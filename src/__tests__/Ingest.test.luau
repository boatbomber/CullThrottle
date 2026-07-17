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
local Ingest = require(CullThrottlePackage:WaitForChild("Ingest"))
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
		-- The elapsed values in these tests assume the band boundaries that a
		-- 15 to 60 Hz range produces (over-refresh up to 1/60s, p0 from 1/15s),
		-- so the rates are pinned here instead of riding on the library defaults.
		cullThrottle:SetRefreshRates(NumberRange.new(15, 60))
	end)

	afterEach(function()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil
	end)

	--[[
		Lays out whatever the ingest passes staged and drains the queue proper,
		returning the objects in dequeue order plus a map of each object's
		dequeued band. The queue holds ObjectData records, so this unwraps
		each one back to its Instance. This is the same pop order
		IterateObjectsToUpdate consumes, so assertions on it survive refactors of
		how ingest feeds the queue.
	]]
	local function drainStagedObjects()
		local ingest = cullThrottle._ingest
		local queue = ingest._visibleObjectsQueue
		ingest:enqueueStagedObjects()
		local order = {}
		local bands = {}
		while not queue:isEmpty() do
			local objectData, band = queue:dequeue()
			table.insert(order, objectData.object)
			bands[objectData.object] = band
		end
		return order, bands
	end

	--[[
		Counts how many staged batch entries reference the object. The staged
		batch is the right surface for duplicate checks because the facade
		answers GetVisibleObjects straight off this objects array, and the queue
		lays out whatever the batch holds, so a double staging would enter the
		drain twice. The ingest passes prevent that through lastCheckClock.
	]]
	local function stagedOccurrences(object: Instance): number
		local ingest = cullThrottle._ingest
		local occurrences = 0
		for i = 1, ingest._stagedSize do
			if ingest._stagedObjects[i].object == object then
				occurrences += 1
			end
		end
		return occurrences
	end

	--[[
		Positions an object a fixed distance straight out from the camera and
		prepares the object data fields the priority branches read. Jitter is
		zeroed and lastUpdateClock is anchored to the caller's shared now, so the
		elapsed argument alone picks the priority branch with no clock drift.
	]]
	local function stageObject(now: number, distance: number, radius: number, elapsed: number): Instance
		local part = createMockPart()
		cullThrottle:AddObject(part)
		local objectData = cullThrottle._lifecycle._objects[part]
		objectData.jitterOffset = 0
		objectData.radius = radius
		objectData.lastCheckClock = 0
		objectData.cframe = CFrame.new(CameraCache.Position + CameraCache.CFrame.LookVector * distance)
		objectData.position = objectData.cframe.Position
		objectData.lastUpdateClock = now - elapsed
		return part
	end

	describe("Ingest priority", function()
		it("excludes objects beyond the render distance", function()
			local now = os.clock()
			local part = stageObject(now, 500, 2, 0.04)
			cullThrottle._config.renderDistance = 100

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { part })

			-- It's past the render distance, so it never dequeues and is never
			-- marked visible.
			local order = drainStagedObjects()
			expect(table.find(order, part)).toBeNil()
			expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

			part:Destroy()
		end)

		it("excludes objects beyond the render distance in the fast pass too", function()
			local now = os.clock()
			local part = stageObject(now, 500, 2, 0.04)
			cullThrottle._config.renderDistance = 100

			cullThrottle._ingest:clearStagedObjects()
			fastIngestObjects(cullThrottle, now, { part })

			-- The cheap pass applies the same cull as the precise one, so the
			-- object never dequeues and is never marked visible.
			local order = drainStagedObjects()
			expect(table.find(order, part)).toBeNil()
			expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

			part:Destroy()
		end)

		it("refreshes the stored distance in the fast pass", function()
			local now = os.clock()
			local part = stageObject(now, 200, 2, 0.04)
			-- The stored distance goes stale when the camera moves while the
			-- object's voxel keeps falling to the fast pass, so we plant a stale
			-- value and expect ingest to overwrite it with the real distance.
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.distance = 50

			cullThrottle._ingest:clearStagedObjects()
			fastIngestObjects(cullThrottle, now, { part })

			expect(objectData.distance).toBeCloseTo(200)
			-- It still got staged and dequeues like any visible object.
			local order = drainStagedObjects()
			expect(table.find(order, part)).toBe(1)

			part:Destroy()
		end)

		it("pushes over-refreshed objects far down the queue", function()
			local now = os.clock()
			-- An elapsed of 0 is under the best refresh period, so this is the
			-- over-refresh branch. A small, distant object keeps the screen size
			-- below 1 so the scaled value stays large.
			local overRefreshed = stageObject(now, 300, 0.5, 0)
			-- A fair-band companion makes the band ordering observable.
			local due = stageObject(now, 100, 2, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { overRefreshed, due })

			local order, bands = drainStagedObjects()
			expect(table.find(order, due)).toBe(1)
			expect(table.find(order, overRefreshed)).toBe(2)
			-- The over-refresh region sits at the very back of the band table,
			-- behind everything the precise pass scores for this frame.
			expect(bands[overRefreshed] >= Ingest.OVER_BAND_OFFSET).toBe(true)

			overRefreshed:Destroy()
			due:Destroy()
		end)

		it("keeps over-refreshed large objects from stealing p0 priority", function()
			local now = os.clock()
			-- A large radius relative to distance gives a screen size above 1,
			-- which would drive (1 - screenSize) negative and pull this just-updated
			-- object below the p0 threshold and ahead of overdue ones. An elapsed
			-- of 0 selects the over-refresh branch.
			local overRefreshed = stageObject(now, 10, 50, 0)
			-- A small, distant object that is well overdue (elapsed far past
			-- the worst refresh period) sits in the p0 band.
			local overdue = stageObject(now, 300, 0.5, 100)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { overRefreshed, overdue })

			local order, bands = drainStagedObjects()

			-- The overdue object dequeues first.
			expect(table.find(order, overdue)).toBe(1)
			expect(table.find(order, overRefreshed)).toBe(2)
			-- The overdue object sits in the p0 region the update loop keys its
			-- overrun budget off, while the clamped over-refreshed object lands
			-- at the very back in the over-refresh region.
			expect(bands[overdue] <= Ingest.P0_BAND_COUNT).toBe(true)
			expect(bands[overRefreshed] >= Ingest.OVER_BAND_OFFSET).toBe(true)

			overRefreshed:Destroy()
			overdue:Destroy()
		end)

		it("keeps a screen-filling fair-band object out of the p0 band", function()
			local now = os.clock()
			-- A radius far above the distance pushes the screen size past 1. The
			-- fair band must clamp it so the screen-size term can't go negative
			-- and drop a recently refreshed object below the p0 threshold, where
			-- it would steal the p0 overrun budget from objects that are actually overdue.
			-- Distance 40 keeps it past the nearby band, and an elapsed of 0.04
			-- keeps it in the fair band.
			local screenFilling = stageObject(now, 40, 100, 0.04)
			local overdue = stageObject(now, 300, 0.5, 100)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { screenFilling, overdue })

			local order, bands = drainStagedObjects()

			-- The overdue object dequeues first.
			expect(table.find(order, overdue)).toBe(1)
			expect(table.find(order, screenFilling)).toBe(2)
			-- The screen-filling object stays out of the p0 region, so the
			-- update loop never grants it the extended p0 budget.
			expect(bands[screenFilling] > Ingest.P0_BAND_COUNT).toBe(true)
			expect(bands[overdue] <= Ingest.P0_BAND_COUNT).toBe(true)

			screenFilling:Destroy()
			overdue:Destroy()
		end)

		it("skips an object whose position has gone NaN in both passes", function()
			local now = os.clock()
			-- A NaN position makes every comparison against its distance false, so
			-- the render distance cull must be phrased to reject it. Letting it
			-- through would feed a NaN band into the queue, corrupting the
			-- counting sort's layout.
			local part = stageObject(now, 100, 2, 0.04)
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.position = Vector3.new(0 / 0, 0 / 0, 0 / 0)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { part })

			local order = drainStagedObjects()
			expect(#order).toBe(0)
			expect(objectData.lastVisibleClock).toBe(0)

			objectData.lastCheckClock = 0
			cullThrottle._ingest:clearStagedObjects()
			fastIngestObjects(cullThrottle, now, { part })

			order = drainStagedObjects()
			expect(#order).toBe(0)
			expect(objectData.lastVisibleClock).toBe(0)

			part:Destroy()
		end)

		it("sorts over-refreshed objects behind objects that are due for a refresh", function()
			local now = os.clock()
			-- A screen-filling object (radius well above distance) clamps the
			-- screen-size term to zero, which must not let its just-refreshed
			-- priority undercut the fair band. An elapsed of 0 selects the
			-- over-refresh branch.
			local overRefreshed = stageObject(now, 10, 50, 0)
			-- An elapsed between the best and worst refresh periods stages a due
			-- object in the fair band.
			local due = stageObject(now, 300, 0.5, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { overRefreshed, due })

			local order = drainStagedObjects()
			expect(table.find(order, due)).toBe(1)
			expect(table.find(order, overRefreshed)).toBe(2)

			overRefreshed:Destroy()
			due:Destroy()
		end)

		it("gives overdue objects p0 priority sorted by screen size", function()
			local now = os.clock()
			-- An elapsed far past the worst refresh period puts both in the p0 band.
			local smallPart = stageObject(now, 100, 0.5, 100)
			local bigPart = stageObject(now, 100, 5, 100)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { smallPart, bigPart })

			local order, bands = drainStagedObjects()

			-- Both sit in the p0 region the update loop keys its overrun
			-- budget off.
			expect(bands[smallPart] <= Ingest.P0_BAND_COUNT).toBe(true)
			expect(bands[bigPart] <= Ingest.P0_BAND_COUNT).toBe(true)
			-- The larger (more on-screen) object dequeues first.
			expect(table.find(order, bigPart)).toBe(1)
			expect(table.find(order, smallPart)).toBe(2)

			smallPart:Destroy()
			bigPart:Destroy()
		end)

		it("gives nearby objects a distance-proportional priority", function()
			local now = os.clock()
			-- Both sit within the nearby threshold and refresh at a fair rate,
			-- with the farther one exactly twice as far out.
			local nearPart = stageObject(now, 10, 2, 0.04)
			local farPart = stageObject(now, 20, 2, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { nearPart, farPart })

			local order, bands = drainStagedObjects()

			-- The nearer object dequeues first, and each object's band is the
			-- p0 slice its own distance fraction picks, so a constant score
			-- can't pass here.
			expect(table.find(order, nearPart)).toBe(1)
			expect(table.find(order, farPart)).toBe(2)
			expect(bands[nearPart]).toBe((10 / 30) * Ingest.P0_BAND_SCALE // 1 + 1)
			expect(bands[farPart]).toBe((20 / 30) * Ingest.P0_BAND_SCALE // 1 + 1)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("ranks a farther object below a nearer one in the fair band", function()
			local now = os.clock()
			-- Both are past the nearby threshold and refreshing at a fair rate, so they
			-- take the weighted-blend branch where distance and screen size matter.
			local nearPart = stageObject(now, 100, 2, 0.04)
			local farPart = stageObject(now, 200, 2, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { nearPart, farPart })

			-- The farther, smaller-on-screen object dequeues after the nearer one.
			local order = drainStagedObjects()
			expect(table.find(order, nearPart)).toBe(1)
			expect(table.find(order, farPart)).toBe(2)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("ranks a larger object ahead of a smaller one in the fair band", function()
			local now = os.clock()
			local bigPart = stageObject(now, 100, 5, 0.04)
			local smallPart = stageObject(now, 100, 1, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { bigPart, smallPart })

			-- The bigger object fills more of the screen, so it dequeues first.
			local order = drainStagedObjects()
			expect(table.find(order, bigPart)).toBe(1)
			expect(table.find(order, smallPart)).toBe(2)

			bigPart:Destroy()
			smallPart:Destroy()
		end)

		it("ranks a more overdue object ahead of a fresher one in the fair band", function()
			local now = os.clock()
			-- Both objects share distance and size, so only the refresh urgency
			-- term separates them. Deleting or inverting it would break this.
			local fresher = stageObject(now, 100, 2, 0.02)
			local overdue = stageObject(now, 100, 2, 0.06)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { fresher, overdue })

			local order = drainStagedObjects()
			expect(table.find(order, overdue)).toBe(1)
			expect(table.find(order, fresher)).toBe(2)

			fresher:Destroy()
			overdue:Destroy()
		end)

		it("breaks fair-band ties between equal screen sizes by distance", function()
			local now = os.clock()
			-- The far object's radius scales with its distance, so both project
			-- to the same screen size, and both elapsed values anchor to the same
			-- shared now. Only the deliberate distance tiebreaker can order them.
			-- The render distance is pinned so the two distance terms sit more
			-- than a whole point of score apart (0.5 versus 1.75), which lands
			-- the objects in different bands no matter where the shared screen
			-- and refresh terms fall.
			local nearPart = stageObject(now, 100, 2, 0.04)
			local farPart = stageObject(now, 350, 7, 0.04)
			cullThrottle._config.renderDistance = 400

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { farPart, nearPart })

			local order = drainStagedObjects()
			expect(table.find(order, nearPart)).toBe(1)
			expect(table.find(order, farPart)).toBe(2)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("sends a just-refreshed nearby object to the over-refresh band, not the nearby band", function()
			local now = os.clock()
			-- The over-refresh check outranks the nearby check in the branch
			-- ladder. Reordering them would make objects right by the camera
			-- refresh every frame no matter how recently they updated.
			local part = stageObject(now, 15, 2, 0)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { part })

			-- A nearby score would land in the p0 slices near the front, while
			-- the over-refresh region sits at the very back of the band table.
			local _, bands = drainStagedObjects()
			expect(bands[part] >= Ingest.OVER_BAND_OFFSET).toBe(true)

			part:Destroy()
		end)

		it("stages an object at the camera's position into the front band", function()
			local now = os.clock()
			-- A zero distance would feed an infinite screen size into the p0
			-- math without the minimum-distance clamp. The object is hugely
			-- overdue so it takes the p0 branch, where the huge screen size
			-- drives the score far negative and the band must clamp to the
			-- front of the queue instead of computing a nonsense index.
			local part = stageObject(now, 0, 2, 100)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { part })

			local order, bands = drainStagedObjects()
			expect(table.find(order, part)).toBe(1)
			expect(bands[part]).toBe(1)

			part:Destroy()
		end)

		it("culls an object poking outside a side plane within a visible voxel", function()
			local now = os.clock()
			-- Voxel-level visibility doesn't imply per-object visibility, so an
			-- object whose bounding sphere sits fully outside a side plane must
			-- be dropped (and never marked in view) even though its voxel was
			-- staged as visible. Its neighbor just inside the plane stays.
			local sinH = CameraCache.SinHalfHorizontalFOV
			local cosH = CameraCache.CosHalfHorizontalFOV
			local forward = 100
			local radius = 2
			local boundary = forward * sinH / cosH

			local function stageAtLateralOffset(right: number): Instance
				local part = createMockPart()
				cullThrottle:AddObject(part)
				local objectData = cullThrottle._lifecycle._objects[part]
				objectData.jitterOffset = 0
				objectData.radius = radius
				objectData.lastCheckClock = 0
				objectData.lastUpdateClock = now - 0.04
				objectData.cframe = CameraCache.CFrame * CFrame.new(right, 0, -forward)
				objectData.position = objectData.cframe.Position
				return part
			end

			local culled = stageAtLateralOffset(boundary + (radius + 5) / cosH)
			local kept = stageAtLateralOffset(boundary - (radius + 5) / cosH)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { culled, kept })

			local order = drainStagedObjects()
			expect(table.find(order, culled)).toBeNil()
			expect(cullThrottle._lifecycle._objects[culled].lastVisibleClock).toBe(0)
			expect(table.find(order, kept)).never.toBeNil()

			culled:Destroy()
			kept:Destroy()
		end)

		it("keeps a large near object whose center is behind the camera", function()
			local now = os.clock()
			-- The per-axis angle test is only valid in front of the camera. A big
			-- object centered just behind the camera plane can still wrap its body
			-- into view, so it must be kept rather than culled.
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.jitterOffset = 0
			objectData.lastCheckClock = 0
			objectData.lastUpdateClock = now
			objectData.radius = 40
			-- Local +Z is behind the camera (LookVector is -Z), so this sits 8 behind
			-- and 12 to the side.
			objectData.cframe = CameraCache.CFrame * CFrame.new(12, 0, 8)
			objectData.position = objectData.cframe.Position

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { part })

			-- Coming out of the queue means it was kept, not culled.
			local order = drainStagedObjects()
			expect(table.find(order, part)).never.toBeNil()

			part:Destroy()
		end)
	end)

	describe("Multi-voxel deduplication", function()
		it("ingests an object spanning two visible voxels only once in the precise pass", function()
			local now = os.clock()
			local part = stageObject(now, 100, 2, 0.04)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- The same object data sits in two visible voxels, the way a large
			-- object straddling a voxel boundary does, so the precise pass must
			-- do the work only on its first visit this frame.
			local keyA = Vector3.new(1e6, 1e6, 1e6)
			local keyB = Vector3.new(1e6, 1e6, 1e6 + 1)
			cullThrottle._grid._voxels[keyA] = { objectData }
			cullThrottle._grid._voxels[keyB] = { objectData }
			cullThrottle._search._visibleVoxelKeys = { keyA, keyB }
			cullThrottle._search._visibleVoxelCount = 2

			-- A generous budget keeps the precise pass on both voxels.
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._ingest:clearStagedObjects()
			cullThrottle._ingest:ingestVisibleVoxels(now)

			-- It was staged exactly once.
			expect(stagedOccurrences(part)).toBe(1)
			-- It was marked visible exactly once, so one entered-view event is
			-- buffered and the in-view set holds one entry.
			expect(cullThrottle._signals._pendingEnteredViewSize).toBe(1)
			expect(cullThrottle._signals._inViewCount).toBe(1)

			cullThrottle._grid._voxels[keyA] = nil
			cullThrottle._grid._voxels[keyB] = nil
			cullThrottle._search._visibleVoxelCount = 0
			part:Destroy()
		end)

		it("does not duplicate an object spanning several voxels in the fast pass", function()
			local now = os.clock()
			local part = stageObject(now, 100, 2, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			-- Each helper call stages one visible voxel, so two calls sharing one
			-- now reproduce an object occupying two voxels that both fall to the
			-- fast pass in the same frame.
			fastIngestObjects(cullThrottle, now, { part })
			fastIngestObjects(cullThrottle, now, { part })

			expect(stagedOccurrences(part)).toBe(1)

			part:Destroy()
		end)

		it("does not re-add an object the precise ingest pass already handled", function()
			local now = os.clock()
			local part = stageObject(now, 100, 2, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			-- The precise pass reaches the object's first voxel, then its second
			-- voxel falls to the fast pass within the same frame, which must
			-- recognize the object was already handled.
			ingestObjects(cullThrottle, now, { part })
			fastIngestObjects(cullThrottle, now, { part })

			expect(stagedOccurrences(part)).toBe(1)

			part:Destroy()
		end)
	end)

	describe("Budget handoff", function()
		it("hands voxels past the exhausted budget to the fast pass without skipping or duplicating any", function()
			local now = os.clock()
			-- The first voxel holds enough objects to cross the per-batch clock
			-- check interval (the count just needs to be at least the interval,
			-- so it sits comfortably above it), which means the budget check runs
			-- right after that voxel and the zero budget is already spent. The
			-- second voxel must fall through to the fast pass, neither skipped
			-- (an off-by-one up) nor re-ingested from the first voxel (an
			-- off-by-one down, visible in the skip tally).
			local nearObjects = {}
			for i = 1, 64 do
				nearObjects[i] = stageObject(now, 100, 2, 0.04)
			end
			local farObjects = {}
			for i = 1, 3 do
				farObjects[i] = stageObject(now, 200, 2, 0.04)
			end

			local nearVoxel = {}
			for i, part in nearObjects do
				nearVoxel[i] = cullThrottle._lifecycle._objects[part]
			end
			local farVoxel = {}
			for i, part in farObjects do
				farVoxel[i] = cullThrottle._lifecycle._objects[part]
			end

			local keyA = Vector3.new(1e6, 1e6, 1e6)
			local keyB = Vector3.new(1e6, 1e6, 1e6 + 1)
			cullThrottle._grid._voxels[keyA] = nearVoxel
			cullThrottle._grid._voxels[keyB] = farVoxel
			cullThrottle._search._visibleVoxelKeys = { keyA, keyB }
			cullThrottle._search._visibleVoxelCount = 2

			cullThrottle._config.ingestTimeBudget = 0
			cullThrottle._ingest:clearStagedObjects()
			cullThrottle._ingest:ingestVisibleVoxels(now)

			local order, bands = drainStagedObjects()

			-- Every object came through exactly once.
			expect(#order).toBe(#nearObjects + #farObjects)
			-- All the precisely scored near objects dequeue ahead of the far
			-- voxel's coarse tier.
			local worstNearPosition = 0
			for _, part in nearObjects do
				local position = table.find(order, part)
				expect(position).never.toBeNil()
				if position > worstNearPosition then
					worstNearPosition = position
				end
			end
			for _, part in farObjects do
				local position = table.find(order, part)
				expect(position).never.toBeNil()
				expect(position).toBeGreaterThan(worstNearPosition)
			end
			-- The far voxel's objects share one coarse tier, since the fast pass
			-- bands per voxel rather than per object.
			local farBand = bands[farObjects[1]]
			for _, part in farObjects do
				expect(bands[part]).toBe(farBand)
			end
			-- Exactly one voxel fell through to the fast pass.
			local perfMetrics = cullThrottle._perfMetrics
			expect(perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor]).toBe(1)

			cullThrottle._grid._voxels[keyA] = nil
			cullThrottle._grid._voxels[keyB] = nil
			cullThrottle._search._visibleVoxelCount = 0
			for _, part in nearObjects do
				part:Destroy()
			end
			for _, part in farObjects do
				part:Destroy()
			end
		end)

		it("records the ingest duration when the budget hands off to the fast pass", function()
			local now = os.clock()
			-- The handoff returns out of the precise pass early, and that path
			-- must still record how long the pass ran before it bailed. The
			-- object count just needs to be at least the per-batch clock check
			-- interval so the zero budget is noticed after the first voxel.
			local parts = {}
			for i = 1, 64 do
				parts[i] = stageObject(now, 100, 2, 0.04)
			end
			local voxel = {}
			for i, part in parts do
				voxel[i] = cullThrottle._lifecycle._objects[part]
			end
			local key = Vector3.new(1e6, 1e6, 1e6)
			cullThrottle._grid._voxels[key] = voxel
			cullThrottle._search._visibleVoxelKeys = { key }
			cullThrottle._search._visibleVoxelCount = 1

			cullThrottle:SetTimeBudgets(1, 0, 1)
			cullThrottle._ingest:clearStagedObjects()
			-- The sentinel proves the early return wrote the metric rather than
			-- leaving a stale value behind.
			cullThrottle._perfMetrics._ingestDuration = -1
			cullThrottle._ingest:ingestVisibleVoxels(now)

			expect(cullThrottle._perfMetrics._ingestDuration >= 0).toBe(true)

			cullThrottle._grid._voxels[key] = nil
			cullThrottle._search._visibleVoxelCount = 0
			for _, part in parts do
				part:Destroy()
			end
		end)

		it("gives farther fast-pass voxels strictly higher priority tiers", function()
			local now = os.clock()
			-- The fast pass can't score objects, so it must still dequeue nearer
			-- voxels first through the per-voxel tier scale.
			local partA = stageObject(now, 100, 2, 0.04)
			local partB = stageObject(now, 200, 2, 0.04)

			local keyA = Vector3.new(1e6, 1e6, 1e6)
			local keyB = Vector3.new(1e6, 1e6, 1e6 + 1)
			cullThrottle._grid._voxels[keyA] = { cullThrottle._lifecycle._objects[partA] }
			cullThrottle._grid._voxels[keyB] = { cullThrottle._lifecycle._objects[partB] }
			cullThrottle._search._visibleVoxelKeys = { keyA, keyB }
			cullThrottle._search._visibleVoxelCount = 2

			cullThrottle._ingest:clearStagedObjects()
			cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 1)

			-- The earlier voxel's object dequeues first, from a strictly lower
			-- (distinct) tier.
			local order, bands = drainStagedObjects()
			expect(table.find(order, partA)).toBe(1)
			expect(table.find(order, partB)).toBe(2)
			expect(bands[partA] < bands[partB]).toBe(true)
			-- Both voxels fell through here, so the skip tally records two.
			local perfMetrics = cullThrottle._perfMetrics
			expect(perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor]).toBe(2)

			cullThrottle._grid._voxels[keyA] = nil
			cullThrottle._grid._voxels[keyB] = nil
			cullThrottle._search._visibleVoxelCount = 0
			partA:Destroy()
			partB:Destroy()
		end)

		it("keeps deep fast-pass voxels ahead of over-refreshed objects", function()
			local now = os.clock()
			-- Objects dumped by the fast pass still need updates this frame, so
			-- every fast-pass tier must stay ahead of the over-refresh region no
			-- matter how deep the voxel index grows. The tiers saturate at their
			-- cap, so the index here sits well past it, and the screen-filling
			-- over-refreshed object takes the region's front band, the hardest
			-- case to stay ahead of.
			local overRefreshed = stageObject(now, 10, 50, 0)
			local fastPassed = stageObject(now, 200, 2, 0.04)

			cullThrottle._ingest:clearStagedObjects()
			ingestObjects(cullThrottle, now, { overRefreshed })

			-- The fast-passed object's voxel sits at slot 120 of the visible
			-- list, with every earlier slot referencing no voxel.
			local deepIndex = 120
			local deepKey = Vector3.new(1e6, 1e6, 1e6)
			local keys = table.create(deepIndex)
			for i = 1, deepIndex - 1 do
				keys[i] = Vector3.new(2e6 + i, 2e6, 2e6)
			end
			keys[deepIndex] = deepKey
			cullThrottle._grid._voxels[deepKey] = { cullThrottle._lifecycle._objects[fastPassed] }
			cullThrottle._search._visibleVoxelKeys = keys
			cullThrottle._search._visibleVoxelCount = deepIndex

			cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 1)

			local order = drainStagedObjects()
			expect(table.find(order, fastPassed)).toBe(1)
			expect(table.find(order, overRefreshed)).toBe(2)

			cullThrottle._grid._voxels[deepKey] = nil
			cullThrottle._search._visibleVoxelCount = 0
			overRefreshed:Destroy()
			fastPassed:Destroy()
		end)
	end)

	describe("Voxel iteration edge cases", function()
		it("records a zero skip tally when the fast pass starts past the last voxel", function()
			local now = os.clock()
			-- When the precise pass spends its budget exactly on the last voxel,
			-- the handoff calls the fast pass with a start index one past the
			-- end. It must not error, and the tally must record that nothing
			-- actually fell through.
			local part = stageObject(now, 100, 2, 0.04)

			local key = Vector3.new(1e6, 1e6, 1e6)
			cullThrottle._grid._voxels[key] = { cullThrottle._lifecycle._objects[part] }
			cullThrottle._search._visibleVoxelKeys = { key }
			cullThrottle._search._visibleVoxelCount = 1

			-- Plant a sentinel so the zero is provably written rather than left over.
			local perfMetrics = cullThrottle._perfMetrics
			perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor] = 5

			cullThrottle._ingest:clearStagedObjects()
			expect(function()
				cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 2)
			end).never.toThrow()

			expect(perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor]).toBe(0)
			local order = drainStagedObjects()
			expect(#order).toBe(0)

			cullThrottle._grid._voxels[key] = nil
			cullThrottle._search._visibleVoxelCount = 0
			part:Destroy()
		end)

		it("skips a visible voxel missing from the grid while ingesting the rest in both passes", function()
			local now = os.clock()
			-- The search can stage a voxel key whose voxel got emptied out of the
			-- grid before ingest ran, so both passes must step over it without
			-- erroring and still ingest the voxels around it.
			local part = stageObject(now, 100, 2, 0.04)
			local objectData = cullThrottle._lifecycle._objects[part]

			local missingKey = Vector3.new(1e6, 1e6, 1e6)
			local presentKey = Vector3.new(1e6, 1e6, 1e6 + 1)
			cullThrottle._grid._voxels[presentKey] = { objectData }
			cullThrottle._search._visibleVoxelKeys = { missingKey, presentKey }
			cullThrottle._search._visibleVoxelCount = 2

			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._ingest:clearStagedObjects()
			expect(function()
				cullThrottle._ingest:ingestVisibleVoxels(now)
			end).never.toThrow()
			local order = drainStagedObjects()
			expect(table.find(order, part)).toBe(1)

			-- Resetting the per-frame stamp makes the fast pass do the work again.
			objectData.lastCheckClock = 0
			cullThrottle._ingest:clearStagedObjects()
			expect(function()
				cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 1)
			end).never.toThrow()
			order = drainStagedObjects()
			expect(table.find(order, part)).toBe(1)

			cullThrottle._grid._voxels[presentKey] = nil
			cullThrottle._search._visibleVoxelCount = 0
			part:Destroy()
		end)
	end)

	describe("Visible voxel ordering", function()
		it("accumulates added voxels into the pending buffer in call order", function()
			-- The subject here is VisibilitySearch's addVoxelKeyToVisible, pinned
			-- in this file because the pending buffer it fills is exactly what
			-- the sort under test consumes.
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

		it("keeps equal-distance voxels in their original order through the sort", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- All four offsets sit at manhattan distance two in distinct
			-- directions, so the documented stability is the only thing that
			-- can order them.
			local equalOffsets = {
				Vector3.new(2, 0, 0),
				Vector3.new(0, 2, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(0, 1, 1),
			}
			for _, offset in equalOffsets do
				cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + offset)
			end

			cullThrottle._ingest:sortVisibleVoxelKeys()

			for i, offset in equalOffsets do
				expect(cullThrottle._search._visibleVoxelKeys[i]).toBe(cameraVoxel + offset)
			end
		end)

		it("sorts correctly on a second batch with a smaller max distance", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- The first sort fills the reused scratch counts out to a wide max
			-- distance, leaving stale prefix sums behind in the higher buckets.
			local wideOffsets = {
				Vector3.new(3, 2, 1), -- This one sits at distance 6.
				Vector3.new(1, 0, 0), -- This one sits at distance 1.
				Vector3.new(2, 2, 0), -- This one sits at distance 4.
			}
			for _, offset in wideOffsets do
				cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + offset)
			end
			cullThrottle._ingest:sortVisibleVoxelKeys()

			-- The second batch tops out at distance 2, well inside the stale
			-- range, so only a correct reset of the reused counts can place its
			-- voxels in the right slots.
			cullThrottle._search._visibleVoxelCount = 0
			local narrowOffsets = {
				Vector3.new(0, 2, 0), -- This one sits at distance 2.
				Vector3.new(0, 0, 0), -- This one sits at distance 0.
				Vector3.new(-1, 0, 0), -- This one sits at distance 1.
			}
			for _, offset in narrowOffsets do
				cullThrottle._search:addVoxelKeyToVisible(cameraVoxel + offset)
			end
			cullThrottle._ingest:sortVisibleVoxelKeys()

			expect(cullThrottle._search._visibleVoxelCount).toBe(3)
			expect(cullThrottle._search._visibleVoxelKeys[1]).toBe(cameraVoxel)
			expect(cullThrottle._search._visibleVoxelKeys[2]).toBe(cameraVoxel + Vector3.new(-1, 0, 0))
			expect(cullThrottle._search._visibleVoxelKeys[3]).toBe(cameraVoxel + Vector3.new(0, 2, 0))
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
			-- Spread objects through the view at increasing depth so the search
			-- produces a multi-voxel batch to order.
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 7 do
				local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -120 * i)).Position)
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- Generous budgets let the search and ingest both run to completion.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle:_findVisibleObjects(os.clock())

			-- The sort only matters when several voxels are visible, so prove
			-- the staging actually produced a batch.
			expect(cullThrottle._search._visibleVoxelCount).toBeGreaterThan(1)

			-- The batch must come out non-decreasing in manhattan distance to
			-- the camera (the ingest passes depend on it).
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
			-- The subject here is the facade's _resizeTables, pinned in this file
			-- because the sorted visible list is the buffer it must not corrupt.
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
