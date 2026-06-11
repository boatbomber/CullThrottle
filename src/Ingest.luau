--!strict
--!optimize 2
--!native

--[[
	This module turns the frame's visible voxels into a prioritized update
	queue. The visible voxels are sorted closest-first, then the precise pass
	scores each object (screen size, refresh urgency, distance) until its time
	budget runs out. Whatever remains is dumped by the fast pass with a coarse
	priority derived from each voxel's search order.
]]

local types = require(script.Parent.types)
local Config = require(script.Parent.Config)
local PriorityQueue = require(script.Parent.PriorityQueue)
local VoxelGrid = require(script.Parent.VoxelGrid)
local VisibilitySearch = require(script.Parent.VisibilitySearch)
local VisibilitySignals = require(script.Parent.VisibilitySignals)
local CameraCache = require(script.Parent.Utilities.CameraCache)

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local tableClear = table.clear

-- Priorities below this are p0 (must refresh this frame). IterateObjectsToUpdate
-- keys its overrun budget off the same threshold, so it's exported.
local P0_THRESHOLD = 0.90
-- This is in studs. Objects closer than this to the camera are prioritized to
-- refresh nearly every frame regardless of screen size.
local NEARBY_DISTANCE_THRESHOLD = 30
-- An object centered exactly on the camera has distance == 0, which would make
-- screen size infinite and feed -inf into the priority math. We clamp distance
-- to a tiny positive minimum. Objects this close fill the view and sort first
-- anyway.
local MIN_SCREEN_SIZE_DISTANCE = 1e-4

-- os.clock costs ~30ns, so the ingest loop checks its time budget once per
-- batch of objects instead of after every object. The worst-case budget overrun
-- is one batch's worth of work (a few microseconds).
local INGEST_CLOCK_CHECK_OBJECT_INTERVAL = 16

-- This weight gives more update priority to larger objects,
-- focusing on the objects that contribute the most visually.
local SCREEN_SIZE_PRIORITY_WEIGHT = 85
-- This weight tries to make everything the same refresh rate,
-- sacrificing some updates to big objects for the little ones
-- for a smoother overall vibe.
local REFRESH_RATE_PRIORITY_WEIGHT = 13
-- This weight gives more priority to nearby objects regardless of size,
-- which can help prioritize objects that are likely the real focus
-- in cases where there are many objects of similar screen size.
local DISTANCE_PRIORITY_WEIGHT = 2

-- Objects that don't need refreshing yet are pushed far down the queue (the
-- lowest priority value dequeues first) by scaling their screen-size term by
-- this, so they sort after everything that actually needs an update this frame.
local OVER_REFRESH_PRIORITY_SCALE = 1e6
-- The fast-approx ingest path can't compute a real priority, so it derives one
-- from each voxel's search order (closer voxels are searched first). Scaling the
-- voxel index keeps successive voxels in distinct, monotonically increasing
-- priority tiers, so nearer voxels are always dequeued ahead of farther ones.
local FAST_APPROX_VOXEL_PRIORITY_SCALE = 1e4
-- The fast-pass tiers saturate at this cap, one tier under the over-refresh
-- band's floor. Objects dumped by the fast pass still need updates this frame,
-- so even the deepest voxel must sort ahead of objects that were just
-- refreshed. Voxels past the cap share one tier, trading their relative order
-- for that guarantee.
local FAST_APPROX_VOXEL_PRIORITY_CAP = P0_THRESHOLD * OVER_REFRESH_PRIORITY_SCALE - FAST_APPROX_VOXEL_PRIORITY_SCALE

local Ingest = {}
Ingest.__index = Ingest

Ingest.P0_THRESHOLD = P0_THRESHOLD

type IngestProto = {
	_config: Config.Config,
	_grid: VoxelGrid.VoxelGrid,
	_search: VisibilitySearch.VisibilitySearch,
	_signals: VisibilitySignals.VisibilitySignals,
	_perfMetrics: types.PerfMetrics,

	_visibleObjectsQueue: PriorityQueue.PriorityQueue<Instance>,
	_voxelDistanceCounts: { number },
}

