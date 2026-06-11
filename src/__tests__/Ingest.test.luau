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
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local ingestObjects = TestHelpers.ingestObjects
local fastIngestObjects = TestHelpers.fastIngestObjects

describe("Ingest", function()
	local cullThrottle

	beforeEach(function()
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil
	end)

	describe("Ingest priority", function()
		--[[
			Reads back the priority the ingest pass staged for an object, matching it
			to its entry in the incoming batch (items[i] pairs with priorities[i]).
		]]
		local function incomingPriority(object: Instance): number?
			local batch = cullThrottle._ingest._visibleObjectsQueue._incomingBatch
			for i = 1, batch.size do
				if batch.items[i] == object then
					return batch.priorities[i]
				end
			end
			return nil
		end

		--[[
			Positions an object a fixed distance straight out from the camera and
			prepares the object data fields the priority branches read. Jitter is
			zeroed so the elapsed argument alone picks the priority branch.
		]]
		local function stageObject(distance: number, radius: number, elapsed: number): Instance
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.jitterOffset = 0
			objectData.radius = radius
			objectData.lastCheckClock = 0
			objectData.cframe = CFrame.new(CameraCache.Position + CameraCache.CFrame.LookVector * distance)
			objectData.position = objectData.cframe.Position
			-- The elapsed argument is measured from "now" (os.clock) at ingest time.
			objectData.lastUpdateClock = os.clock() - elapsed
			return part
		end

		it("excludes objects beyond the render distance", function()
			local part = stageObject(500, 2, 0.04)
			cullThrottle._config.renderDistance = 100

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { part })

			-- It's past the render distance, so it's never staged and never marked visible.
			expect(incomingPriority(part)).toBeNil()
			expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

			part:Destroy()
		end)

		it("excludes objects beyond the render distance in the fast pass too", function()
			local part = stageObject(500, 2, 0.04)
			cullThrottle._config.renderDistance = 100

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			fastIngestObjects(cullThrottle, os.clock(), { part })

			-- The cheap pass applies the same cull as the precise one, so the
			-- object is never staged and never marked visible.
			expect(incomingPriority(part)).toBeNil()
			expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

			part:Destroy()
		end)

		it("refreshes the stored distance in the fast pass", function()
			local part = stageObject(200, 2, 0.04)
			-- The stored distance goes stale when the camera moves while the
			-- object's voxel keeps falling to the fast pass, so we plant a stale
			-- value and expect ingest to overwrite it with the real distance.
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.distance = 50

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			fastIngestObjects(cullThrottle, os.clock(), { part })

			expect(objectData.distance).toBeCloseTo(200)
			expect(incomingPriority(part)).toBeDefined()

			part:Destroy()
		end)

		it("pushes over-refreshed objects far down the queue", function()
			-- An elapsed of 0 is well under bestRefreshPeriod, so this is the over-refresh
			-- branch, scaled by OVER_REFRESH_PRIORITY_SCALE (1e6). A small, distant
			-- object keeps the screen size below 1 so the scaled value stays large.
			local part = stageObject(300, 0.5, 0)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { part })

			local priority = incomingPriority(part)
			expect(priority).toBeDefined()
			expect((priority :: number) > 1e5).toBe(true)

			part:Destroy()
		end)

		it("keeps over-refreshed large objects from stealing p0 priority", function()
			-- A large radius relative to distance gives a screen size above 1,
			-- which would drive (1 - screenSize) negative and pull this just-updated
			-- object below the p0 threshold and ahead of overdue ones. An elapsed
			-- of 0 selects the over-refresh branch.
			local overRefreshed = stageObject(10, 50, 0)
			-- A small, distant object that is genuinely overdue (elapsed far past
			-- the worst refresh rate) sits in the p0 band.
			local overdue = stageObject(300, 0.5, 100)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { overRefreshed, overdue })

			local pOverRefreshed = incomingPriority(overRefreshed) :: number
			local pOverdue = incomingPriority(overdue) :: number

			-- The over-refreshed object stays at or above the p0 threshold (0.90),
			-- so the update loop never grants it the extended p0 budget.
			expect(pOverRefreshed >= 0.9).toBe(true)
			-- The genuinely overdue object still sorts first (lower value dequeues first).
			expect(pOverdue < pOverRefreshed).toBe(true)

			overRefreshed:Destroy()
			overdue:Destroy()
		end)

		it("sorts over-refreshed objects behind objects that are due for a refresh", function()
			-- A screen-filling object (radius well above distance) clamps the
			-- screen-size term to zero, which must not let its just-refreshed
			-- priority undercut the fair band. An elapsed of 0 selects the
			-- over-refresh branch.
			local overRefreshed = stageObject(10, 50, 0)
			-- A due object in the fair band, with elapsed between the best and
			-- worst refresh periods.
			local due = stageObject(300, 0.5, 0.04)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { overRefreshed, due })

			local pOverRefreshed = incomingPriority(overRefreshed) :: number
			local pDue = incomingPriority(due) :: number

			expect(pDue < pOverRefreshed).toBe(true)

			overRefreshed:Destroy()
			due:Destroy()
		end)

		it("gives overdue objects p0 priority sorted by screen size", function()
			-- An elapsed far past worstRefreshPeriod puts both in the p0 band.
			local smallPart = stageObject(100, 0.5, 100)
			local bigPart = stageObject(100, 5, 100)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { smallPart, bigPart })

			local pSmall = incomingPriority(smallPart) :: number
			local pBig = incomingPriority(bigPart) :: number

			-- Both sit below the p0 threshold (0.90).
			expect(pSmall < 0.9).toBe(true)
			expect(pBig < 0.9).toBe(true)
			-- The larger (more on-screen) object sorts ahead with a lower value.
			expect(pBig < pSmall).toBe(true)

			smallPart:Destroy()
			bigPart:Destroy()
		end)

		it("gives nearby objects a distance-proportional priority", function()
			-- This sits within NEARBY_DISTANCE_THRESHOLD (30) and refreshes at a fair rate.
			local part = stageObject(15, 2, 0.04)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { part })

			-- The priority is distance / NEARBY_DISTANCE_THRESHOLD, which is 15 / 30.
			expect(incomingPriority(part)).toBeCloseTo(15 / 30)

			part:Destroy()
		end)

		it("ranks a farther object below a nearer one in the fair band", function()
			-- Both are past the nearby threshold and refreshing at a fair rate, so they
			-- take the weighted-blend branch where distance and screen size matter.
			local nearPart = stageObject(100, 2, 0.04)
			local farPart = stageObject(200, 2, 0.04)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { nearPart, farPart })

			local pNear = incomingPriority(nearPart) :: number
			local pFar = incomingPriority(farPart) :: number

			-- A higher priority value means later in the queue, so the farther,
			-- smaller-on-screen object should sort after the nearer one.
			expect(pFar > pNear).toBe(true)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("ranks a larger object ahead of a smaller one in the fair band", function()
			local bigPart = stageObject(100, 5, 0.04)
			local smallPart = stageObject(100, 1, 0.04)

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { bigPart, smallPart })

			local pBig = incomingPriority(bigPart) :: number
			local pSmall = incomingPriority(smallPart) :: number

			-- The bigger object fills more of the screen, so it sorts first (lower value).
			expect(pBig < pSmall).toBe(true)

			bigPart:Destroy()
			smallPart:Destroy()
		end)

		it("keeps a large near object whose center is behind the camera", function()
			-- The per-axis angle test is only valid in front of the camera. A big
			-- object centered just behind the camera plane can still wrap its body
			-- into view, so it must be kept rather than culled.
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.jitterOffset = 0
			objectData.lastCheckClock = 0
			objectData.lastUpdateClock = os.clock()
			objectData.radius = 40
			-- Local +Z is behind the camera (LookVector is -Z), so this sits 8 behind
			-- and 12 to the side.
			objectData.cframe = CameraCache.CFrame * CFrame.new(12, 0, 8)
			objectData.position = objectData.cframe.Position

			cullThrottle._ingest._visibleObjectsQueue:clearIncomingBatch()
			ingestObjects(cullThrottle, os.clock(), { part })

			-- Being staged into the queue means it was kept, not culled.
			expect(incomingPriority(part)).never.toBeNil()

			part:Destroy()
		end)
	end)

	describe("Visible voxel ordering", function()
		it("accumulates added voxels into the pending buffer in call order", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + Vector3.new(3, 0, 0))
			cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + Vector3.new(1, 0, 0))

			expect(cullThrottle._search._visibleVoxelCount).toBe(2)
			expect(cullThrottle._search._pendingVoxelKeys[1]).toBe(cameraVoxel + Vector3.new(3, 0, 0))
			expect(cullThrottle._search._pendingVoxelKeys[2]).toBe(cameraVoxel + Vector3.new(1, 0, 0))
		end)

		it("sorts visible voxels closest-first by manhattan distance to the camera", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- The offsets are deliberately added out of distance order.
			local offsets = {
				Vector3.new(5, 0, 0), -- This one sits at distance 5.
				Vector3.new(0, 0, 0), -- This one sits at distance 0 (it's the camera's own voxel).
				Vector3.new(-2, 1, 0), -- This one sits at distance 3.
				Vector3.new(1, 0, 0), -- This one sits at distance 1.
				Vector3.new(2, 2, 2), -- This one sits at distance 6.
				Vector3.new(0, -3, 1), -- This one sits at distance 4.
			}
			for _, offset in offsets do
				cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + offset)
			end

			cullThrottle._ingest:sortVisibleVoxelKeys()

			expect(cullThrottle._search._visibleVoxelCount).toBe(#offsets)

			-- Output distances are non-decreasing, and the nearest voxel is first.
			local previousDistance = -1
			for i = 1, cullThrottle._search._visibleVoxelCount do
				local difference = cullThrottle._search._visibleVoxelKeys[i] - cameraVoxel
				local distance = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)
				expect(distance).toBeGreaterThanOrEqual(previousDistance)
				previousDistance = distance
			end
			expect(cullThrottle._search._visibleVoxelKeys[1]).toBe(cameraVoxel)
		end)

		it("preserves every voxel exactly once through the sort, including ties", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- This is a spread of distinct voxels, several of which tie on distance.
			local added = {}
			for x = -3, 3 do
				for y = -1, 1 do
					local key = cameraVoxel + Vector3.new(x, y, 0)
					cullThrottle._search:addVoxelKeyToVisible(key)
					added[key] = true
				end
			end

			cullThrottle._ingest:sortVisibleVoxelKeys()

			local seen = {}
			for i = 1, cullThrottle._search._visibleVoxelCount do
				local key = cullThrottle._search._visibleVoxelKeys[i]
				seen[key] = (seen[key] or 0) + 1
			end

			-- The same set comes out as went in, with each added key present
			-- exactly once and nothing extra.
			local addedCount = 0
			for key in added do
				expect(seen[key]).toBe(1)
				addedCount += 1
			end
			expect(cullThrottle._search._visibleVoxelCount).toBe(addedCount)
		end)

		it("handles the empty and single-voxel cases", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			expect(function()
				cullThrottle._ingest:sortVisibleVoxelKeys()
			end).never.toThrow()
			expect(cullThrottle._search._visibleVoxelCount).toBe(0)

			local onlyKey = cameraVoxel + Vector3.new(7, -2, 4)
			cullThrottle._search:addVoxelKeyToVisible(onlyKey)
			cullThrottle._ingest:sortVisibleVoxelKeys()
			expect(cullThrottle._search._visibleVoxelCount).toBe(1)
			expect(cullThrottle._search._visibleVoxelKeys[1]).toBe(onlyKey)
		end)

		it("keeps visible voxels ordered closest-first end to end", function()
			-- Spread objects across several voxels so the search produces a batch to order.
			local parts = {}
			for i = -3, 3 do
				local part = createMockPart(Vector3.new(i * 120, 0, 0))
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- Generous budgets let the search and ingest both run to completion.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle:_findVisibleObjects(os.clock())

			-- However many voxels ended up visible, they must come out non-decreasing
			-- in manhattan distance to the camera (the ingest passes depend on it).
			local cameraVoxel = CameraCache.Position // cullThrottle._config.voxelSize
			local previousDistance = -1
			for i = 1, cullThrottle._search._visibleVoxelCount do
				local difference = cullThrottle._search._visibleVoxelKeys[i] - cameraVoxel
				local distance = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)
				expect(distance).toBeGreaterThanOrEqual(previousDistance)
				previousDistance = distance
			end

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("preserves the visible voxel keys when the backing tables are resized", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + Vector3.new(1, 0, 0))
			cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + Vector3.new(2, 0, 0))
			cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + Vector3.new(3, 0, 0))
			cullThrottle._ingest:sortVisibleVoxelKeys()

			local expectedCount = cullThrottle._search._visibleVoxelCount
			local before = {}
			for i = 1, expectedCount do
				before[i] = cullThrottle._search._visibleVoxelKeys[i]
			end

			cullThrottle:_resizeTables()

			-- The resize trims the unused tail without dropping any live key.
			expect(cullThrottle._search._visibleVoxelCount).toBe(expectedCount)
			for i = 1, expectedCount do
				expect(cullThrottle._search._visibleVoxelKeys[i]).toBe(before[i])
			end
		end)
	end)
end)
