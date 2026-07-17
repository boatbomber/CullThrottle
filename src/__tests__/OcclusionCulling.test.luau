local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local CullThrottle = require(CullThrottlePackage)
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))
local OcclusionCulling = require(CullThrottlePackage:WaitForChild("OcclusionCulling"))
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local createMockOccluder = TestHelpers.createMockOccluder
local stubObjectData = TestHelpers.stubObjectData
local patchFunction = TestHelpers.patchFunction
local popVolume = TestHelpers.popVolume
local drainVolumeStack = TestHelpers.drainVolumeStack
local hiddenOcclusionProof = TestHelpers.hiddenOcclusionProof
local clearOcclusionProof = TestHelpers.clearOcclusionProof
local volumeCount = TestHelpers.volumeCount
local roomyFrustumPlanes = TestHelpers.roomyFrustumPlanes

local OCCLUDER_TAG = OcclusionCulling.OCCLUDER_TAG

--[[
	Wraps Frustum.classifyBucket with a counting shim (registered for the
	afterEach restore) and returns a getter for how many classifications have
	run since.
]]
local function countClassifyCalls(): () -> number
	return TestHelpers.countCalls(Frustum, "classifyBucket")
end

--[[
	Wraps OcclusionCulling.testBoxOcclusion with a counting shim (registered
	for the afterEach restore) and returns a getter for how many umbra tests
	have run since.
]]
local function countUmbraTests(): () -> number
	return TestHelpers.countCalls(OcclusionCulling, "testBoxOcclusion")
end

--[[
	Wraps OcclusionCulling._buildUmbra with a counting shim (registered for
	the afterEach restore) and returns a getter for how many umbra
	constructions have run since, which is what tells a reuse frame apart
	from a rebuild.
]]
local function countUmbraBuilds(): () -> number
	return TestHelpers.countCalls(OcclusionCulling, "_buildUmbra")
end

--[[
	Stages a hand-built single-plane umbra directly onto the instance's
	occlusion module and marks it live, hiding everything past z = 1.9 in
	voxel space. A world-fixed slab like this keeps the search integration
	tests independent of the umbra construction geometry. The single plane is
	classified as a cap, the shape and edge fields are zeroed so every
	depth-scaled term collapses and allowances stay pinned to the staged pad
	value, and the AABB is unbounded so the gate never prunes.
]]
local function stageSlabUmbra(cullThrottle)
	local occlusion = cullThrottle._occlusion
	occlusion._umbraCount = 1
	occlusion._fullUmbraMask = 1
	occlusion._umbraPlaneNormals[1] = { Vector3.new(0, 0, -1) }
	occlusion._umbraPlaneOffsets[1] = { -1.9 }
	occlusion._umbraPlaneCounts[1] = 1
	occlusion._umbraCapCounts[1] = 1
	occlusion._umbraAllowances[1] = 0.5
	occlusion._umbraShapeAllowances[1] = 0
	occlusion._umbraEdgeDistances[1] = 0
	occlusion._umbraBoundsMin[1] = Vector3.one * -math.huge
	occlusion._umbraBoundsMax[1] = Vector3.one * math.huge
	occlusion._cameraPosVoxels = Vector3.zero
end

--[[
	Stages a second hand-built slab umbra opposing the first, so the pair
	hides everything past z = 1.9 (umbra one) and everything before z = -1.9
	(umbra two), leaving the band between them contested. Two single-plane
	slabs with independent allowances keep the multi-umbra mask arithmetic
	tests independent of the umbra construction geometry.
]]
local function stageOpposingSlabUmbrae(cullThrottle)
	stageSlabUmbra(cullThrottle)
	local occlusion = cullThrottle._occlusion
	occlusion._umbraCount = 2
	occlusion._fullUmbraMask = 3
	occlusion._umbraPlaneNormals[2] = { Vector3.new(0, 0, 1) }
	occlusion._umbraPlaneOffsets[2] = { -1.9 }
	occlusion._umbraPlaneCounts[2] = 1
	occlusion._umbraCapCounts[2] = 1
	occlusion._umbraAllowances[2] = 0.5
	occlusion._umbraShapeAllowances[2] = 0
	occlusion._umbraEdgeDistances[2] = 0
	occlusion._umbraBoundsMin[2] = Vector3.one * -math.huge
	occlusion._umbraBoundsMax[2] = Vector3.one * math.huge
end

--[[
	Builds the shared face-on fixture umbra directly onto the instance's
	occlusion module and marks it live. The camera sits at the origin and the
	wall is a 400 by 400 by 40 slab 200 studs down negative Z, so with the
	default 100 stud voxels the erosion pad is 10 studs and the umbra is one
	cap followed by four silhouette planes. The far radius of 60 voxels
	stands in for what buildUmbrae would derive from the frustum bounds, so
	the AABB gate covers everything within 60 voxels of the camera along the
	umbra. Returns the wall for the caller to clean up.
]]
local function stageFaceOnWallUmbra(cullThrottle): Part
	CameraCache.Position = Vector3.zero
	local wall = createMockPart(Vector3.new(0, 0, -200), Vector3.new(400, 400, 40))
	local occlusion = cullThrottle._occlusion
	assert(occlusion:_buildUmbra(wall, 1, 60), "the fixture umbra failed to build")
	occlusion._umbraCount = 1
	occlusion._fullUmbraMask = 1
	occlusion._cameraPosVoxels = Vector3.zero
	return wall
end