export type Ingest = typeof(setmetatable({} :: IngestProto, Ingest))

--[[
	Builds the ingest pass with an empty visible-objects queue.
]]
function Ingest.new(
	config: Config.Config,
	grid: VoxelGrid.VoxelGrid,
	search: VisibilitySearch.VisibilitySearch,
	signals: VisibilitySignals.VisibilitySignals,
	perfMetrics: types.PerfMetrics
): Ingest
	local self = setmetatable({
		_config = config,
		_grid = grid,
		_search = search,
		_signals = signals,
		_perfMetrics = perfMetrics,
		_visibleObjectsQueue = PriorityQueue.new(),
		_voxelDistanceCounts = {},
	}, Ingest)

	return self
end

--[[
	Orders this frame's visible voxels closest-first by manhattan distance to the
	camera (in voxel space). The ingest passes rely on that order. Nearer voxels
	get precise ingestion, and once the budget runs out fastApproxIngestRemainingVoxels
	uses the index as a coarse priority. The ordering is only a soft heuristic
	(manhattan distance is itself an approximation).

	Distances are small non-negative integers, so a counting sort orders them in
	O(n + maxDistance) with no element shuffling, and cameraVoxelKey is computed
	just once for the whole batch.
]]
function Ingest.sortVisibleVoxelKeys(self: Ingest)
	local search = self._search
	local count = search._visibleVoxelCount
	local pendingVoxelKeys = search._pendingVoxelKeys
	local visibleVoxelKeys = search._visibleVoxelKeys

	if count == 0 then
		return
	elseif count == 1 then
		visibleVoxelKeys[1] = pendingVoxelKeys[1]
		return
	end

	local cameraVoxelKey = CameraCache.Position // self._config.voxelSize
	local distances = search._pendingVoxelDistances
	local counts = self._voxelDistanceCounts

	-- Compute the manhattan distance for every pending voxel, plus the max (the bucket range).
	local maxDistance = 0
	for i = 1, count do
		local difference = pendingVoxelKeys[i] - cameraVoxelKey
		local distance = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)
		distances[i] = distance
		if distance > maxDistance then
			maxDistance = distance
		end
	end

	-- Tally how many voxels land in each distance bucket.
	for distance = 0, maxDistance do
		counts[distance] = 0
	end
	for i = 1, count do
		local distance = distances[i]
		counts[distance] += 1
	end

	-- Turn the tallies into each bucket's starting output slot (prefix sum).
	local slot = 1
	for distance = 0, maxDistance do
		local bucketCount = counts[distance]
		counts[distance] = slot
		slot += bucketCount
	end

	-- Scatter each voxel into its sorted slot.
	-- Walking the source in order keeps voxels at equal distance in their original (stable) order.
	for i = 1, count do
		local distance = distances[i]
		local outputIndex = counts[distance]
		counts[distance] = outputIndex + 1
		visibleVoxelKeys[outputIndex] = pendingVoxelKeys[i]
	end
end

