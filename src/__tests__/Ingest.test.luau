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
		-- Every test stages its own batch, so each one starts from a
		-- known-empty staged batch with the layout guard re-armed.
		cullThrottle._ingest:clearStagedObjects()
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
	local function prepareScoredObject(now: number, distance: number, radius: number, elapsed: number): Instance
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

	describe("Culling and input hygiene", function()
		it("excludes objects beyond the render distance", function()
			local now = os.clock()
			local part = prepareScoredObject(now, 500, 2, 0.04)
			cullThrottle._config.renderDistance = 100

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
			local part = prepareScoredObject(now, 500, 2, 0.04)
			cullThrottle._config.renderDistance = 100

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
			local part = prepareScoredObject(now, 200, 2, 0.04)
			-- The stored distance goes stale when the camera moves while the
			-- object's voxel keeps falling to the fast pass, so we plant a stale
			-- value and expect ingest to overwrite it with the real distance.
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.distance = 50

			fastIngestObjects(cullThrottle, now, { part })

			expect(objectData.distance).toBeCloseTo(200)
			-- It still got staged and dequeues like any visible object.
			local order = drainStagedObjects()
			expect(table.find(order, part)).toBe(1)

			part:Destroy()
		end)

		it("skips an object whose position has gone NaN in both passes", function()
			local now = os.clock()
			-- A NaN position makes every comparison against its distance false, so
			-- the render distance cull must be phrased to reject it. Letting it
			-- through would feed a NaN band into the queue, corrupting the
			-- counting sort's layout.
			local part = prepareScoredObject(now, 100, 2, 0.04)
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.position = Vector3.new(0 / 0, 0 / 0, 0 / 0)

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

		it("skips an object whose radius has gone NaN instead of banding it", function()
			local now = os.clock()
			-- A NaN bounding box with a finite position leaves the object parked
			-- in its old voxels (the grid holds them steady until geometry
			-- recovers), so the precise pass must cull the NaN radius before it
			-- reaches the screen-size arithmetic, where every banding branch
			-- would produce a NaN band and crash the queue's counting sort.
			local part = prepareScoredObject(now, 100, 0 / 0, 0.04)

			ingestObjects(cullThrottle, now, { part })

			local order = drainStagedObjects()
			expect(#order).toBe(0)
			expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

			part:Destroy()
		end)

		it("skips an object whose radius has gone infinite instead of banding it", function()
			local now = os.clock()
			-- An infinite radius isn't NaN, so it compares like an ordinary
			-- number and would slip past a NaN-only check. The guard is phrased
			-- against math.huge itself, so the object waits here until its
			-- geometry recovers instead of riding an infinite screen size into
			-- the priority math.
			local part = prepareScoredObject(now, 100, math.huge, 0.04)

			ingestObjects(cullThrottle, now, { part })

			local order = drainStagedObjects()
			expect(#order).toBe(0)
			expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

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

			ingestObjects(cullThrottle, now, { part })

			-- Coming out of the queue means it was kept, not culled.
			local order = drainStagedObjects()
			expect(table.find(order, part)).never.toBeNil()

			part:Destroy()
		end)
	end)

	describe("Ingest priority", function()
		it("pushes over-refreshed objects far down the queue", function()
			local now = os.clock()
			-- An elapsed of 0 is under the best refresh period, so this is the
			-- over-refresh branch. A small, distant object keeps the screen size
			-- below 1 so the scaled value stays large.
			local overRefreshed = prepareScoredObject(now, 300, 0.5, 0)
			-- A fair-band companion makes the band ordering observable.
			local due = prepareScoredObject(now, 100, 2, 0.04)

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
			local overRefreshed = prepareScoredObject(now, 10, 50, 0)
			-- A small, distant object that is well overdue (elapsed far past
			-- the worst refresh period) sits in the p0 band.
			local overdue = prepareScoredObject(now, 300, 0.5, 100)

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
			-- it would steal the p0 overrun budget from objects that are overdue.
			-- Distance 40 keeps it past the nearby band, and an elapsed of 0.04
			-- keeps it in the fair band.
			local screenFilling = prepareScoredObject(now, 40, 100, 0.04)
			local overdue = prepareScoredObject(now, 300, 0.5, 100)

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

		it("sorts over-refreshed objects behind objects that are due for a refresh", function()
			local now = os.clock()
			-- A screen-filling object (radius well above distance) clamps the
			-- screen-size term to zero, which must not let its just-refreshed
			-- priority undercut the fair band. An elapsed of 0 selects the
			-- over-refresh branch.
			local overRefreshed = prepareScoredObject(now, 10, 50, 0)
			-- An elapsed between the best and worst refresh periods stages a due
			-- object in the fair band.
			local due = prepareScoredObject(now, 300, 0.5, 0.04)

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
			local smallPart = prepareScoredObject(now, 100, 0.5, 100)
			local bigPart = prepareScoredObject(now, 100, 5, 100)

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
			local nearPart = prepareScoredObject(now, 10, 2, 0.04)
			local farPart = prepareScoredObject(now, 20, 2, 0.04)

			ingestObjects(cullThrottle, now, { nearPart, farPart })

			local order, bands = drainStagedObjects()

			-- The nearer object dequeues first from a strictly earlier band, so
			-- a constant nearby score can't pass here, and both land in the p0
			-- slices most of the nearby range maps onto.
			expect(table.find(order, nearPart)).toBe(1)
			expect(table.find(order, farPart)).toBe(2)
			expect(bands[nearPart] < bands[farPart]).toBe(true)
			expect(bands[farPart] <= Ingest.P0_BAND_COUNT).toBe(true)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("ranks a farther object below a nearer one in the fair band", function()
			local now = os.clock()
			-- Both are past the nearby threshold and refreshing at a fair rate, so they
			-- take the weighted-blend branch where distance and screen size matter.
			local nearPart = prepareScoredObject(now, 100, 2, 0.04)
			local farPart = prepareScoredObject(now, 200, 2, 0.04)

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
			local bigPart = prepareScoredObject(now, 100, 5, 0.04)
			local smallPart = prepareScoredObject(now, 100, 1, 0.04)

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
			local fresher = prepareScoredObject(now, 100, 2, 0.02)
			local overdue = prepareScoredObject(now, 100, 2, 0.06)

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
			local nearPart = prepareScoredObject(now, 100, 2, 0.04)
			local farPart = prepareScoredObject(now, 350, 7, 0.04)
			cullThrottle._config.renderDistance = 400

			ingestObjects(cullThrottle, now, { farPart, nearPart })

			local order = drainStagedObjects()
			expect(table.find(order, nearPart)).toBe(1)
			expect(table.find(order, farPart)).toBe(2)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("ranks a large fresh object ahead of a small overdue one within the refresh window", function()
			local now = os.clock()
			-- Both objects sit in the fair blend, where the 85-point screen-size
			-- weight is meant to dominate the 13-point refresh weight (MATH.md
			-- section 17 walks the same arithmetic). The large object just
			-- updated, so it pays nearly the whole refresh term, while the small
			-- one has nearly finished its window, so the refresh term favors the
			-- small object by around eleven points. The screen-size term favors
			-- the large object by around 48 points and must win the band
			-- ordering, so inverting the two weights fails here. The radii are
			-- derived from the projection so the screen sizes hit the intended
			-- fractions at any field of view.
			local distance = 100
			local tanHalfVerticalFov = CameraCache.TanHalfVertFOV
			local largeFresh = prepareScoredObject(now, distance, 0.6 * distance * tanHalfVerticalFov, 0.02)
			local smallOverdue = prepareScoredObject(now, distance, 0.03 * distance * tanHalfVerticalFov, 0.06)

			ingestObjects(cullThrottle, now, { smallOverdue, largeFresh })

			local order, bands = drainStagedObjects()
			expect(table.find(order, largeFresh)).toBe(1)
			expect(table.find(order, smallOverdue)).toBe(2)
			expect(bands[largeFresh] < bands[smallOverdue]).toBe(true)

			largeFresh:Destroy()
			smallOverdue:Destroy()
		end)

		it("sends a just-refreshed nearby object to the over-refresh band, not the nearby band", function()
			local now = os.clock()
			-- The over-refresh check outranks the nearby check in the branch
			-- ladder. Reordering them would make objects right by the camera
			-- refresh every frame no matter how recently they updated.
			local part = prepareScoredObject(now, 15, 2, 0)

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
			local part = prepareScoredObject(now, 0, 2, 100)

			ingestObjects(cullThrottle, now, { part })

			local order, bands = drainStagedObjects()
			expect(table.find(order, part)).toBe(1)
			expect(bands[part]).toBe(1)

			part:Destroy()
		end)

		it("keeps a hugely overdue zero-size object inside the p0 region", function()
			local now = os.clock()
			-- A zero radius is reachable in production (a light with Range 0
			-- boxes to nothing), and it projects to a screen size of exactly
			-- zero, which lands the p0 slice arithmetic exactly one band past
			-- the p0 region. The branch exists to guarantee overdue objects
			-- the p0 overrun budget, so the back edge must clamp into the last
			-- p0 slice instead of leaking into the fair region.
			local part = prepareScoredObject(now, 100, 0, 100)

			ingestObjects(cullThrottle, now, { part })

			local _, bands = drainStagedObjects()
			expect(bands[part]).toBe(Ingest.P0_BAND_COUNT)

			part:Destroy()
		end)

		it("clamps a just-refreshed zero-size object into the last over-refresh band", function()
			local now = os.clock()
			-- A zero screen size pushes the over-refresh tier arithmetic to
			-- OVER_BAND_COUNT, one slice past the region, and the clamp pulls
			-- it back into the final band. Without the clamp the band lands
			-- past the queue's band table and the layout pass errors on a nil
			-- band count.
			local part = prepareScoredObject(now, 100, 0, 0)

			ingestObjects(cullThrottle, now, { part })

			local _, bands = drainStagedObjects()
			expect(bands[part]).toBe(Ingest.OVER_BAND_OFFSET + Ingest.OVER_BAND_COUNT - 1)

			part:Destroy()
		end)

		it("slices the over-refresh region by screen size", function()
			local now = os.clock()
			-- Both objects were refreshed within their best period, so both land
			-- in the over-refresh region at the very back, and the bigger one
			-- takes an earlier slice so leftover budget still favors what shows
			-- most on screen.
			local big = prepareScoredObject(now, 100, 20, 0)
			local small = prepareScoredObject(now, 100, 1, 0)

			ingestObjects(cullThrottle, now, { small, big })

			local order, bands = drainStagedObjects()
			expect(bands[big] >= Ingest.OVER_BAND_OFFSET).toBe(true)
			expect(bands[small] >= Ingest.OVER_BAND_OFFSET).toBe(true)
			expect(bands[big] < bands[small]).toBe(true)
			expect(table.find(order, big)).toBe(1)
			expect(table.find(order, small)).toBe(2)

			big:Destroy()
			small:Destroy()
		end)

		it("lets a fair score dipping under the p0 threshold take the matching p0 slice", function()
			local now = os.clock()
			-- A screen-filling object (the clamped term contributes zero) that
			-- is nearly due (the refresh term nearly gone) and close (a tiny
			-- distance term) blends to a score around 0.23, under the p0
			-- threshold, without taking the p0 or nearby branches. The dip hands
			-- it the matching p0 slice and the overrun budget that comes with it.
			local part = prepareScoredObject(now, 32, 100, 0.066)

			ingestObjects(cullThrottle, now, { part })

			local _, bands = drainStagedObjects()
			expect(bands[part] <= Ingest.P0_BAND_COUNT).toBe(true)

			part:Destroy()
		end)

		it("sends the nearby branch's farthest sliver to the first fair band", function()
			local now = os.clock()
			-- Within the nearby threshold the score is the distance fraction,
			-- and from 27 studs out that fraction crosses the p0 threshold, so
			-- the farthest sliver of the nearby range takes the first fair band
			-- rather than a p0 slice.
			local part = prepareScoredObject(now, 28, 2, 0.04)

			ingestObjects(cullThrottle, now, { part })

			local _, bands = drainStagedObjects()
			expect(bands[part]).toBe(Ingest.FAIR_BAND_OFFSET)

			part:Destroy()
		end)

		it("parks an object elapsed exactly at its best refresh period in the over-refresh region", function()
			local now = os.clock()
			-- The over-refresh check is at-or-under, so an object exactly at its
			-- best refresh period still counts as refreshed within it. The
			-- jitter offset carries the whole elapsed value, making the
			-- comparison see the config's own number with no clock subtraction
			-- drift. A strict comparison would drop this object into the fair
			-- region instead.
			local part = prepareScoredObject(now, 100, 2, 0)
			cullThrottle._lifecycle._objects[part].jitterOffset = cullThrottle._config.bestRefreshPeriod

			ingestObjects(cullThrottle, now, { part })

			local _, bands = drainStagedObjects()
			expect(bands[part] >= Ingest.OVER_BAND_OFFSET).toBe(true)

			part:Destroy()
		end)

		it("gives an object elapsed exactly at its worst refresh period p0 priority", function()
			local now = os.clock()
			-- The p0 check is at-or-past, so an object exactly at its worst
			-- refresh period is already overdue. The jitter offset carries the
			-- whole elapsed value, making the comparison see the config's own
			-- number with no clock subtraction drift. A strict comparison would
			-- drop this object into the fair region instead.
			local part = prepareScoredObject(now, 100, 2, 0)
			cullThrottle._lifecycle._objects[part].jitterOffset = cullThrottle._config.worstRefreshPeriod

			ingestObjects(cullThrottle, now, { part })

			local _, bands = drainStagedObjects()
			expect(bands[part] <= Ingest.P0_BAND_COUNT).toBe(true)

			part:Destroy()
		end)

		it("sends an object exactly at the nearby threshold to the fair blend", function()
			-- The nearby check is strictly less-than, so a distance exactly at
			-- the threshold takes the weighted fair blend instead of the nearby
			-- score. At the threshold the nearby score would be exactly 1,
			-- landing exactly on the first fair band, while the fair blend for a
			-- small object lands deep in the fair region, so the two sides of
			-- the comparison are told apart at band granularity. The camera
			-- moves to the origin for the test so the distance computes to
			-- exactly 30 with no float drift, and it moves back before the
			-- assertions run.
			local camera = workspace.CurrentCamera
			local savedCameraCFrame = camera.CFrame
			camera.CFrame = CFrame.new(0, 0, 0)
			CameraCache.cframeChanged()

			local now = os.clock()
			local part = prepareScoredObject(now, 30, 2, 0.04)
			ingestObjects(cullThrottle, now, { part })

			camera.CFrame = savedCameraCFrame
			CameraCache.cframeChanged()

			local _, bands = drainStagedObjects()
			expect(bands[part] > Ingest.FAIR_BAND_OFFSET).toBe(true)

			part:Destroy()
		end)
	end)

	describe("Staged batch lifecycle", function()
		it("lays the staged batch into the queue only once until the batch clears", function()
			local now = os.clock()
			local partA = prepareScoredObject(now, 100, 2, 0.04)
			local partB = prepareScoredObject(now, 150, 2, 0.04)
			ingestObjects(cullThrottle, now, { partA, partB })

			local ingest = cullThrottle._ingest
			local queue = ingest._visibleObjectsQueue
			-- Without the guard the second call would append the whole batch
			-- again behind itself, and the drain would hand every object back
			-- twice within one frame.
			ingest:enqueueStagedObjects()
			ingest:enqueueStagedObjects()
			expect(queue:len()).toBe(2)

			local drained = 0
			local seen = {}
			while not queue:isEmpty() do
				local objectData = queue:dequeue()
				expect(seen[objectData.object]).toBeNil()
				seen[objectData.object] = true
				drained += 1
			end
			expect(drained).toBe(2)

			-- Clearing the staged batch re-arms the guard, so the next frame's
			-- batch lays out again.
			ingest:clearStagedObjects()
			local later = now + 1
			ingestObjects(cullThrottle, later, { partA, partB })
			ingest:enqueueStagedObjects()
			expect(queue:len()).toBe(2)

			partA:Destroy()
			partB:Destroy()
		end)

		it("empties both the staged batch and the queue layout on clearFrame", function()
			local now = os.clock()
			local part = prepareScoredObject(now, 100, 2, 0.04)
			ingestObjects(cullThrottle, now, { part })

			local ingest = cullThrottle._ingest
			ingest:enqueueStagedObjects()
			expect(ingest._stagedSize).toBe(1)
			expect(ingest._visibleObjectsQueue:len()).toBe(1)

			-- A fresh visibility pass resets both halves of the ingest output,
			-- so nothing staged or laid out last frame leaks into the new one.
			ingest:clearFrame()

			expect(ingest._stagedSize).toBe(0)
			expect(ingest._visibleObjectsQueue:len()).toBe(0)
			expect(ingest._visibleObjectsQueue:isEmpty()).toBe(true)

			part:Destroy()
		end)

		it("keeps the queue layout draining when only the staged batch clears", function()
			local now = os.clock()
			local nearPart = prepareScoredObject(now, 100, 2, 0.04)
			local farPart = prepareScoredObject(now, 150, 2, 0.04)
			ingestObjects(cullThrottle, now, { nearPart, farPart })

			local ingest = cullThrottle._ingest
			local queue = ingest._visibleObjectsQueue
			ingest:enqueueStagedObjects()
			local first = queue:dequeue()
			expect(first.object).toBe(nearPart)

			-- Clearing the staged batch mid-drain leaves the queue layout
			-- alone, so a live drain picks up right where it was.
			ingest:clearStagedObjects()

			expect(ingest._stagedSize).toBe(0)
			expect(queue:len()).toBe(1)
			local second = queue:dequeue()
			expect(second.object).toBe(farPart)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("keeps the staged batch intact across a buffer resize", function()
			local now = os.clock()
			local nearPart = prepareScoredObject(now, 100, 2, 0.04)
			local farPart = prepareScoredObject(now, 200, 2, 0.04)
			ingestObjects(cullThrottle, now, { nearPart, farPart })

			-- The staged batch backs GetVisibleObjects until the next frame
			-- restages it, so the rebuild must preserve contents, and the
			-- layout built from the preserved batch must still drain in order.
			cullThrottle._ingest:resizeBuffers()

			expect(cullThrottle._ingest._stagedSize).toBe(2)
			expect(stagedOccurrences(nearPart)).toBe(1)
			expect(stagedOccurrences(farPart)).toBe(1)

			local order = drainStagedObjects()
			expect(table.find(order, nearPart)).toBe(1)
			expect(table.find(order, farPart)).toBe(2)

			nearPart:Destroy()
			farPart:Destroy()
		end)
	end)

	describe("Multi-voxel deduplication", function()
		it("ingests an object spanning two visible voxels only once in the precise pass", function()
			local now = os.clock()
			local part = prepareScoredObject(now, 100, 2, 0.04)
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
			cullThrottle._ingest:ingestVisibleVoxels(now)

			-- It was staged exactly once.
			expect(stagedOccurrences(part)).toBe(1)
			-- It was marked visible exactly once, so exactly one entered-view
			-- event comes out of the end-of-frame flush.
			local enteredFires = 0
			local connection = cullThrottle.ObjectEnteredView:Connect(function(object)
				if object == part then
					enteredFires += 1
				end
			end)
			cullThrottle._signals:flushVisibilitySignals()
			connection:Disconnect()
			expect(enteredFires).toBe(1)

			cullThrottle._grid._voxels[keyA] = nil
			cullThrottle._grid._voxels[keyB] = nil
			cullThrottle._search._visibleVoxelCount = 0
			part:Destroy()
		end)

		it("does not duplicate an object spanning several voxels in the fast pass", function()
			local now = os.clock()
			local part = prepareScoredObject(now, 100, 2, 0.04)

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
			local part = prepareScoredObject(now, 100, 2, 0.04)

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
				nearObjects[i] = prepareScoredObject(now, 100, 2, 0.04)
			end
			local farObjects = {}
			for i = 1, 3 do
				farObjects[i] = prepareScoredObject(now, 200, 2, 0.04)
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
				parts[i] = prepareScoredObject(now, 100, 2, 0.04)
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

		it("records the ingest duration when the precise pass finishes within budget", function()
			local now = os.clock()
			-- The completed pass writes the metric on its normal exit too, so a
			-- frame that never hands off still reports how long ingest ran. The
			-- sentinel proves the value was written rather than left over.
			local part = prepareScoredObject(now, 100, 2, 0.04)
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._perfMetrics._ingestDuration = -1

			ingestObjects(cullThrottle, now, { part })

			expect(cullThrottle._perfMetrics._ingestDuration >= 0).toBe(true)

			part:Destroy()
		end)
	end)

	describe("Fast-pass banding", function()
		it("bands farther fast-pass voxels behind nearer ones", function()
			local now = os.clock()
			-- The fast pass can't score objects, so it must still dequeue nearer
			-- voxels first through the per-voxel tier scale.
			local partA = prepareScoredObject(now, 100, 2, 0.04)
			local partB = prepareScoredObject(now, 200, 2, 0.04)

			local keyA = Vector3.new(1e6, 1e6, 1e6)
			local keyB = Vector3.new(1e6, 1e6, 1e6 + 1)
			cullThrottle._grid._voxels[keyA] = { cullThrottle._lifecycle._objects[partA] }
			cullThrottle._grid._voxels[keyB] = { cullThrottle._lifecycle._objects[partB] }
			cullThrottle._search._visibleVoxelKeys = { keyA, keyB }
			cullThrottle._search._visibleVoxelCount = 2

			cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 1)

			-- The earlier voxel's object dequeues first, from an earlier,
			-- distinct tier.
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
			local overRefreshed = prepareScoredObject(now, 10, 50, 0)
			local fastPassed = prepareScoredObject(now, 200, 2, 0.04)

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

		it("saturates the fast-pass tiers at the cap so the deepest voxels share one band", function()
			local now = os.clock()
			local cap = Ingest.FAST_VOXEL_TIER_CAP
			-- Three voxels bracket the tier cap. The one just inside it keeps
			-- its own tier, and the ones at and past it share the deepest tier,
			-- which pins the exact band on both sides of the cap comparison.
			local justInside = prepareScoredObject(now, 100, 2, 0.04)
			local atCap = prepareScoredObject(now, 150, 2, 0.04)
			local pastCap = prepareScoredObject(now, 200, 2, 0.04)

			local keys = table.create(cap + 1)
			for i = 1, cap + 1 do
				keys[i] = Vector3.new(2e6 + i, 2e6, 2e6)
			end
			cullThrottle._grid._voxels[keys[cap - 1]] = { cullThrottle._lifecycle._objects[justInside] }
			cullThrottle._grid._voxels[keys[cap]] = { cullThrottle._lifecycle._objects[atCap] }
			cullThrottle._grid._voxels[keys[cap + 1]] = { cullThrottle._lifecycle._objects[pastCap] }
			cullThrottle._search._visibleVoxelKeys = keys
			cullThrottle._search._visibleVoxelCount = cap + 1

			cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 1)

			local order, bands = drainStagedObjects()
			expect(bands[justInside]).toBe(Ingest.FAST_BAND_OFFSET + cap - 1)
			expect(bands[atCap]).toBe(Ingest.FAST_BAND_OFFSET + cap)
			expect(bands[pastCap]).toBe(bands[atCap])
			-- Within the shared deepest tier, search order still holds through
			-- staging order.
			expect(table.find(order, justInside)).toBe(1)
			expect(table.find(order, atCap)).toBe(2)
			expect(table.find(order, pastCap)).toBe(3)

			cullThrottle._grid._voxels[keys[cap - 1]] = nil
			cullThrottle._grid._voxels[keys[cap]] = nil
			cullThrottle._grid._voxels[keys[cap + 1]] = nil
			cullThrottle._search._visibleVoxelCount = 0
			justInside:Destroy()
			atCap:Destroy()
			pastCap:Destroy()
		end)

		it("marks a newly visible object as entered view from the fast pass", function()
			local now = os.clock()
			-- The fast pass owns the same entered-view bookkeeping as the
			-- precise one, so an object it dumps still stamps its visible clock
			-- and buffers exactly one entered event for the flush.
			local part = prepareScoredObject(now, 100, 2, 0.04)
			local objectData = cullThrottle._lifecycle._objects[part]
			expect(objectData.lastVisibleClock).toBe(0)

			local enteredFires = 0
			local connection = cullThrottle.ObjectEnteredView:Connect(function(object)
				if object == part then
					enteredFires += 1
				end
			end)

			fastIngestObjects(cullThrottle, now, { part })

			expect(objectData.lastVisibleClock).toBe(now)
			cullThrottle._signals:flushVisibilitySignals()
			connection:Disconnect()
			expect(enteredFires).toBe(1)

			part:Destroy()
		end)
	end)

	describe("Voxel iteration edge cases", function()
		it("records a zero skip tally when the fast pass starts past the last voxel", function()
			local now = os.clock()
			-- When the precise pass spends its budget exactly on the last voxel,
			-- the handoff calls the fast pass with a start index one past the
			-- end. It must not error, and the tally must record that nothing
			-- fell through.
			local part = prepareScoredObject(now, 100, 2, 0.04)

			local key = Vector3.new(1e6, 1e6, 1e6)
			cullThrottle._grid._voxels[key] = { cullThrottle._lifecycle._objects[part] }
			cullThrottle._search._visibleVoxelKeys = { key }
			cullThrottle._search._visibleVoxelCount = 1

			-- Plant a sentinel so the zero is definitely written rather than left over.
			local perfMetrics = cullThrottle._perfMetrics
			perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor] = 5

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
			local part = prepareScoredObject(now, 100, 2, 0.04)
			local objectData = cullThrottle._lifecycle._objects[part]

			local missingKey = Vector3.new(1e6, 1e6, 1e6)
			local presentKey = Vector3.new(1e6, 1e6, 1e6 + 1)
			cullThrottle._grid._voxels[presentKey] = { objectData }
			cullThrottle._search._visibleVoxelKeys = { missingKey, presentKey }
			cullThrottle._search._visibleVoxelCount = 2

			cullThrottle._config.ingestTimeBudget = 1
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
end)