describe("OcclusionCulling", function()
	local cullThrottle

	beforeEach(function()
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		TestHelpers.restorePatches()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil

		-- A failed assertion skips the test body's own cleanup, and a leaked
		-- tagged wall would register with every CullThrottle constructed
		-- after it, cascading one real failure into unrelated suites. The
		-- sweep here keeps each test's fixtures its own.
		for _, tagged in CollectionService:GetTagged(OCCLUDER_TAG) do
			tagged:Destroy()
		end

		-- Tests that override the camera cache's position restore it from the
		-- live camera here, so a failed assertion can't leak a fake camera
		-- position into every later suite.
		CameraCache.cframeChanged()
	end)

	describe("occluder registry", function()
		it("registers tagged box parts and unregisters them when untagged", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			-- The tag signals fire deferred, so let them land.
			task.wait()

			expect(#occlusion._occluders).toBe(1)
			expect(table.find(occlusion._occluders, wall)).never.toBeNil()

			-- Removing an occluder invalidates the proofs it anchored, so the
			-- generation must move.
			local generationBefore = occlusion._generation
			wall:RemoveTag(OCCLUDER_TAG)
			task.wait()

			expect(#occlusion._occluders).toBe(0)
			expect(occlusion._generation).toBeGreaterThan(generationBefore)

			wall:Destroy()
		end)

		it("skips tagged parts that are not anchored boxes", function()
			local occlusion = cullThrottle._occlusion

			-- A ball doesn't fill its bounding box, so treating it as a box
			-- occluder could cull things visible past its curves.
			local ball = createMockPart(Vector3.new(0, 0, -300))
			ball.Shape = Enum.PartType.Ball
			ball:AddTag(OCCLUDER_TAG)

			-- Physics motion fires no change signals, so cached proofs anchored
			-- to an unanchored part could outlive the pose that proved them.
			local loose = createMockPart(Vector3.new(0, 0, -400), nil, false)
			loose:AddTag(OCCLUDER_TAG)

			task.wait()
			expect(#occlusion._occluders).toBe(0)

			ball:Destroy()
			loose:Destroy()
		end)

		it("bumps the generation the same frame an occluder moves or resizes", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			task.wait()
			expect(#occlusion._occluders).toBe(1)
			occlusion:buildUmbrae()

			-- Property signals arrive deferred, so a build in the same
			-- resumption as the move can't lean on them. The selection loop's
			-- pose poll must catch the change before the reuse gate or any
			-- proof consult trusts the old pose.
			local generationBefore = occlusion._generation
			wall.CFrame = CFrame.new(0, 50, -300)
			occlusion:buildUmbrae()
			expect(occlusion._generation).toBeGreaterThan(generationBefore)

			generationBefore = occlusion._generation
			wall.Size = Vector3.new(200, 200, 10)
			occlusion:buildUmbrae()
			expect(occlusion._generation).toBeGreaterThan(generationBefore)

			wall:Destroy()
		end)

		it("unregisters an occluder that leaves the workspace and re-registers it on return", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			-- A part parked outside the workspace no longer renders, so leaving
			-- it registered would keep culling everything behind its stored
			-- pose, and dropping it must invalidate the proofs it anchored.
			local generationBefore = occlusion._generation
			wall.Parent = ReplicatedStorage
			task.wait()
			expect(#occlusion._occluders).toBe(0)
			expect(occlusion._generation).toBeGreaterThan(generationBefore)

			wall.Parent = workspace
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			wall:Destroy()
		end)

		it("registers a tagged part once it qualifies and again after a flip", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10), false)
			wall:AddTag(OCCLUDER_TAG)
			task.wait()
			expect(#occlusion._occluders).toBe(0)

			-- The tag outlives any one disqualification, so anchoring the part
			-- later must register it without retagging.
			wall.Anchored = true
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			wall.Anchored = false
			task.wait()
			expect(#occlusion._occluders).toBe(0)

			wall.Anchored = true
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			wall:Destroy()
		end)

		it("keeps a tagged template outside the workspace unregistered", function()
			local occlusion = cullThrottle._occlusion
			local template = Instance.new("Part")
			template.Size = Vector3.new(100, 100, 10)
			template.Anchored = true
			template.Parent = ReplicatedStorage
			template:AddTag(OCCLUDER_TAG)
			task.wait()

			-- A stored template would otherwise cull the space around its
			-- stored pose even though nothing renders there.
			expect(#occlusion._occluders).toBe(0)

			template.Parent = workspace
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			template:Destroy()
		end)

		it("keeps both generations still when an occluder registers", function()
			local occlusion = cullThrottle._occlusion
			local generationBefore = occlusion._generation
			local clearGenerationBefore = occlusion._clearGeneration

			-- Registration adds occlusion without changing any existing
			-- umbra, so hidden proofs stay true, and clear proofs stay safe
			-- until the newcomer actually wins a selection slot, which the
			-- build's selection tracking catches. Other suites stage proofs
			-- right after registering an occluder directly and rely on this
			-- contract.
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			task.wait()

			local occluderCount = #occlusion._occluders
			local generationAfter = occlusion._generation
			local clearGenerationAfter = occlusion._clearGeneration
			wall:Destroy()
			expect(occluderCount).toBe(1)
			expect(generationAfter).toBe(generationBefore)
			expect(clearGenerationAfter).toBe(clearGenerationBefore)
		end)

		it("unregisters a destroyed occluder and stops watching it", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			-- Destroying the part strips its tag and drops it from the
			-- workspace, and either signal alone must unregister it, expire
			-- the proofs it anchored, and leave nothing for the next frame's
			-- selection to touch.
			local generationBefore = occlusion._generation
			wall:Destroy()
			task.wait()

			expect(#occlusion._occluders).toBe(0)
			expect(next(occlusion._watchedParts)).toBeNil()
			expect(occlusion._generation).toBeGreaterThan(generationBefore)

			occlusion:buildUmbrae()
			expect(occlusion._umbraCount).toBe(0)
		end)

		it("unregisters an occluder whose shape stops being a block", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 100))
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			-- A ball doesn't fill the bounding box its umbra would be built
			-- from, so the shape watcher must disqualify the part the moment
			-- it stops being a block, and the proofs it anchored must expire
			-- with it.
			local generationBefore = occlusion._generation
			wall.Shape = Enum.PartType.Ball
			task.wait()

			local occluderCount = #occlusion._occluders
			local generationAfter = occlusion._generation
			wall:Destroy()
			expect(occluderCount).toBe(0)
			expect(generationAfter).toBeGreaterThan(generationBefore)
		end)

		it("skips a tagged instance that is not a part", function()
			local occlusion = cullThrottle._occlusion
			local model = Instance.new("Model")
			model.Parent = workspace
			model:AddTag(OCCLUDER_TAG)
			task.wait()

			-- Only parts can qualify and an instance's class can never
			-- change, so the registry warns once and gives the instance no
			-- watchers at all.
			local occluderCount = #occlusion._occluders
			local firstWatched = next(occlusion._watchedParts)
			model:Destroy()
			expect(occluderCount).toBe(0)
			expect(firstWatched).toBeNil()
		end)

		it("keeps a double-registered occluder in one slot", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))

			-- The tag signal and a watcher evaluation can both land on the
			-- same qualifying part, so a repeat registration must fall out as
			-- a no-op instead of duplicating the slot.
			occlusion:_registerOccluder(wall)
			occlusion:_registerOccluder(wall)

			local occluderCount = #occlusion._occluders
			wall:Destroy()
			expect(occluderCount).toBe(1)
		end)

		it("ignores tag and property changes after destroy", function()
			local occlusion = cullThrottle._occlusion
			local watched = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			occlusion:destroy()

			-- Destroy drops the tag connections and every watcher, so a
			-- fresh tag and a property flip on the previously watched part
			-- must both land on nothing.
			local late = createMockOccluder(Vector3.new(0, 0, -400), Vector3.new(100, 100, 10))
			watched.Anchored = false
			watched.Anchored = true
			task.wait()

			local occluderCount = #occlusion._occluders
			local firstWatched = next(occlusion._watchedParts)
			late:Destroy()
			watched:Destroy()
			expect(occluderCount).toBe(0)
			expect(firstWatched).toBeNil()
		end)
	end)

	describe("umbra construction", function()
		it("builds one cap followed by four silhouette planes for a face-on view", function()
			CameraCache.Position = Vector3.zero
			local wall = createMockPart(Vector3.new(0, 0, -200), Vector3.new(400, 400, 40))
			local occlusion = cullThrottle._occlusion

			expect(occlusion:_buildUmbra(wall, 1, 40)).toBe(true)
			-- One camera-facing face means one cap plane laid out first and
			-- four silhouette edges behind it.
			expect(occlusion._umbraPlaneCounts[1]).toBe(5)
			expect(occlusion._umbraCapCounts[1]).toBe(1)
			-- The erosion pad is half the 20 stud half thickness, so the
			-- allowance floor is 0.1 voxels shaved by the safety margin.
			expect(occlusion._umbraAllowances[1]).toBeCloseTo(0.09, 5)
			-- The eroded box has half extents (190, 190, 10) and the camera's
			-- local position is (0, 0, 200), so every face's classification
			-- flip is 190 studs away, and each silhouette plane's orienting
			-- face center works out to the same 190 stud bound, making the
			-- shape allowance 1.9 voxels.
			expect(occlusion._umbraShapeAllowances[1]).toBeCloseTo(1.9, 5)
			-- Each silhouette edge line passes 190 studs off-axis at 190
			-- studs depth, so the camera's distance to it is 190 * sqrt(2).
			expect(occlusion._umbraEdgeDistances[1]).toBeCloseTo(1.9 * math.sqrt(2), 5)

			wall:Destroy()
		end)

		it("refuses to build an umbra for a camera inside the part", function()
			-- The wall spans z in [-220, -180] with a 10 stud erosion pad, so
			-- a camera at z = -185 sits inside the part but outside the eroded
			-- box. The renderer draws backfaces transparent there, so the
			-- player sees straight through the wall and nothing behind it may
			-- be culled.
			CameraCache.Position = Vector3.new(0, 0, -185)
			local wall = createMockPart(Vector3.new(0, 0, -200), Vector3.new(400, 400, 40))
			local occlusion = cullThrottle._occlusion

			local built = occlusion:_buildUmbra(wall, 1, 40)
			wall:Destroy()
			expect(built).toBe(false)
		end)

		it("builds three caps followed by six silhouette planes for a corner view", function()
			CameraCache.Position = Vector3.new(500, 500, 500)
			local box = createMockPart(Vector3.new(0, 0, 0), Vector3.new(100, 100, 100))
			local occlusion = cullThrottle._occlusion

			expect(occlusion:_buildUmbra(box, 1, 40)).toBe(true)
			-- Three camera-facing faces give three caps up front and the
			-- classic hexagonal silhouette of six planes behind them.
			expect(occlusion._umbraPlaneCounts[1]).toBe(9)
			expect(occlusion._umbraCapCounts[1]).toBe(3)

			box:Destroy()
		end)

		it("measures the shape allowance from the nearest classification flip", function()
			-- The camera sits 2 studs past the cube's +Y face plane (the
			-- eroded half extent is 50), so a 2 stud translation could flip
			-- that face's classification and reshape the plane set. That
			-- flip distance is the binding term of the shape allowance.
			CameraCache.Position = Vector3.new(0, 52, 0)
			local box = createMockPart(Vector3.new(0, 0, -300), Vector3.new(200, 200, 200))
			local occlusion = cullThrottle._occlusion

			expect(occlusion:_buildUmbra(box, 1, 40)).toBe(true)
			expect(occlusion._umbraShapeAllowances[1]).toBeCloseTo(0.02, 4)

			box:Destroy()
		end)

		it("skips an occluder the camera is inside of", function()
			CameraCache.Position = Vector3.new(0, 0, 0)
			local box = createMockPart(Vector3.new(0, 0, 0), Vector3.new(100, 100, 100))
			local occlusion = cullThrottle._occlusion

			expect(occlusion:_buildUmbra(box, 1, 40)).toBe(false)

			box:Destroy()
		end)

		it("skips an occluder when the camera lines up with a silhouette edge", function()
			-- The wall's eroded top-front edge runs along x at y = 240 and
			-- z = -290, and the camera sits a ten-thousandth of a stud off
			-- that line's extension, high enough for the +Y face to classify
			-- visible and make the edge a silhouette. The camera-to-endpoint
			-- vectors are then collinear within the guard's epsilon, no
			-- stable plane orientation exists there, and the whole occluder
			-- must be skipped rather than build a leaky umbra.
			CameraCache.Position = Vector3.new(500, 240.0001, -290)
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			local occlusion = cullThrottle._occlusion

			local built = occlusion:_buildUmbra(wall, 1, 40)
			wall:Destroy()
			expect(built).toBe(false)
		end)
	end)

	describe("occluder selection", function()
		local savedCameraCFrame

		beforeEach(function()
			savedCameraCFrame = workspace.CurrentCamera.CFrame
			-- A canonical world-aligned pose makes the occluder geometry below
			-- deterministic. The camera cache refresh is called synchronously
			-- rather than waiting on the deferred change signal.
			workspace.CurrentCamera.CFrame = CFrame.new(Vector3.new(50, 50, 50), Vector3.new(50, 50, -1000))
			CameraCache.cframeChanged()
		end)

		afterEach(function()
			workspace.CurrentCamera.CFrame = savedCameraCFrame
			task.wait()
		end)

		it("drops an occluder behind the camera", function()
			-- The wall is close and large, but the camera faces the other way,
			-- so its umbra can't overlap anything the frustum shows.
			local wall = createMockOccluder(Vector3.new(50, 50, 350), Vector3.new(400, 400, 40))
			task.wait()

			local occlusion = cullThrottle._occlusion
			occlusion:buildUmbrae()

			-- The fixture is destroyed before the assertion so a failure can't
			-- leak a tagged occluder into later tests.
			local umbraCount = occlusion._umbraCount
			wall:Destroy()
			expect(umbraCount).toBe(0)
		end)

		it("drops an occluder outside the side of the frustum", function()
			-- The wall sits within render distance but far off to the right,
			-- outside the widest field of view the camera can have.
			local wall = createMockOccluder(Vector3.new(600, 50, -100), Vector3.new(400, 400, 40))
			task.wait()

			local occlusion = cullThrottle._occlusion
			occlusion:buildUmbrae()

			local umbraCount = occlusion._umbraCount
			wall:Destroy()
			expect(umbraCount).toBe(0)
		end)

		it("drops an occluder past the render distance", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))
			local box = createMockOccluder(Vector3.new(50, 50, -700), Vector3.new(100, 100, 100))
			task.wait()

			local occlusion = cullThrottle._occlusion
			occlusion:buildUmbrae()

			local umbraCount = occlusion._umbraCount
			box:Destroy()
			expect(umbraCount).toBe(0)
		end)

		it("keeps a frustum-dropped occluder from consuming the cap slot", function()
			-- The behind wall is bigger and closer, so it would win the
			-- projected size score, but it sits outside the frustum and is
			-- dropped before scoring, leaving the single slot for the front
			-- wall.
			cullThrottle:SetMaxOccluders(1)
			local behindWall = createMockOccluder(Vector3.new(50, 50, 250), Vector3.new(4000, 4000, 40))
			local frontWall = createMockOccluder(Vector3.new(50, 50, -150), Vector3.new(2000, 2000, 40))
			task.wait()

			local occlusion = cullThrottle._occlusion
			occlusion:buildUmbrae()

			-- With the front wall holding the single slot, a region behind it
			-- tests occluded. The reads all land before the fixtures are
			-- destroyed, and the assertions after, so a failure can't leak a
			-- tagged occluder into later tests.
			local umbraCount = occlusion._umbraCount
			local occluded = occlusion:testBoxOcclusion(occlusion._fullUmbraMask, 0, 0, -8, 1, 1, -7)
			behindWall:Destroy()
			frontWall:Destroy()
			expect(umbraCount).toBe(1)
			expect(occluded).toBe(true)
		end)

		it("skips a top scorer the camera sits inside and spends its slot on the rest", function()
			cullThrottle:SetMaxOccluders(2)
			local occlusion = cullThrottle._occlusion
			-- The room dwarfs the other scores, but the camera sits inside
			-- it, so no umbra it casts can be trusted and both slots must go
			-- to the walls behind it.
			local room = createMockPart(Vector3.new(50, 50, 0), Vector3.new(400, 400, 400))
			local nearWall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 100, 40))
			local highWall = createMockPart(Vector3.new(50, 350, -600), Vector3.new(300, 300, 40))
			occlusion:_registerOccluder(room)
			occlusion:_registerOccluder(nearWall)
			occlusion:_registerOccluder(highWall)

			occlusion:buildUmbrae()

			-- The probe box hides behind the high wall alone (the near wall
			-- is too short to shadow it), so an occluded verdict proves the
			-- lowest scorer still won a slot.
			local umbraCount = occlusion._umbraCount
			local occluded = occlusion:testBoxOcclusion(occlusion._fullUmbraMask, 0.4, 6.4, -12.6, 0.6, 6.6, -12.4)
			room:Destroy()
			nearWall:Destroy()
			highWall:Destroy()
			expect(umbraCount).toBe(2)
			expect(occluded).toBe(true)
		end)

		it("pulls in the next candidate when a selected occluder fails to build", function()
			cullThrottle:SetMaxOccluders(2)
			local occlusion = cullThrottle._occlusion
			local degenerateWall = createMockPart(Vector3.new(50, 50, -150), Vector3.new(400, 400, 40))
			local nearWall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 100, 40))
			local highWall = createMockPart(Vector3.new(50, 350, -600), Vector3.new(300, 300, 40))
			occlusion:_registerOccluder(degenerateWall)
			occlusion:_registerOccluder(nearWall)
			occlusion:_registerOccluder(highWall)

			-- The selection prefilter excludes the degeneracy it can see
			-- coming (a camera inside the part) before the build loop runs,
			-- so the top scorer's refusal is staged by patching its
			-- construction to fail, the way a collinear silhouette edge
			-- would.
			local originalBuildUmbra
			originalBuildUmbra = patchFunction(
				OcclusionCulling,
				"_buildUmbra",
				function(self, part, umbraIndex, farRadius)
					if part == degenerateWall then
						return false
					end
					return originalBuildUmbra(self, part, umbraIndex, farRadius)
				end
			)

			occlusion:buildUmbrae()

			-- The probe box hides behind the high wall alone (the near wall
			-- is too short to shadow it), so an occluded verdict proves the
			-- third candidate got the slot the degenerate gave up.
			local umbraCount = occlusion._umbraCount
			local occluded = occlusion:testBoxOcclusion(occlusion._fullUmbraMask, 0.4, 6.4, -12.6, 0.6, 6.6, -12.4)
			degenerateWall:Destroy()
			nearWall:Destroy()
			highWall:Destroy()
			expect(umbraCount).toBe(2)
			expect(occluded).toBe(true)
		end)

		it("stops building at the occluder cap and leaves the next candidate unbuilt", function()
			cullThrottle:SetMaxOccluders(2)
			local occlusion = cullThrottle._occlusion
			local bigWall = createMockPart(Vector3.new(50, 50, -150), Vector3.new(400, 400, 40))
			local nearWall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 100, 40))
			local highWall = createMockPart(Vector3.new(50, 350, -600), Vector3.new(300, 300, 40))
			occlusion:_registerOccluder(bigWall)
			occlusion:_registerOccluder(nearWall)
			occlusion:_registerOccluder(highWall)

			-- Three viable candidates and two slots means construction runs
			-- exactly twice and the lowest scorer never builds.
			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()

			local builds = getBuilds()
			local umbraCount = occlusion._umbraCount
			bigWall:Destroy()
			nearWall:Destroy()
			highWall:Destroy()
			expect(builds).toBe(2)
			expect(umbraCount).toBe(2)
		end)

		it("leaves the camera cache's planes table unmutated by the build", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			task.wait()
			expect(#occlusion._occluders).toBe(1)

			-- Several suites patch getPlanesAndBounds to hand back a shared
			-- fixture, and the camera cache owns the real table, so the build
			-- must keep its closing plane in its own scratch instead of growing
			-- the returned table.
			local sharedPlanes = table.clone(roomyFrustumPlanes)
			patchFunction(CameraCache, "getPlanesAndBounds", function()
				return sharedPlanes, Vector3.new(0, 0, 0), Vector3.new(19, 27, 3)
			end)

			occlusion:buildUmbrae()
			expect(#sharedPlanes).toBe(10)

			wall:Destroy()
		end)
	end)

	describe("umbra reuse", function()
		local savedCameraCFrame

		beforeEach(function()
			savedCameraCFrame = workspace.CurrentCamera.CFrame
			-- A canonical world-aligned pose makes the occluder geometry below
			-- deterministic. The camera cache refresh is called synchronously
			-- rather than waiting on the deferred change signal.
			workspace.CurrentCamera.CFrame = CFrame.new(Vector3.new(50, 50, 50), Vector3.new(50, 50, -1000))
			CameraCache.cframeChanged()
		end)

		afterEach(function()
			workspace.CurrentCamera.CFrame = savedCameraCFrame
			task.wait()
		end)

		it("reuses the built umbrae while the drift stays under the tightest pad", function()
			local occlusion = cullThrottle._occlusion
			-- The wall is 40 studs thick, so its pad is 10 studs and the pad
			-- floor allowance is 0.09 voxels, the drift budget reuse gets.
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()
			local anchor = occlusion._cameraPosVoxels

			-- The camera drifts 5 studs, under the 9 stud budget, so the next
			-- frame keeps the built planes and leaves the anchor where the
			-- build put it. What the drift does to handed-out allowances is
			-- owned by the debit test below.
			CameraCache.Position += Vector3.new(5, 0, 0)
			cullThrottle._motion._accumT += 0.05
			occlusion:buildUmbrae()

			local builds = getBuilds()
			local umbraCount = occlusion._umbraCount
			local anchorAfter = occlusion._cameraPosVoxels
			wall:Destroy()
			expect(builds).toBe(1)
			expect(umbraCount).toBe(1)
			expect(anchorAfter).toBe(anchor)
		end)

		it("tears down a reused umbra and expires its proofs when the camera enters the occluder", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			occlusion:buildUmbrae()
			local umbraCountBefore = occlusion._umbraCount
			local generationBefore = occlusion._generation

			-- The camera steps inside the wall, where backfaces render
			-- transparent and the player sees straight through it. With no
			-- odometer movement the reuse gate would keep the built planes,
			-- so the entry itself must tear the umbra down and expire the
			-- hidden proofs the wall anchored, whose sightline argument no
			-- longer matches what the renderer shows.
			CameraCache.Position = Vector3.new(50, 50, -285)
			occlusion:buildUmbrae()

			local umbraCountAfter = occlusion._umbraCount
			local generationAfter = occlusion._generation
			wall:Destroy()
			expect(umbraCountBefore).toBe(1)
			expect(umbraCountAfter).toBe(0)
			expect(generationAfter).toBeGreaterThan(generationBefore)
		end)

		it("rebuilds once the drift since the build crosses the tightest pad", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()
			local anchor = occlusion._cameraPosVoxels

			-- Twenty studs of drift blows past the 9 stud pad budget, so the
			-- planes rebuild from the camera's current position, the debit
			-- resets, and the anchor moves with it.
			CameraCache.Position += Vector3.new(20, 0, 0)
			cullThrottle._motion._accumT += 0.2
			occlusion:buildUmbrae()

			local builds = getBuilds()
			local debit = occlusion._allowanceDebit
			local anchorAfter = occlusion._cameraPosVoxels
			wall:Destroy()
			expect(builds).toBe(2)
			expect(debit).toBe(0)
			expect(anchorAfter).never.toBe(anchor)
		end)

		it("rebuilds when the occluder generation bumps even with no drift", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()

			-- A generation bump is what any occluder move or resize fires, and
			-- it means the built planes describe stale geometry, so reuse must
			-- yield no matter how still the camera held. The bump is invoked
			-- directly to keep the test synchronous (a deferred property
			-- signal would yield a frame, letting the render loop's own build
			-- consume the rebuild first), and the property connections that
			-- fire it are covered by the registry tests.
			occlusion:_bumpGeneration()
			occlusion:buildUmbrae()

			local builds = getBuilds()
			wall:Destroy()
			expect(builds).toBe(2)
		end)

		it("rebuilds when the selection would admit a new occluder", function()
			local occlusion = cullThrottle._occlusion
			local wallA = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wallA)

			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()
			local umbraCountAfterFirstBuild = occlusion._umbraCount

			-- A second wall entering the selection means the built set no
			-- longer covers what this frame would build, so reuse yields.
			local wallB = createMockPart(Vector3.new(50, 50, -500), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wallB)
			occlusion:buildUmbrae()

			local builds = getBuilds()
			local umbraCount = occlusion._umbraCount
			wallA:Destroy()
			wallB:Destroy()
			expect(umbraCountAfterFirstBuild).toBe(1)
			expect(builds).toBe(3)
			expect(umbraCount).toBe(2)
		end)

		it("rebuilds after a visibility cache flush even though the odometer reads no drift", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()

			-- A flush re-anchors the odometer at zero, so the drift since the
			-- build is unmeasurable and could hide a camera swap. The flush
			-- count is what forces the rebuild.
			cullThrottle._motion:flushVisibilityCache()
			occlusion:buildUmbrae()

			local builds = getBuilds()
			wall:Destroy()
			expect(builds).toBe(2)
		end)

		it("debits allowances handed out on a reuse frame by the drift since the build", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			occlusion:buildUmbrae()
			-- The first box hides deep behind the wall and the second sits in
			-- front of its cap, so one exercises the hidden grant and the
			-- other the measured clear grant.
			local _, hiddenBefore = occlusion:testBoxOcclusion(occlusion._fullUmbraMask, 0, 0, -8, 1, 1, -7)
			local clearBefore = occlusion:measureClearAllowance(occlusion._fullUmbraMask, 0, 0, -2, 1, 1, -1)
			expect(hiddenBefore).toBeGreaterThan(0.05)
			expect(clearBefore).toBeGreaterThan(0.05)

			cullThrottle._motion._accumT += 0.05
			occlusion:buildUmbrae()
			local _, hiddenAfter = occlusion:testBoxOcclusion(occlusion._fullUmbraMask, 0, 0, -8, 1, 1, -7)
			local clearAfter = occlusion:measureClearAllowance(occlusion._fullUmbraMask, 0, 0, -2, 1, 1, -1)

			wall:Destroy()
			expect(hiddenAfter).toBeCloseTo(hiddenBefore - 0.05, 5)
			expect(clearAfter).toBeCloseTo(clearBefore - 0.05, 5)
		end)

		it("rules out a whole frame of measuring when the motion floor beats the shape ceiling", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			-- Five voxels of translation last frame towers over this wall's
			-- 1.9 voxel shape ceiling, so no measuring pass this frame could
			-- stamp anything that survives, and the measures themselves bail
			-- to zero if called anyway.
			cullThrottle._motion._lastTranslationDelta = 5
			occlusion:buildUmbrae()
			local measuresUsefulFast = occlusion._measuresUseful
			local motionFloorFast = occlusion._motionFloor
			local bailedAllowance = occlusion:measureClearAllowance(occlusion._fullUmbraMask, 0, 0, -2, 1, 1, -1)

			-- The camera settling re-arms the measures on the very next frame.
			cullThrottle._motion._lastTranslationDelta = 0
			occlusion:buildUmbrae()
			local measuresUsefulStill = occlusion._measuresUseful

			wall:Destroy()
			expect(measuresUsefulFast).toBe(false)
			expect(motionFloorFast).toBe(5)
			expect(bailedAllowance).toBe(0)
			expect(measuresUsefulStill).toBe(true)
		end)

		it("bumps the generation once while the camera stays inside and again on re-entry", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)
			occlusion:buildUmbrae()

			-- Entering the wall bumps the generation, and holding the camera
			-- there must not bump again, or every embedded frame would flush
			-- proofs the entry already expired.
			local generationBeforeEntry = occlusion._generation
			CameraCache.Position = Vector3.new(50, 50, -285)
			occlusion:buildUmbrae()
			local generationAfterEntry = occlusion._generation
			occlusion:buildUmbrae()
			local generationAfterHold = occlusion._generation

			-- Stepping back out clears the inside mark without a bump, since
			-- everything the wall anchored expired on the way in.
			CameraCache.Position = Vector3.new(50, 50, 50)
			occlusion:buildUmbrae()
			local insideAfterExit = occlusion._cameraInsideOccluder[wall]
			local generationAfterExit = occlusion._generation

			-- Re-entering is a fresh transition, so the proofs cached while
			-- the camera was outside must expire again.
			CameraCache.Position = Vector3.new(50, 50, -285)
			occlusion:buildUmbrae()
			local generationAfterReentry = occlusion._generation

			wall:Destroy()
			expect(generationAfterEntry).toBeGreaterThan(generationBeforeEntry)
			expect(generationAfterHold).toBe(generationAfterEntry)
			expect(insideAfterExit).toBeNil()
			expect(generationAfterExit).toBe(generationAfterHold)
			expect(generationAfterReentry).toBeGreaterThan(generationAfterExit)
		end)

		it("rebuilds when the drift since the build reaches the pad budget exactly", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)

			local getBuilds = countUmbraBuilds()
			occlusion:buildUmbrae()

			-- The pad budget is the drift at which the reused planes'
			-- soundness argument runs out, so landing on it exactly must
			-- rebuild rather than squeeze out one more reuse frame.
			cullThrottle._motion._accumT = occlusion._buildAccumT + occlusion._reusePadBudget
			occlusion:buildUmbrae()

			local builds = getBuilds()
			wall:Destroy()
			expect(builds).toBe(2)
		end)

		it("bumps the build count on a teardown frame and holds it across bare frames", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)
			occlusion:buildUmbrae()
			local countAfterBuild = occlusion._buildCount

			-- Dropping the cap to zero leaves planes standing from the last
			-- build, and tearing them down changes what the search tests
			-- against, so the count must move or the whole-frame replay
			-- would keep serving results that assumed the umbra still stood.
			cullThrottle:SetMaxOccluders(0)
			occlusion:buildUmbrae()
			local countAfterTeardown = occlusion._buildCount

			-- A bare frame following a bare frame changes nothing, so the
			-- replay gate stays open.
			occlusion:buildUmbrae()
			local countAfterBareFrame = occlusion._buildCount

			wall:Destroy()
			expect(countAfterTeardown).toBe(countAfterBuild + 1)
			expect(countAfterBareFrame).toBe(countAfterTeardown)
		end)

		it("holds the build count on reuse frames and bumps it on a rebuild of the same selection", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)
			occlusion:buildUmbrae()
			local countAfterBuild = occlusion._buildCount

			-- A reuse frame keeps the plane sets as they stand, so the count
			-- holds and the search's replay can trust that nothing changed.
			occlusion:buildUmbrae()
			local countAfterReuse = occlusion._buildCount

			-- A generation bump forces a reconstruction, and even though the
			-- wall hasn't moved and the planes come out identical, the count
			-- moves, since the replay gate only needs an unchanged count to
			-- mean unchanged umbrae and never the reverse.
			occlusion:_bumpGeneration()
			occlusion:buildUmbrae()
			local countAfterRebuild = occlusion._buildCount

			wall:Destroy()
			expect(countAfterReuse).toBe(countAfterBuild)
			expect(countAfterRebuild).toBe(countAfterBuild + 1)
		end)

		it("keeps the build count still while rebuilds keep producing nothing", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(wall)
			occlusion:buildUmbrae()

			-- Entering the wall tears the umbra down, which counts as a
			-- build, and the embedded frames after it rebuild nothing from
			-- nothing, which must not count, or a camera parked inside an
			-- occluder would close the replay gate every frame.
			CameraCache.Position = Vector3.new(50, 50, -285)
			occlusion:buildUmbrae()
			local countAfterTeardown = occlusion._buildCount
			occlusion:buildUmbrae()
			local countAfterEmbeddedFrame = occlusion._buildCount

			wall:Destroy()
			expect(countAfterEmbeddedFrame).toBe(countAfterTeardown)
		end)
	end)

	describe("clear generation", function()
		local savedCameraCFrame

		beforeEach(function()
			savedCameraCFrame = workspace.CurrentCamera.CFrame
			-- A canonical world-aligned pose makes the occluder geometry below
			-- deterministic. The camera cache refresh is called synchronously
			-- rather than waiting on the deferred change signal.
			workspace.CurrentCamera.CFrame = CFrame.new(Vector3.new(50, 50, 50), Vector3.new(50, 50, -1000))
			CameraCache.cframeChanged()
		end)

		afterEach(function()
			workspace.CurrentCamera.CFrame = savedCameraCFrame
			task.wait()
		end)

		it("bumps when the selection admits an occluder it lacked last frame", function()
			local occlusion = cullThrottle._occlusion
			local frontWall = createMockPart(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			local backWall = createMockPart(Vector3.new(50, 50, 400), Vector3.new(400, 400, 40))
			occlusion:_registerOccluder(frontWall)
			occlusion:_registerOccluder(backWall)

			-- Only the front wall is in view, so the first build selects just
			-- it, and that first selection is itself an entrant.
			occlusion:buildUmbrae()
			local umbraCountAfterFirstBuild = occlusion._umbraCount
			local generationAfterFirstBuild = occlusion._clearGeneration

			-- Rebuilding with the same selection must not bump, or every
			-- frame would flush every clear proof.
			occlusion:buildUmbrae()
			local generationAfterRepeat = occlusion._clearGeneration

			-- Turning around swaps the selection to the back wall, an entrant
			-- that no cached clear proof was tested against.
			workspace.CurrentCamera.CFrame = CFrame.new(Vector3.new(50, 50, 50), Vector3.new(50, 50, 1000))
			CameraCache.cframeChanged()
			occlusion:buildUmbrae()

			local umbraCount = occlusion._umbraCount
			local generationAfterTurn = occlusion._clearGeneration
			frontWall:Destroy()
			backWall:Destroy()
			expect(umbraCountAfterFirstBuild).toBe(1)
			expect(generationAfterRepeat).toBe(generationAfterFirstBuild)
			expect(umbraCount).toBe(1)
			expect(generationAfterTurn).toBeGreaterThan(generationAfterFirstBuild)
		end)

		it("holds when the selection only shrinks and bumps when the member returns", function()
			local occlusion = cullThrottle._occlusion
			-- The big wall outscores the small one by projected size, so it
			-- deterministically wins a solo slot.
			local bigWall = createMockPart(Vector3.new(50, 50, -200), Vector3.new(800, 800, 40))
			local smallWall = createMockPart(Vector3.new(50, 50, -500), Vector3.new(200, 200, 40))
			occlusion:_registerOccluder(bigWall)
			occlusion:_registerOccluder(smallWall)

			cullThrottle:SetMaxOccluders(2)
			occlusion:buildUmbrae()
			local umbraCountAfterBoth = occlusion._umbraCount
			local generationAfterBoth = occlusion._clearGeneration

			-- Dropping to one slot shrinks the selection, which can't put a
			-- box inside an umbra, so the counter holds.
			cullThrottle:SetMaxOccluders(1)
			occlusion:buildUmbrae()
			local umbraCountAfterShrink = occlusion._umbraCount
			local generationAfterShrink = occlusion._clearGeneration

			-- Widening the cap lets the small wall back in, an entrant that
			-- cached clear proofs were never tested against.
			cullThrottle:SetMaxOccluders(2)
			occlusion:buildUmbrae()

			local umbraCount = occlusion._umbraCount
			local generationAfterReturn = occlusion._clearGeneration
			bigWall:Destroy()
			smallWall:Destroy()
			expect(umbraCountAfterBoth).toBe(2)
			expect(umbraCountAfterShrink).toBe(1)
			expect(generationAfterShrink).toBe(generationAfterBoth)
			expect(umbraCount).toBe(2)
			expect(generationAfterReturn).toBeGreaterThan(generationAfterBoth)
		end)

		it("bumps alongside the occluder generation when an occluder mutates", function()
			local occlusion = cullThrottle._occlusion
			local wall = createMockOccluder(Vector3.new(50, 50, -300), Vector3.new(400, 400, 40))
			task.wait()

			-- A moved occluder reshapes its umbra, which can falsify clear
			-- proofs just as easily as hidden ones. The next build's pose poll
			-- catches the move and bumps both generations together.
			local generationBefore = occlusion._clearGeneration
			wall.CFrame = CFrame.new(50, 60, -300)
			occlusion:buildUmbrae()

			local generationAfter = occlusion._clearGeneration
			wall:Destroy()
			expect(generationAfter).toBeGreaterThan(generationBefore)
		end)
	end)

	describe("generation wrap", function()
		it("wraps the occluder generation at the proof packing limit and flushes every occlusion proof", function()
			local occlusion = cullThrottle._occlusion
			local bucketProofs = cullThrottle._visibilityCache._bucketOcclusionProofs
			local voxelProofs = cullThrottle._visibilityCache._voxelOcclusionProofs

			-- Cached proofs pack their generation into an f32 component that
			-- is only exact up to 2^24, so the counter's next step must land
			-- back on zero and flush every cached occlusion proof at both
			-- granularities, or a wrapped counter could falsely match an
			-- ancient proof.
			occlusion._generation = 2 ^ 24 - 1
			bucketProofs[Vector3.new(0, 10, 0)] = hiddenOcclusionProof(5, occlusion._generation)
			bucketProofs[Vector3.new(1, 10, 0)] = clearOcclusionProof(5, occlusion._clearGeneration)
			voxelProofs[Vector3.new(1, 41, 1)] = hiddenOcclusionProof(5, occlusion._generation)
			voxelProofs[Vector3.new(2, 41, 1)] = clearOcclusionProof(5, occlusion._clearGeneration)

			-- The clear counter is far from its own limit, so it advances
			-- alongside as it always does.
			local clearGenerationBefore = occlusion._clearGeneration
			occlusion:_bumpGeneration()

			expect(occlusion._generation).toBe(0)
			expect(occlusion._clearGeneration).toBe(clearGenerationBefore + 1)
			expect(next(bucketProofs)).toBeNil()
			expect(next(voxelProofs)).toBeNil()
		end)

		it("wraps the clear generation at the proof packing limit and flushes every occlusion proof", function()
			local occlusion = cullThrottle._occlusion
			local bucketProofs = cullThrottle._visibilityCache._bucketOcclusionProofs
			local voxelProofs = cullThrottle._visibilityCache._voxelOcclusionProofs

			-- The clear counter shares the packing and so shares the wrap,
			-- flushing both proof tables while the occluder generation stays
			-- untouched.
			occlusion._clearGeneration = 2 ^ 24 - 1
			bucketProofs[Vector3.new(0, 10, 0)] = hiddenOcclusionProof(5, occlusion._generation)
			bucketProofs[Vector3.new(1, 10, 0)] = clearOcclusionProof(5, occlusion._clearGeneration)
			voxelProofs[Vector3.new(1, 41, 1)] = hiddenOcclusionProof(5, occlusion._generation)
			voxelProofs[Vector3.new(2, 41, 1)] = clearOcclusionProof(5, occlusion._clearGeneration)

			local generationBefore = occlusion._generation
			occlusion:_bumpClearGeneration()

			expect(occlusion._clearGeneration).toBe(0)
			expect(occlusion._generation).toBe(generationBefore)
			expect(next(bucketProofs)).toBeNil()
			expect(next(voxelProofs)).toBeNil()
		end)
	end)

	describe("box versus umbra verdicts", function()
		it("occludes a box fully behind the wall with a depth-scaled allowance beyond the pad", function()
			local wall = stageFaceOnWallUmbra(cullThrottle)

			-- The pad floor for this wall is 0.09 voxels. The pivot bound does
			-- far better for this box: its minimum silhouette margin is
			-- 4/sqrt(2) - sqrt(3)/2 (about 1.962 voxels, measured through the
			-- sphere prefilter), the umbra's minimum edge distance is
			-- 1.9 * sqrt(2), and the box reaches at most 4 + sqrt(3)/2 voxels
			-- from the camera, so the allowance is about
			-- 1.962 * 2.687 / (4.866 + 2.687) shaved by the safety margin.
			local occluded, allowance = cullThrottle._occlusion:testBoxOcclusion(1, -0.5, -0.5, -4.5, 0.5, 0.5, -3.5)
			expect(occluded).toBe(true)
			expect(allowance).toBeCloseTo(0.6881, 3)

			wall:Destroy()
		end)

		it("measures a cap prune's clear allowance as the shape allowance", function()
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._umbraShapeAllowances[1] = 1.5

			-- The box sits fully outside the world-fixed cap plane, so this
			-- umbra can never touch it or anything inside it, and the prune
			-- survives as long as the plane set keeps its shape, shaved by
			-- the safety margin.
			local occluded, _, prunedMask =
				cullThrottle._occlusion:testBoxOcclusion(1, -0.5, -0.5, -1.25, 0.5, 0.5, -0.75)
			expect(occluded).toBe(false)
			expect(prunedMask).toBe(0)
			local allowance = cullThrottle._occlusion:measureClearAllowance(1, -0.5, -0.5, -1.25, 0.5, 0.5, -0.75)
			expect(allowance).toBeCloseTo(1.49, 5)
		end)

		it("keeps a box straddling the umbra boundary visible without pruning", function()
			local wall = stageFaceOnWallUmbra(cullThrottle)

			-- The box rides the silhouette plane, so part of it may be hidden
			-- but nothing is provable, and children of the box could still
			-- land fully inside, so the bit stays set.
			local occluded, _, prunedMask = cullThrottle._occlusion:testBoxOcclusion(1, 3.5, -0.5, -4.5, 4.5, 0.5, -3.5)
			expect(occluded).toBe(false)
			expect(prunedMask).toBe(1)

			wall:Destroy()
		end)

		it("measures a silhouette prune's clear allowance from that plane's pivot bound", function()
			local wall = stageFaceOnWallUmbra(cullThrottle)

			-- The pruning silhouette plane measures a 2/sqrt(2) - sqrt(3)/2
			-- margin through the sphere prefilter, and the box reaches at most
			-- sqrt(52) + sqrt(3)/2 voxels from the camera, so the clear
			-- allowance is about 0.548 * 2.687 / (8.077 + 2.687) shaved by
			-- the safety margin.
			local occluded, _, prunedMask = cullThrottle._occlusion:testBoxOcclusion(1, 5.5, -0.5, -4.5, 6.5, 0.5, -3.5)
			expect(occluded).toBe(false)
			expect(prunedMask).toBe(0)
			local allowance = cullThrottle._occlusion:measureClearAllowance(1, 5.5, -0.5, -4.5, 6.5, 0.5, -3.5)
			expect(allowance).toBeCloseTo(0.1268, 3)

			wall:Destroy()
		end)

		it("prunes through the AABB gate and recovers durability in the measuring pass", function()
			local wall = stageFaceOnWallUmbra(cullThrottle)

			-- The box sits far off to the side, outside even the scaled
			-- corner hull, so the gate prunes the umbra without any plane
			-- math. The measuring pass never gates, so the clear allowance
			-- is still recovered from the plane margins.
			local occluded, allowance, prunedMask =
				cullThrottle._occlusion:testBoxOcclusion(1, 80, -0.5, -4.5, 81, 0.5, -3.5)
			expect(occluded).toBe(false)
			expect(prunedMask).toBe(0)
			expect(allowance).toBe(0)
			expect(cullThrottle._occlusion:measureClearAllowance(1, 80, -0.5, -4.5, 81, 0.5, -3.5)).toBeGreaterThan(0)

			wall:Destroy()
		end)

		it("measures a not-occluded allowance from a cap poke-out witness", function()
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._umbraShapeAllowances[1] = 3

			-- The box straddles the slab's cap plane, so no whole-box outside
			-- margin exists, but its front corner pokes 0.4 voxels out, and a
			-- cap is world fixed, so the witness holds for as long as the
			-- plane set keeps its shape, shaved by the safety margin.
			local occluded, _, prunedMask = cullThrottle._occlusion:testBoxOcclusion(1, -0.5, -0.5, 1.5, 0.5, 0.5, 2.5)
			expect(occluded).toBe(false)
			expect(prunedMask).toBe(1)
			local allowance = cullThrottle._occlusion:measureNotOccludedAllowance(1, -0.5, -0.5, 1.5, 0.5, 0.5, 2.5)
			expect(allowance).toBeCloseTo(2.99, 5)
		end)

		it("measures a not-occluded allowance from a silhouette poke-out witness through the pivot bound", function()
			local occlusion = cullThrottle._occlusion
			occlusion._umbraCount = 1
			occlusion._fullUmbraMask = 1
			occlusion._umbraPlaneNormals[1] = { Vector3.new(1, 0, 0) }
			occlusion._umbraPlaneOffsets[1] = { 0 }
			occlusion._umbraPlaneCounts[1] = 1
			occlusion._umbraCapCounts[1] = 0
			occlusion._umbraAllowances[1] = 0
			occlusion._umbraShapeAllowances[1] = 5
			occlusion._umbraEdgeDistances[1] = 10
			occlusion._umbraBoundsMin[1] = Vector3.one * -math.huge
			occlusion._umbraBoundsMax[1] = Vector3.one * math.huge
			occlusion._cameraPosVoxels = Vector3.zero

			-- The box pokes 0.5 voxels out of the single silhouette plane and
			-- reaches sqrt(0.5) + sqrt(0.75) voxels from the camera, so the
			-- witness rides the pivot bound 0.5 * 10 / (1.5731 + 10), shaved
			-- by the safety margin.
			local allowance = occlusion:measureNotOccludedAllowance(1, -0.5, 0, 0, 0.5, 1, 1)
			expect(allowance).toBeCloseTo(0.42204, 4)
		end)

		it("measures zero not-occluded allowance for a box with no witness", function()
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._umbraShapeAllowances[1] = 3

			-- Every point of the box sits behind the cap by at least 0.6
			-- voxels, so no plane offers a poke-out witness and the
			-- measurement reports that no durable claim exists.
			expect(cullThrottle._occlusion:measureNotOccludedAllowance(1, -0.5, -0.5, 3, 0.5, 0.5, 4)).toBe(0)
		end)

		it("takes the weakest umbra's witness when several are in play", function()
			-- Umbra 1 is the slab, whose cap witness is worth its whole shape
			-- allowance, and umbra 2 is a single silhouette plane with a much
			-- tighter pivot bound, so the cell's allowance is the silhouette's.
			stageSlabUmbra(cullThrottle)
			local occlusion = cullThrottle._occlusion
			occlusion._umbraShapeAllowances[1] = 3
			occlusion._umbraCount = 2
			occlusion._fullUmbraMask = 3
			occlusion._umbraPlaneNormals[2] = { Vector3.new(1, 0, 0) }
			occlusion._umbraPlaneOffsets[2] = { 0 }
			occlusion._umbraPlaneCounts[2] = 1
			occlusion._umbraCapCounts[2] = 0
			occlusion._umbraAllowances[2] = 0
			occlusion._umbraShapeAllowances[2] = 5
			occlusion._umbraEdgeDistances[2] = 10
			occlusion._umbraBoundsMin[2] = Vector3.one * -math.huge
			occlusion._umbraBoundsMax[2] = Vector3.one * math.huge

			local allowance = occlusion:measureNotOccludedAllowance(3, -0.5, 0, 0, 0.5, 1, 1)
			expect(allowance).toBeCloseTo(0.42204, 4)
			expect(allowance).toBeLessThan(2.99)
		end)

		it("occludes a box hidden only by the second umbra", function()
			stageOpposingSlabUmbrae(cullThrottle)

			-- The box sits fully outside the first umbra and fully inside
			-- the second, so the walk must prune bit one and keep going to
			-- find the hidden verdict at bit two, returning the caller's
			-- mask untouched alongside the second slab's pad allowance.
			local occluded, allowance, mask = cullThrottle._occlusion:testBoxOcclusion(3, 0, 0, -4, 1, 1, -3)
			expect(occluded).toBe(true)
			expect(allowance).toBe(0.5)
			expect(mask).toBe(3)
		end)

		it("prunes only the umbra a contested box sits fully outside of", function()
			stageOpposingSlabUmbrae(cullThrottle)

			-- The box straddles the second slab's plane while sitting fully
			-- outside the first, so the verdict stays visible, the first bit
			-- is pruned for the box's children, and the straddled bit stays.
			local occluded, _, prunedMask = cullThrottle._occlusion:testBoxOcclusion(3, 0, 0, -2.4, 1, 1, -1.4)
			expect(occluded).toBe(false)
			expect(prunedMask).toBe(2)
		end)

		it("leaves an umbra untested when the incoming mask excludes it", function()
			stageOpposingSlabUmbrae(cullThrottle)

			-- The box sits deep inside the first umbra, but the caller's
			-- mask names only the second, so the first must contribute
			-- nothing to the verdict and the box comes back visible with the
			-- second pruned.
			local occluded, allowance, prunedMask = cullThrottle._occlusion:testBoxOcclusion(2, 0, 0, 3, 1, 1, 4)
			expect(occluded).toBe(false)
			expect(allowance).toBe(0)
			expect(prunedMask).toBe(0)
		end)

		it("returns a final verdict when every umbra is pruned with slots remaining", function()
			stageOpposingSlabUmbrae(cullThrottle)

			-- The caller's mask names only the first umbra and the box sits
			-- fully outside it, so the walk runs out of live bits with the
			-- second umbra's slot still ahead and the verdict is already
			-- final.
			local occluded, allowance, prunedMask = cullThrottle._occlusion:testBoxOcclusion(1, 0, 0, -4, 1, 1, -3)
			expect(occluded).toBe(false)
			expect(allowance).toBe(0)
			expect(prunedMask).toBe(0)
		end)

		it("measures a clear allowance from the weakest umbra's witness", function()
			stageOpposingSlabUmbrae(cullThrottle)
			local occlusion = cullThrottle._occlusion
			occlusion._umbraShapeAllowances[1] = 3
			occlusion._umbraShapeAllowances[2] = 1.5

			-- The box sits fully outside both caps, and a cap witness is
			-- worth its umbra's whole shape allowance, so the proof's grant
			-- is the smaller umbra's ceiling shaved by the safety margin.
			local allowance = occlusion:measureClearAllowance(3, 0, 0, -1.4, 1, 1, -0.4)
			expect(allowance).toBeCloseTo(1.49, 5)
		end)
	end)

	describe("search integration", function()
		it("skips a bucket with a valid occlusion proof before any frustum work", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))

			-- Proofs are only honored while some occluder is registered, so
			-- give the staged proof a live anchor. Registering directly keeps
			-- the test synchronous and doesn't bump the generation.
			local wall = createMockPart(Vector3.new(0, 0, -300), Vector3.new(100, 100, 10))
			cullThrottle._occlusion:_registerOccluder(wall)

			-- A staged proof at the current generation with plenty of expiry
			-- left must settle the bucket in two comparisons.
			local search = cullThrottle._search
			local proofs = cullThrottle._visibilityCache._bucketOcclusionProofs
			proofs[Vector3.new(0, 10, 0)] = hiddenOcclusionProof(5, cullThrottle._occlusion._generation)

			local getCalls = countClassifyCalls()
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)).toBe(0)
			expect(getCalls()).toBe(0)
			expect(search._visibleVoxelCount).toBe(0)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(1)

			-- A generation mismatch means the anchoring occluder changed, so
			-- the proof is dead and the bucket classifies fresh (fully inside
			-- this frustum, so its voxel bulk-appends).
			proofs[Vector3.new(0, 10, 0)] = hiddenOcclusionProof(5, cullThrottle._occlusion._generation + 7)
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)

			part:Destroy()
			wall:Destroy()
		end)

		it("skips the bucket proof lookup entirely when no occluders are registered", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))

			-- With an empty occluder registry no cached proof can have a live
			-- anchor, so seeding ignores even a proof staged at the current
			-- generation and the bucket classifies fresh. This is what makes
			-- occlusion free for a place that never tags an occluder.
			local search = cullThrottle._search
			local proofs = cullThrottle._visibilityCache._bucketOcclusionProofs
			proofs[Vector3.new(0, 10, 0)] = hiddenOcclusionProof(5, cullThrottle._occlusion._generation)

			local getCalls = countClassifyCalls()
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(0)

			part:Destroy()
		end)

		it("skips a fully occluded volume and stamps its voxels' occlusion proofs", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			stageSlabUmbra(cullThrottle)

			local keys = { Vector3.new(1, 41, 2), Vector3.new(2, 42, 3) }
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end

			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 2, 4, 44, 4, 1, 2, 0b11111, math.huge, 1)

			-- The volume dies at the top with no appends and no splits. Each
			-- voxel gets an occlusion proof carrying the umbra's translation
			-- allowance and the live generation, while the frustum proofs
			-- stay untouched for whenever the occlusion lifts.
			expect(search._visibleVoxelCount).toBe(0)
			expect(search._volumesToCheckSize).toBe(0)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(2)
			for _, key in keys do
				expect(voxelProofs[key]).toBeNil()
				expect(voxelOcclusionProofs[key]).toEqual(
					hiddenOcclusionProof(0.5, cullThrottle._occlusion._generation)
				)
			end
		end)

		it("resolves a contested volume from voxel occlusion proofs without splitting", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)

			-- Six hidden cells carry valid occlusion proofs and one clear cell
			-- sits in front of the slab. The walk settles the proven cells in
			-- two comparisons each, so the only umbra tests are the volume's
			-- own box test and the clear cell's leaf test.
			local generation = cullThrottle._occlusion._generation
			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			local keys = {
				Vector3.new(0, 41, 2),
				Vector3.new(1, 41, 2),
				Vector3.new(2, 41, 2),
				Vector3.new(0, 41, 3),
				Vector3.new(1, 41, 3),
				Vector3.new(2, 41, 3),
				Vector3.new(1, 41, 0),
			}
			for i, key in keys do
				search._searchVoxelKeys[i] = key
				if key.Z >= 2 then
					voxelOcclusionProofs[key] = hiddenOcclusionProof(5, generation)
				end
			end

			local getUmbraTests = countUmbraTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 7, 0b11111, math.huge, 1)

			expect(getUmbraTests()).toBe(2)
			expect(search._volumesToCheckSize).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(keys[7])
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(6)
		end)

		it("re-proves a voxel whose occlusion proof is from a stale generation", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)

			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			local key = Vector3.new(1, 41, 2)
			search._searchVoxelKeys[1] = key
			voxelOcclusionProofs[key] = hiddenOcclusionProof(5, cullThrottle._occlusion._generation + 7)

			local getUmbraTests = countUmbraTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)

			-- The stale proof is dead, so the cell re-tests at the leaf and
			-- restamps at the live generation.
			expect(getUmbraTests()).toBe(2)
			expect(search._visibleVoxelCount).toBe(0)
			expect(voxelOcclusionProofs[key].Y).toBe(cullThrottle._occlusion._generation)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(1)
		end)

		it("stamps a clear bucket proof and takes the pure frustum path from it next pass", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, -3), stubObjectData(part))
			local wall = stageFaceOnWallUmbra(cullThrottle)
			-- Proofs are only honored while some occluder is registered, so
			-- give the staged proof a live anchor. Registering directly keeps
			-- the test synchronous and doesn't bump either generation.
			cullThrottle._occlusion:_registerOccluder(wall)

			-- The bucket sits high above the wall's umbra (but within its
			-- AABB and inside the roomy frustum), so seeding prunes the
			-- umbra against a silhouette plane with a real margin, appends
			-- the bucket, and stamps a clear proof.
			local search = cullThrottle._search
			local getUmbraTests = countUmbraTests()
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, -4, 4, 44, 0)).toBe(0)
			expect(getUmbraTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)
			local proof = cullThrottle._visibilityCache._bucketOcclusionProofs[Vector3.new(0, 10, -1)]
			expect(proof).toBeDefined()
			expect(proof.X).toBe(-1)
			expect(proof.Y).toBe(cullThrottle._occlusion._clearGeneration)
			expect(proof.Z).toBeGreaterThan(0)

			-- The second pass trusts the clear proof alongside the cached
			-- frustum verdict and appends without a single umbra test.
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, -4, 4, 44, 0)
			expect(getUmbraTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(2)

			part:Destroy()
			wall:Destroy()
		end)

		it("keeps voxel occlusion proofs through rotation and expires them past translation", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)

			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			local key = Vector3.new(1, 41, 2)
			search._searchVoxelKeys[1] = key
			voxelOcclusionProofs[key] = hiddenOcclusionProof(0.25, cullThrottle._occlusion._generation)

			-- Occlusion depends only on camera position, so a huge rotation
			-- reading must not expire the proof. The only umbra test is the
			-- volume's own box test.
			local getUmbraTests = countUmbraTests()
			search:searchVolume(0, 50, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)
			expect(getUmbraTests()).toBe(1)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(1)

			-- Translation past the stored expiry kills the proof, and the
			-- leaf test re-proves the cell with a fresh allowance on top of
			-- the new odometer reading.
			cullThrottle._motion._accumT = 0.3
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)
			expect(getUmbraTests()).toBe(3)
			expect(voxelOcclusionProofs[key]).toEqual(hiddenOcclusionProof(0.8, cullThrottle._occlusion._generation))
		end)

		it("seeds a frustum-inside bucket that straddles an umbra for subdivision instead of bulk-appending", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))
			cullThrottle._grid:insertToVoxel(Vector3.new(2, 42, 3), stubObjectData(part))
			stageSlabUmbra(cullThrottle)

			local search = cullThrottle._search
			local count = search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)

			-- The bucket sits fully inside this frustum but the umbra cuts
			-- through it, so nothing bulk-appends and the keys go to the
			-- subdivision search with every frustum plane already proven. The
			-- umbra mask arrives negated because the bucket seeded unclipped,
			-- telling the root volume to inherit the seeding test's verdict
			-- instead of repeating it.
			expect(count).toBe(2)
			expect(search._visibleVoxelCount).toBe(0)
			expect(volumeCount(search)).toBe(1)
			local volume = popVolume(search)
			expect(volume.planeMask).toBe(0)
			expect(volume.umbraMask).toBe(-1)
			expect(volume.lo).toBe(1)
			expect(volume.hi).toBe(2)
			expect(volume.inheritedSlack).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("seeds a cached-inside bucket with its remaining expiry margin as the inherited slack", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))
			stageSlabUmbra(cullThrottle)

			-- The staged verdict has 5 charge units of side margin and 7 of
			-- far margin left, and with zero accumulated motion the tighter
			-- side margin is exactly what the seeded volume may claim for the
			-- stamps written inside it.
			cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(0, 10, 0)] = {
				state = Frustum.BUCKET_INSIDE,
				armFactor = 1,
				sideExpiry = 5,
				farExpiry = 7,
			}

			local getCalls = countClassifyCalls()
			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)

			expect(getCalls()).toBe(0)
			expect(search._visibleVoxelCount).toBe(0)
			local volume = popVolume(search)
			expect(volume.planeMask).toBe(0)
			expect(volume.umbraMask).toBe(-1)
			expect(volume.inheritedSlack).toBe(5)

			part:Destroy()
		end)

		it("subdivides an umbra-straddling volume and culls only the hidden voxels", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			stageSlabUmbra(cullThrottle)

			-- Eight cold cells, four on each side of the slab plane, are more
			-- than the walk's bail margin tolerates, so the volume falls back
			-- to subdivision.
			local keys = {
				Vector3.new(1, 41, 0),
				Vector3.new(2, 41, 0),
				Vector3.new(1, 41, 1),
				Vector3.new(2, 41, 1),
				Vector3.new(1, 41, 2),
				Vector3.new(2, 41, 2),
				Vector3.new(1, 41, 3),
				Vector3.new(2, 41, 3),
			}
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end

			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 8, 0b11111, math.huge, 1)
			drainVolumeStack(search, 0, 0, roomyFrustumPlanes)

			-- The four cells in front of the plane stay visible (two are fully
			-- clear and two straddle the boundary, which is the conservative
			-- direction), and the four behind it die at whatever split size
			-- proved them hidden, picking up occlusion proofs while their
			-- frustum history stays intact.
			expect(search._visibleVoxelCount).toBe(4)
			local visible = {}
			for i = 1, search._visibleVoxelCount do
				visible[search._pendingVoxelKeys[i]] = true
			end
			expect(visible[keys[1]]).toBe(true)
			expect(visible[keys[2]]).toBe(true)
			expect(visible[keys[3]]).toBe(true)
			expect(visible[keys[4]]).toBe(true)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(4)
			for i = 5, 8 do
				expect(voxelProofs[keys[i]]).toBeNil()
				expect(voxelOcclusionProofs[keys[i]]).toBeDefined()
			end
		end)

		it("skips an occluded leaf voxel with an occlusion stamp and no frustum stamp", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)

			local voxelKey = Vector3.new(2, 41, 2)
			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 2, 41, 2, voxelKey, 1)

			expect(search._visibleVoxelCount).toBe(0)
			expect(cullThrottle._visibilityCache._voxelProofs[voxelKey]).toBeNil()
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[voxelKey]).toEqual(
				hiddenOcclusionProof(0.5, cullThrottle._occlusion._generation)
			)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(1)

			-- The same cell with no live mask takes the normal frustum path.
			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 2, 41, 2, voxelKey, 0)
			expect(search._visibleVoxelCount).toBe(1)
		end)

		it("stamps a not-occluded proof at the leaf and settles the cell from it while it lives", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._umbraShapeAllowances[1] = 3

			-- The cell in front of the slab can't be proven hidden, so its
			-- leaf test stamps a not-occluded proof carrying the cap
			-- witness's allowance on top of the current odometer reading.
			local key = Vector3.new(1, 41, 0)
			search._searchVoxelKeys[1] = key
			local getUmbraTests = countUmbraTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)
			expect(getUmbraTests()).toBe(2)
			expect(search._visibleVoxelCount).toBe(1)
			local proof = cullThrottle._visibilityCache._voxelOcclusionProofs[key]
			expect(proof).toBeDefined()
			expect(proof.X).toBe(-1)
			expect(proof.Y).toBe(cullThrottle._occlusion._clearGeneration)
			expect(proof.Z).toBeCloseTo(2.99, 5)

			-- Within the allowance the walk hands the cell back to its
			-- frustum proof, so the second pass appends it with only the
			-- volume's own box test.
			cullThrottle._motion._accumT = 2.5
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)
			expect(getUmbraTests()).toBe(3)
			expect(search._visibleVoxelCount).toBe(2)

			-- Past the allowance the proof is dead, so the cell takes a
			-- fresh leaf test and restamps on top of the new reading.
			cullThrottle._motion._accumT = 3.5
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)
			expect(getUmbraTests()).toBe(5)
			expect(search._visibleVoxelCount).toBe(3)
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[key].Z).toBeCloseTo(6.49, 5)
		end)

		it("stamps not-occluded proofs across a volume slice when its test prunes the last umbra", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._umbraShapeAllowances[1] = 3

			-- The whole volume sits in front of the slab, so its own test
			-- prunes the umbra, and being fully outside inherits downward,
			-- so one measuring pass stamps both cells with the cap prune's
			-- allowance through a single shared proof.
			local keys = { Vector3.new(1, 41, 0), Vector3.new(2, 42, 0) }
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end
			local getUmbraTests = countUmbraTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 1, 1, 2, 0b11111, math.huge, 1)

			expect(getUmbraTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(2)
			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			for _, key in keys do
				local proof = voxelOcclusionProofs[key]
				expect(proof).toBeDefined()
				expect(proof.X).toBe(-1)
				expect(proof.Y).toBe(cullThrottle._occlusion._clearGeneration)
				expect(proof.Z).toBeCloseTo(2.99, 5)
			end
		end)

		it("skips stamps whose allowance cannot outlive the motion floor", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)
			local occlusion = cullThrottle._occlusion

			-- The slab's staged pad allowance is 0.5 voxels. With 0.6 voxels
			-- of translation last frame the proof would expire before it was
			-- ever trusted, so the leaf keeps the verdict but skips the write
			-- and the cell just re-tests next frame.
			occlusion._motionFloor = 0.6
			local voxelKey = Vector3.new(2, 41, 2)
			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 2, 41, 2, voxelKey, 1)
			expect(search._visibleVoxelCount).toBe(0)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(1)
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[voxelKey]).toBeNil()

			-- At exactly half a voxel of motion the allowance survives one
			-- repeat of it (expiries compare inclusively), so the stamp is
			-- worth its write again.
			occlusion._motionFloor = 0.5
			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 2, 41, 2, voxelKey, 1)
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[voxelKey]).toBeDefined()
		end)

		it("skips slice-wide hidden stamps that could not outlive the motion floor", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._motionFloor = 0.6

			local keys = { Vector3.new(1, 41, 2), Vector3.new(2, 42, 3) }
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 2, 4, 44, 4, 1, 2, 0b11111, math.huge, 1)

			-- The volume still dies as hidden, so the verdict is unchanged,
			-- and next frame's box test re-proves the slice for one test
			-- instead of paying a write per cell for already-expired proofs.
			expect(search._visibleVoxelCount).toBe(0)
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(2)
			for _, key in keys do
				expect(cullThrottle._visibilityCache._voxelOcclusionProofs[key]).toBeNil()
			end
		end)

		it("skips the leaf measuring pass on frames where nothing it stamps could survive", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)
			cullThrottle._occlusion._umbraShapeAllowances[1] = 3
			local occlusion = cullThrottle._occlusion

			-- The frame ruled all measuring out, so the clear cell appends as
			-- visible without a not-occluded stamp, and with the floor above
			-- zero the fallback zero-allowance stamp is skipped too.
			occlusion._measuresUseful = false
			occlusion._motionFloor = 1
			local key = Vector3.new(1, 41, 0)
			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 1, 41, 0, key, 1)
			expect(search._visibleVoxelCount).toBe(1)
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[key]).toBeNil()

			-- A still frame stamps as always, zero allowance included, so a
			-- parked camera keeps settling the cell from cache.
			occlusion._motionFloor = 0
			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 1, 41, 0, key, 1)
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[key]).toBeDefined()
		end)

		it("skips the root volume's redundant umbra test when the bucket seeds unclipped", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 0), stubObjectData(part))
			stageSlabUmbra(cullThrottle)

			-- The query box contains the whole bucket, so the root volume is
			-- the bucket's exact box and inherits the seeding test's verdict.
			-- The only umbra tests are the seeding test itself and the cell's
			-- leaf test.
			local search = cullThrottle._search
			local getUmbraTests = countUmbraTests()
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getUmbraTests()).toBe(1)
			drainVolumeStack(search, 0, 0, roomyFrustumPlanes)
			expect(getUmbraTests()).toBe(2)
			expect(search._visibleVoxelCount).toBe(1)

			-- A clipped query leaves the root volume smaller than the bucket,
			-- so its own test still runs. The cell itself settles from the
			-- zero-allowance not-occluded stamp the leaf just wrote, since
			-- the odometer hasn't moved and expiries compare inclusively.
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 3)
			expect(getUmbraTests()).toBe(3)
			drainVolumeStack(search, 0, 0, roomyFrustumPlanes)
			expect(getUmbraTests()).toBe(4)
			expect(search._visibleVoxelCount).toBe(2)

			part:Destroy()
		end)

		it("ignores a cell's not-occluded proof from a stale clear generation", function()
			local search = cullThrottle._search
			stageSlabUmbra(cullThrottle)

			local key = Vector3.new(1, 41, 0)
			search._searchVoxelKeys[1] = key
			cullThrottle._visibilityCache._voxelOcclusionProofs[key] =
				clearOcclusionProof(5, cullThrottle._occlusion._clearGeneration + 7)

			-- The stale proof can't settle the cell, so it takes a fresh
			-- leaf test and restamps at the live clear generation.
			local getUmbraTests = countUmbraTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 1, 0b11111, math.huge, 1)
			expect(getUmbraTests()).toBe(2)
			expect(search._visibleVoxelCount).toBe(1)
			expect(cullThrottle._visibilityCache._voxelOcclusionProofs[key].Y).toBe(
				cullThrottle._occlusion._clearGeneration
			)
		end)

		it("drops a voxel's occlusion proof when its voxel empties", function()
			local part = createMockPart()
			local objectData = stubObjectData(part)
			local grid = cullThrottle._grid
			local voxelKey = Vector3.new(1, 41, 2)
			grid:insertToVoxel(voxelKey, objectData)

			local voxelOcclusionProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			voxelOcclusionProofs[voxelKey] = hiddenOcclusionProof(5, cullThrottle._occlusion._generation)

			-- An emptied voxel takes its occlusion proof with it, the same
			-- way it takes its frustum proof.
			grid:removeFromVoxel(voxelKey, objectData)
			expect(voxelOcclusionProofs[voxelKey]).toBeNil()

			part:Destroy()
		end)
	end)

	describe("end to end", function()
		local savedCameraCFrame

		beforeEach(function()
			savedCameraCFrame = workspace.CurrentCamera.CFrame
			-- A canonical world-aligned pose makes the wall, target, and voxel
			-- geometry below deterministic. The camera cache refresh is called
			-- synchronously rather than waiting on the deferred change signal.
			workspace.CurrentCamera.CFrame = CFrame.new(Vector3.new(50, 50, 50), Vector3.new(50, 50, -1000))
			CameraCache.cframeChanged()
		end)

		afterEach(function()
			workspace.CurrentCamera.CFrame = savedCameraCFrame
			task.wait()
		end)

		it("culls objects behind a tagged wall and restores them when the wall is untagged", function()
			local target = createMockPart(Vector3.new(50, 50, -650))
			cullThrottle:AddObject(target)
			cullThrottle:SetTimeBudgets(1, 1, 1)

			cullThrottle:_processObjectVisibility(os.clock())
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).never.toBeNil()

			-- The wall is huge and sits between the camera and the target, so
			-- the target's whole coarse bucket lands inside its umbra.
			local wall = createMockOccluder(Vector3.new(50, 50, -150), Vector3.new(2000, 2000, 40))
			task.wait()

			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).toBeNil()
			local metrics = cullThrottle:GetPerformanceMetrics()
			expect(metrics.occludedVoxelCount).toBeGreaterThan(0)

			wall:RemoveTag(OCCLUDER_TAG)
			task.wait()

			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).never.toBeNil()

			wall:Destroy()
			target:Destroy()
		end)

		it("restores objects when the wall moves out of the way", function()
			local target = createMockPart(Vector3.new(50, 50, -650))
			cullThrottle:AddObject(target)
			cullThrottle:SetTimeBudgets(1, 1, 1)

			local wall = createMockOccluder(Vector3.new(50, 50, -150), Vector3.new(2000, 2000, 40))
			task.wait()

			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).toBeNil()

			-- The next frame's build polls the wall's pose, catches the move,
			-- and bumps the generation (killing the cached proof), so the
			-- target must come back without waiting on any deferred signal.
			local generationBefore = cullThrottle._occlusion._generation
			wall.CFrame = CFrame.new(50, 50, 5000)

			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(cullThrottle._occlusion._generation).toBeGreaterThan(generationBefore)
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).never.toBeNil()

			wall:Destroy()
			target:Destroy()
		end)

		it("keeps a cached occlusion proof through rotation and expires it past its translation allowance", function()
			local target = createMockPart(Vector3.new(50, 50, -650))
			cullThrottle:AddObject(target)
			cullThrottle:SetTimeBudgets(1, 1, 1)

			local wall = createMockOccluder(Vector3.new(50, 50, -150), Vector3.new(2000, 2000, 40))
			task.wait()

			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).toBeNil()

			-- The target voxel is (0, 0, -7), so its coarse bucket is
			-- (0, 0, -2), and the frame above must have cached a proof for it
			-- at the live generation.
			local proofs = cullThrottle._visibilityCache._bucketOcclusionProofs
			local proof = proofs[Vector3.new(0, 0, -2)]
			expect(proof).toBeDefined()
			expect(proof.Y).toBe(cullThrottle._occlusion._generation)

			-- Occlusion depends only on camera position, so a huge rotation
			-- charge must not expire the proof. The bucket resolves from the
			-- cache without a single fresh umbra test.
			local getUmbraTests = countUmbraTests()
			cullThrottle._motion._accumR = 50
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(getUmbraTests()).toBe(0)
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).toBeNil()

			-- Translation past the stored expiry kills the proof, and the
			-- fresh umbra test re-proves the bucket occluded.
			cullThrottle._motion._accumT = proof.X + 0.05
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())
			expect(getUmbraTests()).toBeGreaterThan(0)
			expect(table.find(cullThrottle:GetVisibleObjects(), target)).toBeNil()

			wall:Destroy()
			target:Destroy()
		end)

		it("does nothing when the occluder cap is zero", function()
			local target = createMockPart(Vector3.new(50, 50, -650))
			cullThrottle:AddObject(target)
			cullThrottle:SetTimeBudgets(1, 1, 1)

			local wall = createMockOccluder(Vector3.new(50, 50, -150), Vector3.new(2000, 2000, 40))
			task.wait()

			-- A zero cap disables occlusion outright. Even proofs cached by
			-- earlier frames (the yield above let the render loop cull with
			-- the default cap) must stop being honored.
			cullThrottle:SetMaxOccluders(0)
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())

			expect(table.find(cullThrottle:GetVisibleObjects(), target)).never.toBeNil()
			expect(cullThrottle:GetPerformanceMetrics().occludedVoxelCount).toBe(0)

			wall:Destroy()
			target:Destroy()
		end)
	end)

	describe("configuration", function()
		it("flushes cached occlusion proofs when the voxel size changes", function()
			-- Proofs are in voxel units, so a resize invalidates them along
			-- with everything else in the visibility cache.
			local bucketProofs = cullThrottle._visibilityCache._bucketOcclusionProofs
			local voxelProofs = cullThrottle._visibilityCache._voxelOcclusionProofs
			bucketProofs[Vector3.new(0, 0, 0)] = hiddenOcclusionProof(5, 0)
			voxelProofs[Vector3.new(1, 1, 1)] = hiddenOcclusionProof(5, 0)

			cullThrottle:SetVoxelSize(50)

			expect(next(bucketProofs)).toBeNil()
			expect(next(voxelProofs)).toBeNil()
		end)
	end)
end)