--[[
	This is the precise ingest pass. It scores each object in this frame's
	visible voxels (screen size, refresh urgency, distance), stages it in the
	visible objects queue, and records entered-view bookkeeping, until the
	ingest time budget runs out. The visible voxels are sorted closest-first,
	so the budget is spent on the nearest objects, and whatever it can't reach
	falls into the cheap approximate pass.
]]
function Ingest.ingestVisibleVoxels(self: Ingest, now: number)
	debug.profilebegin("ingestVoxels")

	-- Everything the per-object loop reads is hoisted here so it's paid once
	-- per frame instead of once per voxel.
	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position
	local cameraLookVector = cameraCFrame.LookVector
	local cameraRightVector = cameraCFrame.RightVector
	local cameraUpVector = cameraCFrame.UpVector
	local sinHalfHorizontalFov = CameraCache.SinHalfHorizontalFOV
	local cosHalfHorizontalFov = CameraCache.CosHalfHorizontalFOV
	local sinHalfVerticalFov = CameraCache.SinHalfVerticalFOV
	local cosHalfVerticalFov = CameraCache.CosHalfVerticalFOV
	local tanHalfVerticalFov = CameraCache.TanHalfVertFOV

	local config = self._config
	local ingestTimeBudget = config.ingestTimeBudget
	local renderDistance = config.renderDistance
	local bestRefreshPeriod = config.bestRefreshPeriod
	local worstRefreshPeriod = config.worstRefreshPeriod
	local refreshPeriodRange = config.refreshPeriodRange

	local search = self._search
	local signals = self._signals
	local voxels = self._grid._voxels
	local visibleVoxelKeys = search._visibleVoxelKeys
	local visibleVoxelCount = search._visibleVoxelCount
	local visibleObjectsQueue = self._visibleObjectsQueue
	local addToIncomingBatch = visibleObjectsQueue.addToIncomingBatch
	local markVisible = signals.markVisible

	local objectsSinceClockCheck = 0
	local startIngestClock = os.clock()

	for voxelIndex = 1, visibleVoxelCount do
		local voxel = voxels[visibleVoxelKeys[voxelIndex]]
		if not voxel then
			continue
		end

		for _, objectData in voxel do
			if objectData.lastCheckClock == now then
				-- An object spanning several visible voxels comes up once per
				-- voxel, so only its first visit this frame does the work.
				continue
			end
			objectData.lastCheckClock = now

			local dirToObject: Vector3 = objectData.position - cameraPos
			local distance = vectorMagnitude(dirToObject)
			objectData.distance = distance
			if not (distance <= renderDistance) then
				-- This cull is phrased so a NaN distance (from a NaN position
				-- upstream) fails into it too, instead of feeding a NaN priority
				-- into the queue where it would silently corrupt the heap order.
				continue
			end

			local radius = objectData.radius

			-- Cull objects whose bounding sphere falls fully outside the view
			-- frustum's side planes. The signed distance from the object's center to
			-- a side plane is |lateral| * cos(halfFov) - forward * sin(halfFov), so
			-- the sphere is outside once that exceeds the radius on either axis.
			--
			-- This only applies to objects whose center is in front of the camera.
			-- Once the center passes behind the camera plane, a large object can still
			-- wrap its body into view while the side-plane test no longer holds, so
			-- we keep it. The voxel search already discards voxels fully behind us.
			local forward = vectorDot(cameraLookVector, dirToObject)
			if forward > 0 then
				local right = vectorDot(cameraRightVector, dirToObject)
				local up = vectorDot(cameraUpVector, dirToObject)
				if
					math.abs(right) * cosHalfHorizontalFov - forward * sinHalfHorizontalFov > radius
					or math.abs(up) * cosHalfVerticalFov - forward * sinHalfVerticalFov > radius
				then
					continue
				end
			end

			local screenSize = radius / math.max(distance, MIN_SCREEN_SIZE_DISTANCE) / tanHalfVerticalFov
			local elapsed = now - objectData.lastUpdateClock
			local jitteredElapsed = elapsed + objectData.jitterOffset

			local objectPriority = 0

			if jitteredElapsed <= bestRefreshPeriod then
				-- This was refreshed within the best rate, so push it far down the queue.
				objectPriority = (P0_THRESHOLD + (1 - math.min(screenSize, 1))) * OVER_REFRESH_PRIORITY_SCALE
			elseif jitteredElapsed >= worstRefreshPeriod then
				-- To maintain the worst refresh rate, make this p0 priority.
				-- These p0s sort by screen size.
				objectPriority = P0_THRESHOLD - screenSize
			elseif distance < NEARBY_DISTANCE_THRESHOLD then
				-- Objects right by the camera should update basically every frame.
				objectPriority = distance / NEARBY_DISTANCE_THRESHOLD
			else
				-- Figure out the fair object priority. The screen size clamps to 1
				-- so a screen-filling object can't push the term negative and land
				-- below the p0 threshold, taking the overrun budget from objects
				-- that must refresh this frame.
				local screenSizePriority = SCREEN_SIZE_PRIORITY_WEIGHT * (1 - math.min(screenSize, 1))
				local refreshPriority = REFRESH_RATE_PRIORITY_WEIGHT
					* (1 - (jitteredElapsed - bestRefreshPeriod) / refreshPeriodRange)
				local distancePriority = DISTANCE_PRIORITY_WEIGHT * (distance / renderDistance)

				objectPriority = screenSizePriority + refreshPriority + distancePriority
			end

			addToIncomingBatch(visibleObjectsQueue, objectData.object, objectPriority)
			markVisible(signals, objectData, now)
		end

		objectsSinceClockCheck += #voxel
		if objectsSinceClockCheck >= INGEST_CLOCK_CHECK_OBJECT_INTERVAL then
			objectsSinceClockCheck = 0
			if os.clock() - startIngestClock >= ingestTimeBudget then
				-- We've run out of time! Dump the remaining voxels through the
				-- fast approximate pass.
				self:fastApproxIngestRemainingVoxels(now, voxelIndex + 1)
				self._perfMetrics._ingestDuration = os.clock() - startIngestClock
				debug.profileend()
				return
			end
		end
	end

	self._perfMetrics._ingestDuration = os.clock() - startIngestClock

	debug.profileend()
