--!strict

--[[
	This is the performance benchmark for the per-frame pipeline. It stages a
	large synthetic scene, then drives frames by hand through a handful of
	camera motion scenarios with time budgets that never bind, so
	throughput improvements show up as lower frame times instead of shifted
	degradation. Each scenario reports mean, median, and p95 frame times plus
	a phase breakdown. Run it with scripts/bench.sh.

	The printed per-frame voxel and object averages double as sanity checks.
	An optimization that changes them changed behavior along with speed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local CullThrottle = require(CullThrottlePackage) :: any
local CameraCache = require(CullThrottlePackage:WaitForChild("Utilities"):WaitForChild("CameraCache")) :: any

-- The scene is this many anchored parts scattered in a box around the origin.
local OBJECT_COUNT = 40_000
local SCENE_HALF_EXTENT = 2000
local SCENE_HEIGHT = 400
-- The render distance is pinned with a zero-width range so the dynamic
-- controller can't drift it mid-run and make timings incomparable.
local RENDER_DISTANCE = 1000
-- Each scenario runs unmeasured warmup frames first, so the motion-proof
-- caches settle into the scenario's motion pattern before measurement starts.
local WARMUP_FRAMES = 30
local MEASURE_FRAMES = 120
-- The bench yields periodically so long stretches of frames can't trip the
-- script exhaustion watchdog.
local FRAMES_PER_YIELD = 32

local rng = Random.new(94)

--[[
	Rolls a part size. Most parts are small (well under the multi-voxel
	threshold), some are medium, and a few are large enough to span several
	voxels so the oriented-box fill gets exercised.
]]
local function randomPartSize(): Vector3
	local roll = rng:NextNumber()
	if roll < 0.9 then
		return Vector3.new(rng:NextNumber(1, 12), rng:NextNumber(1, 12), rng:NextNumber(1, 12))
	elseif roll < 0.98 then
		return Vector3.new(rng:NextNumber(12, 40), rng:NextNumber(12, 40), rng:NextNumber(12, 40))
	end
	return Vector3.new(rng:NextNumber(40, 150), rng:NextNumber(40, 150), rng:NextNumber(40, 150))
end

--[[
	Builds the synthetic scene as unparented anchored parts, which keeps the
	DataModel light while still giving CullThrottle real instances to track.
]]
local function buildScene(): { BasePart }
	local parts = table.create(OBJECT_COUNT)
	for i = 1, OBJECT_COUNT do
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = randomPartSize()
		part.CFrame = CFrame.new(
			rng:NextNumber(-SCENE_HALF_EXTENT, SCENE_HALF_EXTENT),
			rng:NextNumber(0, SCENE_HEIGHT),
			rng:NextNumber(-SCENE_HALF_EXTENT, SCENE_HALF_EXTENT)
		) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
		parts[i] = part
		if i % 8000 == 0 then
			task.wait()
		end
	end
	return parts
end

--[[
	Adds every part to the tracker and returns how long the adds themselves
	took, excluding the yields between chunks.
]]
local function addAllObjects(cullThrottle: any, parts: { BasePart }): number
	local addDuration = 0
	local chunkStart = os.clock()
	for i = 1, #parts do
		cullThrottle:AddObject(parts[i])
		if i % 4000 == 0 then
			addDuration += os.clock() - chunkStart
			task.wait()
			chunkStart = os.clock()
		end
	end
	addDuration += os.clock() - chunkStart
	return addDuration
end

--[[
	Builds a ring of big walls around the scene center for the occlusion
	scenario. They stay unparented, since the bench registers them with the
	occlusion module directly instead of going through the tag.
]]
local function createOccluderWalls(): { Part }
	local walls = table.create(8)
	for i = 1, 8 do
		local angle = (i - 1) * math.pi / 4
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Size = Vector3.new(500, 250, 20)
		wall.CFrame = CFrame.new(math.sin(angle) * 350, 125, math.cos(angle) * 350) * CFrame.Angles(0, angle, 0)
		walls[i] = wall
	end
	return walls
end

--[[
	Sorts a copy-free array of samples and returns (mean, p50, p95), all in
	the samples' own unit.
]]
local function summarize(values: { number }): (number, number, number)
	table.sort(values)
	local count = #values
	local sum = 0
	for _, value in values do
		sum += value
	end
	return sum / count, values[math.ceil(count * 0.5)], values[math.ceil(count * 0.95)]
end

--[[
	Runs one benchmark frame. The visibility phase is the library's own
	per-frame entry point, the fill phase lays the staged batch out into the
	queue (timed separately here since the update iterator's own call
	short-circuits), and the drain phase empties the whole prioritized queue
	like a consumer would. Returns the three phase durations and how many
	objects the drain yielded.
]]
local function benchFrame(cullThrottle: any): (number, number, number, number)
	local frameStart = os.clock()
	cullThrottle:_onPreRender(frameStart)
	local visibilityEnd = os.clock()

	cullThrottle._ingest:enqueueStagedObjects()
	local fillEnd = os.clock()

	local drained = 0
	for _object in cullThrottle:IterateObjectsToUpdate() do
		drained += 1
	end
	local drainEnd = os.clock()

	return visibilityEnd - frameStart, fillEnd - visibilityEnd, drainEnd - fillEnd, drained
end

--[[
	Runs one scenario (warmup then measurement), prints its stats line, and
	returns the median total frame time in seconds. The camera pose comes from
	poseForFrame, and CameraCache is refreshed synchronously so the pipeline
	sees the move on the same frame regardless of deferred signal timing.
]]
local function runScenario(cullThrottle: any, camera: Camera, name: string, poseForFrame: (number) -> CFrame): number
	local visibilityTimes = table.create(MEASURE_FRAMES)
	local fillTimes = table.create(MEASURE_FRAMES)
	local drainTimes = table.create(MEASURE_FRAMES)
	local totalTimes = table.create(MEASURE_FRAMES)
	local searchSum, ingestSum = 0, 0
	local drainedSum, voxelSum = 0, 0

	for frame = 1, WARMUP_FRAMES + MEASURE_FRAMES do
		camera.CFrame = poseForFrame(frame)
		CameraCache.cframeChanged()

		local visibilityTime, fillTime, drainTime, drained = benchFrame(cullThrottle)

		local sampleIndex = frame - WARMUP_FRAMES
		if sampleIndex > 0 then
			visibilityTimes[sampleIndex] = visibilityTime
			fillTimes[sampleIndex] = fillTime
			drainTimes[sampleIndex] = drainTime
			totalTimes[sampleIndex] = visibilityTime + fillTime + drainTime

			local metrics = cullThrottle:GetPerformanceMetrics()
			searchSum += metrics.searchDuration
			ingestSum += metrics.ingestDuration
			drainedSum += drained
			voxelSum += cullThrottle._search._visibleVoxelCount
		end

		if frame % FRAMES_PER_YIELD == 0 then
			task.wait()
		end
	end

	local totalMean, totalP50, totalP95 = summarize(totalTimes)
	local visibilityMean = summarize(visibilityTimes)
	local fillMean = summarize(fillTimes)
	local drainMean = summarize(drainTimes)
	local searchMean = searchSum / MEASURE_FRAMES
	local ingestMean = ingestSum / MEASURE_FRAMES
	local otherMean = visibilityMean - searchMean - ingestMean

	print(
		string.format(
			"[BENCH] %-9s | total mean=%7.3fms p50=%7.3fms p95=%7.3fms | search=%6.3f ingest=%6.3f fill=%6.3f drain=%6.3f other=%6.3f | voxels=%d objects=%d",
			name,
			totalMean * 1000,
			totalP50 * 1000,
			totalP95 * 1000,
			searchMean * 1000,
			ingestMean * 1000,
			fillMean * 1000,
			drainMean * 1000,
			otherMean * 1000,
			voxelSum // MEASURE_FRAMES,
			drainedSum // MEASURE_FRAMES
		)
	)

	return totalP50
end

--[[
	This is the benchmark entry point. It stages the scene, runs every
	scenario, and prints the overall score (the sum of scenario median frame
	times), which is the number optimization passes compare.
]]
local function main()
	local camera = workspace.CurrentCamera
	assert(camera, "The benchmark needs workspace.CurrentCamera")

	print("[BENCH] Starting CullThrottle benchmark")
	print(
		string.format(
			"[BENCH] objects=%d scene=%dx%dx%d renderDistance=%d frames=%d",
			OBJECT_COUNT,
			SCENE_HALF_EXTENT * 2,
			SCENE_HEIGHT,
			SCENE_HALF_EXTENT * 2,
			RENDER_DISTANCE,
			MEASURE_FRAMES
		)
	)

	-- The frustum's shape derives from the viewport's aspect ratio and the
	-- engine-adjusted max-axis field of view, so left to the live camera it
	-- would depend on whatever window Studio happens to be rendering into (a
	-- locked screen gives a different viewport than a real monitor), shifting
	-- every voxel and object count. Pinning a canonical projection (16:9 at a
	-- 70 degree vertical field of view) and dropping the listeners that would
	-- reapply the live values keeps the counts comparable across machines and
	-- sessions.
	CameraCache._connections.ViewportSizeChanged:Disconnect()
	CameraCache._connections.FieldOfViewChanged:Disconnect()
	CameraCache.ViewportSize = Vector2.new(1920, 1080)
	CameraCache.AspectRatio = 1920 / 1080
	CameraCache.TanHalfVertFOV = math.tan(math.rad(35))
	CameraCache.HalfVerticalFOV = math.rad(35)
	CameraCache.HalfHorizontalFOV = math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
	CameraCache.SinHalfVerticalFOV = math.sin(CameraCache.HalfVerticalFOV)
	CameraCache.CosHalfVerticalFOV = math.cos(CameraCache.HalfVerticalFOV)
	CameraCache.SinHalfHorizontalFOV = math.sin(CameraCache.HalfHorizontalFOV)
	CameraCache.CosHalfHorizontalFOV = math.cos(CameraCache.HalfHorizontalFOV)

	local cullThrottle = CullThrottle.new()
	-- The bench drives frames by hand, so the real PreRender connection is
	-- disconnected to keep it from processing extra frames between ours.
	cullThrottle._renderConnection:Disconnect()
	cullThrottle:SetRenderDistanceRange(NumberRange.new(RENDER_DISTANCE, RENDER_DISTANCE))
	-- One second per phase means no pass ever degrades, so the bench measures
	-- the full workload every frame.
	cullThrottle:SetTimeBudgets(1, 1, 1)

	local parts = buildScene()
	local addDuration = addAllObjects(cullThrottle, parts)
	print(
		string.format(
			"[BENCH] addObjects | total=%8.1fms (%5.2fus per object)",
			addDuration * 1000,
			addDuration / OBJECT_COUNT * 1e6
		)
	)

	local sceneCenter = Vector3.new(0, SCENE_HEIGHT / 2, 0)
	local p50Sum = 0

	-- The orbit scenarios share one camera path so the occluded runs stay a
	-- true A/B against the plain orbit, differing only in what's registered
	-- (and, for the slow variant, the angular rate).
	local function orbitPose(degreesPerFrame: number): (number) -> CFrame
		return function(frame)
			local angle = math.rad(frame * degreesPerFrame)
			return CFrame.lookAt(Vector3.new(math.sin(angle) * 900, 300, math.cos(angle) * 900), sceneCenter)
		end
	end

	p50Sum += runScenario(cullThrottle, camera, "static", function(_frame)
		return CFrame.lookAt(Vector3.new(0, 250, 1200), sceneCenter)
	end)

	p50Sum += runScenario(cullThrottle, camera, "rotate", function(frame)
		return CFrame.new(0, 250, 0) * CFrame.Angles(0, math.rad(frame * 1.5), 0)
	end)

	p50Sum += runScenario(cullThrottle, camera, "translate", function(frame)
		return CFrame.lookAt(Vector3.new(0, 200, 1500 - frame * 6), Vector3.new(0, 200, -SCENE_HALF_EXTENT))
	end)

	p50Sum += runScenario(cullThrottle, camera, "orbit", orbitPose(0.6))

	local walls = createOccluderWalls()
	for _, wall in walls do
		cullThrottle._occlusion:_registerOccluder(wall)
	end
	p50Sum += runScenario(cullThrottle, camera, "occluded", orbitPose(0.6))
	-- The same orbit at a sixth of the speed, about 1.6 studs per frame, which
	-- is fast player movement rather than the scenario above's extreme sweep.
	-- The fast orbit is adversarial for occlusion proof caching (every proof
	-- expires within a frame or two), while this one moves slowly enough for
	-- the translation allowances to pay off, so the pair brackets the layer's
	-- worst and near-ideal cases.
	p50Sum += runScenario(cullThrottle, camera, "occl-slow", orbitPose(0.1))
	for _, wall in walls do
		cullThrottle._occlusion:_unregisterOccluder(wall)
		wall:Destroy()
	end

	p50Sum += runScenario(cullThrottle, camera, "teleport", function(frame)
		local angle = math.rad((frame % 4) * 90)
		return CFrame.lookAt(Vector3.new(math.sin(angle) * 1200, 250, math.cos(angle) * 1200), sceneCenter)
	end)

	print(string.format("[BENCH] OVERALL p50_sum=%.3fms", p50Sum * 1000))

	cullThrottle:Destroy()
	for _, part in parts do
		part:Destroy()
	end
end

main()

return nil