end

--[[
	This is the cheap fallback ingest. It dumps every object in the remaining
	visible voxels into the queue with a coarse priority derived from each
	voxel's search order (closer voxels were searched first), and it tallies
	how many voxels fell through here in the skipped-ingest metric. It skips
	the precise pass's scoring, but it still refreshes each object's distance
	(the iterator yields the stored value, and nothing else updates it for a
	static object) and culls past the render distance, so each visible object
	pays exactly one magnitude call per frame in whichever pass reaches it.
]]
function Ingest.fastApproxIngestRemainingVoxels(self: Ingest, now: number, startIndex: number)
	local search = self._search
	local signals = self._signals
	local voxels = self._grid._voxels
	local visibleVoxelKeys = search._visibleVoxelKeys
	local visibleVoxelCount = search._visibleVoxelCount
	local visibleObjectsQueue = self._visibleObjectsQueue
	local cameraPos = CameraCache.Position
	local renderDistance = self._config.renderDistance

	for voxelIndex = startIndex, visibleVoxelCount do
		local voxelKey = visibleVoxelKeys[voxelIndex]
		local voxel = voxels[voxelKey]
		if not voxel then
			continue
		end

		local approxPriority = math.min(voxelIndex * FAST_APPROX_VOXEL_PRIORITY_SCALE, FAST_APPROX_VOXEL_PRIORITY_CAP)

		for _, objectData in voxel do
			if objectData.lastCheckClock == now then
				-- This object was already ingested this frame (here or in the precise
				-- pass), so we skip it to avoid duplicating an object that spans voxels.
				continue
			end
			objectData.lastCheckClock = now

			local distance = vectorMagnitude(objectData.position - cameraPos)
			objectData.distance = distance
			if not (distance <= renderDistance) then
				-- Like the precise pass, this is phrased so a NaN distance fails
				-- into the cull rather than staging a NaN priority.
				continue
			end

			visibleObjectsQueue:addToIncomingBatch(objectData.object, approxPriority)
			signals:markVisible(objectData, now)
		end
	end

	local perfMetrics = self._perfMetrics
	-- The frame loop advanced the ring cursor and zeroed this frame's slot before
	-- ingest ran, so frames where this fallback never runs stay recorded as zero.
	perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor] = 1 + visibleVoxelCount - startIndex
end

--[[
	Clears the visible-objects queue and the sort's scratch counts so
	everything they referenced can be garbage collected.
]]
function Ingest.destroy(self: Ingest)
	tableClear(self._voxelDistanceCounts)
	self._visibleObjectsQueue:clearIncomingBatch()
	self._visibleObjectsQueue:clear()
end

return Ingest
