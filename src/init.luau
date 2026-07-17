--!strict
--!optimize 2
--!native

--[[
	This is CullThrottle's entry point, the facade that owns the public API, the
	signals, the configuration, and the per-frame driver. It composes the
	subsystem objects (grid, search, ingest, signals, lifecycle, and friends)
	that do the work.
]]

local RunService = game:GetService("RunService")

if _G.__DEV__ then
	print("Allowing CullThrottle on server during dev for unit test purposes")
else
	if RunService:IsServer() and not RunService:IsEdit() then
		error("CullThrottle is a client side effect and cannot be used on the server")
	end
end

local types = require(script.types)
local Config = require(script.Config)
local GoodSignal = require(script.Utilities.GoodSignal)

local CameraMotion = require(script.CameraMotion)
local Ingest = require(script.Ingest)
local ObjectLifecycle = require(script.ObjectLifecycle)
local OcclusionCulling = require(script.OcclusionCulling)
local RenderDistanceController = require(script.RenderDistanceController)
local VisibilityCache = require(script.VisibilityCache)
local VisibilitySearch = require(script.VisibilitySearch)
local VisibilitySignals = require(script.VisibilitySignals)
local VoxelGrid = require(script.VoxelGrid)

local tableCreate = table.create

-- Queue bands at or under this are the p0 (must refresh this frame) region.
local P0_BAND_COUNT = Ingest.P0_BAND_COUNT
-- P0 objects may run the update budget over by this factor, unless
-- strictlyEnforceWorstRefreshRate makes their budget effectively unbounded.
local P0_UPDATE_BUDGET_OVERRUN = 1.15
-- The update drain's planned clock-check batches cap at this many objects (see
-- IterateObjectsToUpdate).
local DRAIN_CLOCK_CHECK_MAX_BATCH = 8
-- The reusable buffers get rebuilt at most once per this many seconds.
local RESIZE_TABLES_PERIOD = 5
-- The skipped-voxel ring buffers hold this many frames, so one bad frame keeps
-- shrink pressure on the render distance controller until it ages out.
local SKIPPED_FRAMES_LOOKBACK = 4

-- Per-frame voxel upkeep budgets, spent before the search.
local PHYSICS_POLL_TIME_BUDGET = 5e-5
local VOXEL_MAINTENANCE_TIME_BUDGET = 5e-5
-- Changing the voxel size must reslot every object before the next frame, so
-- SetVoxelSize uses this effectively unbounded budget of 5 whole seconds.
local FULL_RESLOT_TIME_BUDGET = 5

--[[
	Averages a skipped-frame ring buffer over the full lookback window, so a frame
	that recorded nothing still weighs in as a zero rather than dropping out of
	the denominator.
]]
local function getSkippedFramesAverage(values: { number }): number
	local sum = 0
	for _, value in values do
		sum += value
	end
	return sum / SKIPPED_FRAMES_LOOKBACK
end

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type CullThrottleProto = {
	ObjectEnteredView: GoodSignal.Signal<Instance>,
	ObjectExitedView: GoodSignal.Signal<Instance>,
	ObjectAdded: GoodSignal.Signal<Instance>,
	ObjectRemoved: GoodSignal.Signal<Instance>,

	_config: Config.Config,
	_perfMetrics: types.PerfMetrics,

	_visibilityCache: VisibilityCache.VisibilityCache,
	_motion: CameraMotion.CameraMotion,
	_grid: VoxelGrid.VoxelGrid,
	_signals: VisibilitySignals.VisibilitySignals,
	_occlusion: OcclusionCulling.OcclusionCulling,
	_search: VisibilitySearch.VisibilitySearch,
	_ingest: Ingest.Ingest,
	_lifecycle: ObjectLifecycle.ObjectLifecycle,
	_renderDistanceController: RenderDistanceController.RenderDistanceController,

	_renderConnection: RBXScriptConnection,
	_processedVisibilityThisFrame: boolean,
	_lastTableResize: number,
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

--[[
	We've got a couple arrays that we clear without shrinking their size, so we
	occasionally rebuild them at their current occupancy to avoid wasting space.
]]
function CullThrottle._resizeTables(self: CullThrottle)
	self._search:resizeBuffers()
	self._signals:resizeBuffers()
	self._ingest:resizeBuffers()
end

--[[
	Resets the visible voxel and object accumulators for a fresh frame, and
	commits the previous frame's update delta times into the average.
]]
function CullThrottle._clearVisibleObjects(self: CullThrottle)
	-- Committing at the start of the next processed frame covers completed and
	-- abandoned iterations alike, since a consumer can break out of the update
	-- loop early.
	local perfMetrics = self._perfMetrics
	if perfMetrics._updatedObjectCount > 0 then
		perfMetrics._averageObjectDeltaTime = perfMetrics._sumOfObjectDeltaTimes / perfMetrics._updatedObjectCount
		perfMetrics._sumOfObjectDeltaTimes = 0
		perfMetrics._updatedObjectCount = 0
	end

	self._search:clearVisibleVoxels()
	self._ingest:clearFrame()
end

--[[
	This is the frame's visibility pass. It advances the camera-motion
	accumulators, runs the search (seeding from the coarse buckets and
	subdividing within its budget), then sorts the visible voxels closest-first
	and ingests them into the prioritized update queue.
]]
function CullThrottle._findVisibleObjects(self: CullThrottle, now: number)
	debug.profilebegin("findVisibleObjects")

	self:_clearVisibleObjects()

	local perfMetrics = self._perfMetrics
	local cursor = (perfMetrics._skippedFramesCursor % SKIPPED_FRAMES_LOOKBACK) + 1
	perfMetrics._skippedFramesCursor = cursor
	perfMetrics._skippedIngest[cursor] = 0
	perfMetrics._skippedSearch[cursor] = 0
	perfMetrics._occludedVoxelCount = 0

	-- Cached visibility verdicts are proven against the motion accumulators, so
	-- they must advance (or flush, on a projection change) before any are consulted.
	self._motion:accumulate()

	self._occlusion:buildUmbrae()

	local replayed = self._search:run(now)

	-- The visible voxels get sorted closest-first so the ingest spends its
	-- budget on the nearest ones. A replayed frame skips the sort, since the
	-- anchor pass's sorted order still stands.
	if not replayed then
		debug.profilebegin("sortVisibleVoxels")
		self._search:sortVisibleVoxelKeys()
		debug.profileend()
	end

	self._ingest:ingestVisibleVoxels(now)

	debug.profileend()
end

--[[
	Runs the whole frame pipeline at most once per frame, covering the voxel
	upkeep, the visibility search and ingest, the exit-signal sweep, the render
	distance controller, and finally the buffered visibility signal flush.
	Re-entry within the same frame short-circuits.
]]
function CullThrottle._processObjectVisibility(self: CullThrottle, start: number)
	if self._processedVisibilityThisFrame then
		return
	end

	debug.profilebegin("CullThrottle.processObjectVisibility")

	-- Each upkeep pass anchors its budget at its own fresh clock rather than at
	-- frame start, so work done earlier in the frame can't eat the budget.
	self._lifecycle:pollPhysicsObjects(PHYSICS_POLL_TIME_BUDGET, os.clock())
	self._grid:updateObjectVoxels(VOXEL_MAINTENANCE_TIME_BUDGET, os.clock())

	self:_findVisibleObjects(start)

	self._signals:signalVisibilityChanges(start)

	self._renderDistanceController:adjust()

	-- Mark the frame done before flushing so a signal handler that re-enters
	-- (say, by calling GetVisibleObjects) short-circuits instead of recomputing
	-- visibility from inside the flush.
	self._processedVisibilityThisFrame = true

	self._signals:flushVisibilitySignals()

	debug.profileend()
end

--[[
	This is the per-frame entry point the PreRender connection drives. It
	resets the once-per-frame guard, periodically rebuilds the reusable
	buffers, and runs the visibility pipeline unless on-demand mode is on and
	nothing demands it. A connected view signal counts as demand, since
	entered/exited can only fire if visibility gets computed.
]]
function CullThrottle._onPreRender(self: CullThrottle, now: number)
	self._processedVisibilityThisFrame = false

	if now - self._lastTableResize > RESIZE_TABLES_PERIOD then
		self._lastTableResize = now
		self:_resizeTables()
	end

	if
		self._config.computeVisibilityOnlyOnDemand == false
		or self.ObjectEnteredView:HasConnections()
		or self.ObjectExitedView:HasConnections()
	then
		self:_processObjectVisibility(now)
	end
end

--[[
	Everything below this point is the public API.
]]

--[[
	Builds an instance with the default configuration, wires the subsystem
	objects together, and starts its PreRender loop. The objects map is created
	here so the lifecycle (its owner) and the grid (which aliases it) can share
	one table without depending on each other.
]]
function CullThrottle.new(): CullThrottle
	local self: CullThrottle = setmetatable({}, CullThrottle) :: any

	self._config = Config.new()

	self.ObjectEnteredView = GoodSignal.new()
	self.ObjectExitedView = GoodSignal.new()
	self.ObjectAdded = GoodSignal.new()
	self.ObjectRemoved = GoodSignal.new()

	self._perfMetrics = {
		_skippedSearch = tableCreate(SKIPPED_FRAMES_LOOKBACK, 0),
		_skippedIngest = tableCreate(SKIPPED_FRAMES_LOOKBACK, 0),
		_skippedFramesCursor = 1,
		_occludedVoxelCount = 0,
		_searchDuration = 0,
		_ingestDuration = 0,
		-- Seeding the average at the best refresh period reads as full headroom,
		-- so a fresh instance's render distance grows until real measurements
		-- take over.
		_averageObjectDeltaTime = self._config.bestRefreshPeriod,
		_sumOfObjectDeltaTimes = 0,
		_updatedObjectCount = 0,
		_getAverage = getSkippedFramesAverage,
	}

	local objects: { [Instance]: types.ObjectData } = {}

	self._visibilityCache = VisibilityCache.new()
	self._motion = CameraMotion.new(self._config, self._visibilityCache)
	self._grid = VoxelGrid.new(self._config, self._visibilityCache, objects)
	self._signals = VisibilitySignals.new(self.ObjectEnteredView, self.ObjectExitedView)
	self._occlusion = OcclusionCulling.new(
		self._config,
		self._visibilityCache,
		self._motion,
		VisibilitySearch.TESTABLE_REACH_EXPANSION
	)
	self._search = VisibilitySearch.new(
		self._config,
		self._grid,
		self._motion,
		self._visibilityCache,
		self._occlusion,
		self._perfMetrics
	)
	self._ingest = Ingest.new(self._config, self._grid, self._search, self._signals, self._perfMetrics)
	self._lifecycle = ObjectLifecycle.new(objects, self._grid, self._signals, self.ObjectAdded, self.ObjectRemoved)
	self._renderDistanceController = RenderDistanceController.new(self._config, self._perfMetrics)

	self._lastTableResize = os.clock()
	self._processedVisibilityThisFrame = false
	self._renderConnection = RunService.PreRender:Connect(function()
		self:_onPreRender(os.clock())
	end)

	return self
end

--[[
	Tears down the instance. It stops the per-frame processing loop (whose
	PreRender connection would otherwise keep the instance and everything it
	references alive forever), disconnects every tag, object, and signal
	connection, and clears the tracked state so it can be garbage collected.
]]
function CullThrottle.Destroy(self: CullThrottle)
	self._renderConnection:Disconnect()

	self._lifecycle:destroy()

	self.ObjectEnteredView:DisconnectAll()
	self.ObjectExitedView:DisconnectAll()
	self.ObjectAdded:DisconnectAll()
	self.ObjectRemoved:DisconnectAll()

	self._grid:destroy()
	self._signals:destroy()
	self._occlusion:destroy()
	self._visibilityCache:clear()
	self._search:destroy()
	self._ingest:destroy()
end

--[[
	Returns a snapshot of every object visible this frame, computing
	visibility first if nothing has processed it yet this frame.
]]
function CullThrottle.GetVisibleObjects(self: CullThrottle): { Instance }
	self:_processObjectVisibility(os.clock())

	-- Removal never scrubs the staged batch, so the snapshot filters out
	-- objects that are no longer tracked, the same defense the update iterator
	-- applies as it drains.
	local objects = self._lifecycle._objects
	local ingest = self._ingest
	local stagedObjects = ingest._stagedObjects
	local stagedSize = ingest._stagedSize
	local visibleObjects = tableCreate(stagedSize)
	local count = 0
	for i = 1, stagedSize do
		local object = stagedObjects[i].object
		if objects[object] then
			count += 1
			visibleObjects[count] = object
		end
	end

	return visibleObjects
end

--[[
	Returns an iterator over this frame's visible objects in update-priority
	order, yielding (object, objectDeltaTime, distance, cframe). Iteration
	stops when the update time budget runs out (p0 objects may overrun it), and
	whatever is left waits, at higher priority, for the next frame. Computes
	visibility first if nothing has processed it yet this frame.
]]
function CullThrottle.IterateObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?, number?, CFrame?)
	self:_processObjectVisibility(os.clock())

	-- The band layout cost lands here, at most once per staged batch, so
	-- frames where nobody iterates never pay it.
	self._ingest:enqueueStagedObjects()

	local updateStartClock = os.clock()
	local queue = self._ingest._visibleObjectsQueue
	-- The queue hands its drain layout over so the loop walks plain arrays,
	-- writing each new cursor position back as it goes per drainView's contract.
	local items, bands, drainStartCursor, size, epoch = queue:drainView()
	local perfMetrics = self._perfMetrics
	local updateTimeBudget = self._config.updateTimeBudget
	local p0UpdateTimeBudget = if self._config.strictlyEnforceWorstRefreshRate
		then 1
		else updateTimeBudget * P0_UPDATE_BUDGET_OVERRUN

	-- An os.clock call per drained object is measurable at queue scale, so the
	-- budget check runs in planned batches, each sized to cover about half the
	-- remaining budget at the average per-object pace so far, capped. The p0
	-- region is a strict prefix of the band-ordered layout, and the first
	-- object past it forces a check so the drop to the plain budget never
	-- rides on a stale plan.
	local objectsUntilClockCheck = 0
	local inP0Prefix = true

	return function()
		-- A cleared or refilled queue means this iterator's frame is over, so
		-- it ends here rather than touching the fresh layout.
		if queue._fillEpoch ~= epoch then
			return nil
		end
		-- The cursor rereads the queue on entry so two live iterators share
		-- drain progress instead of each replaying the other's objects.
		local cursor = queue._cursor
		while cursor < size do
			cursor += 1
			queue._cursor = cursor
			local objectData = items[cursor]

			local leftP0Prefix = false
			if inP0Prefix and bands[cursor] > P0_BAND_COUNT then
				inP0Prefix = false
				leftP0Prefix = true
			end

			if leftP0Prefix or objectsUntilClockCheck <= 0 then
				local budget = if inP0Prefix then p0UpdateTimeBudget else updateTimeBudget
				local elapsed = os.clock() - updateStartClock
				if elapsed >= budget then
					-- Out of time, so the rest waits at higher priority next
					-- frame. The clear keeps leftovers from spilling into a
					-- second same-frame iteration, and its epoch bump ends this
					-- closure and any sibling on their next call.
					queue:clear()

					return nil
				end

				local walked = cursor - drainStartCursor
				if walked > 1 and elapsed > 0 then
					local pace = elapsed / (walked - 1)
					local batch = (budget - elapsed) / (2 * pace)
					objectsUntilClockCheck = if batch >= DRAIN_CLOCK_CHECK_MAX_BATCH
						then DRAIN_CLOCK_CHECK_MAX_BATCH
						else batch // 1
				else
					objectsUntilClockCheck = 1
				end
			end
			objectsUntilClockCheck -= 1

			if objectData.lastVisibleClock == 0 then
				-- Removal doesn't scrub this queue, but it always zeroes
				-- lastVisibleClock, and nothing else can zero it between staging
				-- and this drain, so a zero here means the record is stale.
				continue
			end

			local objectDeltaTime = updateStartClock - objectData.lastUpdateClock
			objectData.lastUpdateClock = updateStartClock

			if objectDeltaTime < 1 then
				-- A dt over a second is an object we haven't seen in a while,
				-- not a real refresh rate, so it stays out of the average.
				perfMetrics._sumOfObjectDeltaTimes += objectDeltaTime
				perfMetrics._updatedObjectCount += 1
			end

			return objectData.object, objectDeltaTime, objectData.distance, objectData.cframe
		end
		return nil
	end
end

--[[
	Begins tracking an object (see ObjectLifecycle.addObject).
]]
function CullThrottle.AddObject(self: CullThrottle, object: Instance)
	self._lifecycle:addObject(object)
end

--[[
	Begins tracking a physics-driven part (see ObjectLifecycle.addPhysicsObject).
]]
function CullThrottle.AddPhysicsObject(self: CullThrottle, object: BasePart)
	self._lifecycle:addPhysicsObject(object)
end

--[[
	Stops tracking an object (see ObjectLifecycle.removeObject).
]]
function CullThrottle.RemoveObject(self: CullThrottle, object: Instance)
	self._lifecycle:removeObject(object)
end

--[[
	Tracks every instance carrying the tag, now and as the tag set changes
	(see ObjectLifecycle.captureTag).
]]
function CullThrottle.CaptureTag(self: CullThrottle, tag: string)
	self._lifecycle:captureTag(tag)
end

--[[
	Stops watching a captured tag (see ObjectLifecycle.releaseTag).
]]
function CullThrottle.ReleaseTag(self: CullThrottle, tag: string)
	self._lifecycle:releaseTag(tag)
end

--[[
	Removes every tracked object carrying the tag
	(see ObjectLifecycle.removeObjectsWithTag).
]]
function CullThrottle.RemoveObjectsWithTag(self: CullThrottle, tag: string)
	self._lifecycle:removeObjectsWithTag(tag)
end

--[[
	Sets the voxel grid cell size in studs, flushes every voxel-unit cache,
	and reslots all tracked objects into the new grid before the next frame.
]]
function CullThrottle.SetVoxelSize(self: CullThrottle, voxelSize: number)
	if not (voxelSize > 0 and voxelSize < math.huge) then
		-- The check is phrased so zero, negatives, infinity, and NaN all fail
		-- into it, since each corrupts the voxel coordinate math.
		error("SetVoxelSize expects a finite voxel size greater than zero")
	end

	self._config:setVoxelSize(voxelSize)

	-- Every cached verdict and motion accumulator is in voxel units, so a new
	-- voxel size invalidates all of them.
	self._motion:flushVisibilityCache()

	self._grid:clearAll()

	for object, objectData in self._lifecycle._objects do
		self._grid:updateDesiredVoxelKeys(object, objectData)
	end

	self._grid:updateObjectVoxels(FULL_RESLOT_TIME_BUDGET, os.clock())
end

--[[
	Sets the [min, max] render distance bounds in studs. A range spanning more
	than one value enables the dynamic render distance controller, while a
	zero-width range pins the distance and disables it. The live distance
	resets to the range's midpoint.
]]
function CullThrottle.SetRenderDistanceRange(self: CullThrottle, renderDistanceRange: NumberRange)
	local minRenderDistance = renderDistanceRange.Min
	local maxRenderDistance = renderDistanceRange.Max
	if
		not (
			minRenderDistance > 0
			and minRenderDistance < math.huge
			and maxRenderDistance > 0
			and maxRenderDistance < math.huge
		)
	then
		-- The render distance is a divisor in the priority math, so zero,
		-- negatives, infinity, and NaN all corrupt state. Max gets its own
		-- gate because a NaN slips through NumberRange's ordering check.
		error("SetRenderDistanceRange expects finite render distances greater than zero")
	end

	-- The controller resets so a streak built up in the old range doesn't
	-- carry into the new one.
	self._config:setRenderDistanceRange(minRenderDistance, maxRenderDistance)
	self._renderDistanceController:reset()
end

--[[
	Sets the per-frame time allowances, in seconds, for the search, ingest,
	and update passes.
]]
function CullThrottle.SetTimeBudgets(
	self: CullThrottle,
	searchTimeBudget: number,
	ingestTimeBudget: number,
	updateTimeBudget: number
)
	if not (searchTimeBudget >= 0 and ingestTimeBudget >= 0 and updateTimeBudget >= 0) then
		-- A negative budget silently starves its pass, while zero just skips
		-- the work. The check is phrased so NaN fails into it too.
		error("SetTimeBudgets expects non-negative time budgets in seconds")
	end

	self._config.searchTimeBudget = searchTimeBudget
	self._config.ingestTimeBudget = ingestTimeBudget
	self._config.updateTimeBudget = updateTimeBudget
end

--[[
	Sets the refresh rate range in Hz. The most frequent (best) rate is the
	higher number, so it maps to the range's Max, and the least frequent (worst)
	rate maps to Min. NumberRange already guarantees Min <= Max for real
	numbers, so the best rate can never be slower than the worst. Rates must be
	finite and positive.
]]
function CullThrottle.SetRefreshRates(self: CullThrottle, refreshRates: NumberRange)
	local worstHz = refreshRates.Min
	local bestHz = refreshRates.Max
	if not (worstHz > 0 and worstHz < math.huge and bestHz > 0 and bestHz < math.huge) then
		-- The checks are phrased so NaN fails into them, and an infinite rate
		-- is gated too, since it inverts to a zero-second period and zeroes the
		-- refresh midpoint the render distance controller divides by.
		error("SetRefreshRates expects finite refresh rates in Hz greater than zero")
	end

	-- The config stores periods (seconds between refreshes), so the rates
	-- invert here at the Hz-facing boundary.
	self._config:setRefreshPeriods(1 / bestHz, 1 / worstHz)
end

--[[
	Sets how many tagged occluders may build umbrae in a single frame. The
	highest scoring occluders win each frame, so the cap trades occlusion
	coverage against umbra test cost. Zero disables occlusion culling
	entirely, cached occlusion proofs included.
]]
function CullThrottle.SetMaxOccluders(self: CullThrottle, maxOccluders: number)
	if not (maxOccluders >= 0 and maxOccluders <= 32 and maxOccluders % 1 == 0) then
		-- Each umbra claims one bit of a 32-bit mask, so the cap tops out at
		-- 32. The checks are phrased so NaN fails into them too.
		error("SetMaxOccluders expects an integer between 0 and 32")
	end

	self._config.maxOccluders = maxOccluders
end

--[[
	When enabled, visibility is only computed when something asks for it (a
	query, or a connected visibility signal) instead of every frame.
]]
function CullThrottle.SetComputeVisibilityOnlyOnDemand(self: CullThrottle, computeVisibilityOnlyOnDemand: boolean)
	self._config.computeVisibilityOnlyOnDemand = computeVisibilityOnlyOnDemand
end

--[[
	When enabled, p0 (must-refresh) objects ignore the update time budget
	entirely so the worst refresh rate is always honored.
]]
function CullThrottle.SetStrictlyEnforceWorstRefreshRate(self: CullThrottle, strictlyEnforceWorstRefreshRate: boolean)
	self._config.strictlyEnforceWorstRefreshRate = strictlyEnforceWorstRefreshRate
end

--[[
	Returns the voxel grid cell size in studs.
]]
function CullThrottle.GetVoxelSize(self: CullThrottle): number
	return self._config.voxelSize
end

--[[
	Mirrors SetRenderDistanceRange. The configured [min, max] bounds the live
	distance floats within. An equal min and max disables dynamic adjustment.
]]
function CullThrottle.GetRenderDistanceRange(self: CullThrottle): NumberRange
	local config = self._config
	return NumberRange.new(config.minRenderDistance, config.maxRenderDistance)
end

--[[
	Returns the live, effective render distance. With dynamic render distance
	enabled this is the value the controller has settled on and may differ
	from the configured range's midpoint (see GetRenderDistanceRange).
]]
function CullThrottle.GetRenderDistance(self: CullThrottle): number
	return self._config.renderDistance
end

--[[
	Mirrors SetTimeBudgets, returning the search, ingest, and update budgets,
	all in seconds.
]]
function CullThrottle.GetTimeBudgets(self: CullThrottle): (number, number, number)
	local config = self._config
	return config.searchTimeBudget, config.ingestTimeBudget, config.updateTimeBudget
end

--[[
	Mirrors SetRefreshRates, returning rates in Hz. The config stores periods,
	so we invert back to Hz here rather than leaking the internal unit. The
	worst (least frequent) rate is the range's Min.
]]
function CullThrottle.GetRefreshRates(self: CullThrottle): NumberRange
	local config = self._config
	return NumberRange.new(1 / config.worstRefreshPeriod, 1 / config.bestRefreshPeriod)
end

--[[
	Mirrors SetMaxOccluders, returning how many tagged occluders may build
	umbrae in a single frame.
]]
function CullThrottle.GetMaxOccluders(self: CullThrottle): number
	return self._config.maxOccluders
end

--[[
	Returns whether visibility is computed only on demand
	(see SetComputeVisibilityOnlyOnDemand).
]]
function CullThrottle.GetComputeVisibilityOnlyOnDemand(self: CullThrottle): boolean
	return self._config.computeVisibilityOnlyOnDemand
end

--[[
	Returns whether p0 objects ignore the update time budget
	(see SetStrictlyEnforceWorstRefreshRate).
]]
function CullThrottle.GetStrictlyEnforceWorstRefreshRate(self: CullThrottle): boolean
	return self._config.strictlyEnforceWorstRefreshRate
end

--[[
	This one is derived and read-only. Dynamic adjustment is active whenever
	the range set via SetRenderDistanceRange spans more than a single value.
]]
function CullThrottle.GetDynamicRenderDistance(self: CullThrottle): boolean
	local config = self._config
	return config.minRenderDistance ~= config.maxRenderDistance
end

--[[
	Returns whether the object is currently tracked.
]]
function CullThrottle.IsTracking(self: CullThrottle, object: Instance): boolean
	return self._lifecycle._objects[object] ~= nil
end

--[[
	Returns every tracked object as a fresh array snapshot, so callers can
	iterate/mutate it freely without touching CullThrottle's internal state.
]]
function CullThrottle.GetTrackedObjects(self: CullThrottle): { Instance }
	local lifecycle = self._lifecycle
	local objects = tableCreate(lifecycle._objectCount)
	local count = 0
	for object in lifecycle._objects do
		count += 1
		objects[count] = object
	end
	return objects
end

--[[
	Returns how many objects are currently tracked.
]]
function CullThrottle.GetTrackedObjectCount(self: CullThrottle): number
	return self._lifecycle._objectCount
end

--[[
	Returns a read-only snapshot of the latest perf metrics with public field
	names, so callers never get a reference to the internal _perfMetrics table.
	Durations and averageObjectDeltaTime are in seconds, and the skipped and
	occluded counts are the most recent frame's tallies.
]]
function CullThrottle.GetPerformanceMetrics(self: CullThrottle): {
	searchDuration: number,
	ingestDuration: number,
	skippedSearch: number,
	skippedIngest: number,
	occludedVoxelCount: number,
	averageObjectDeltaTime: number,
}
	local perfMetrics = self._perfMetrics
	return {
		searchDuration = perfMetrics._searchDuration,
		ingestDuration = perfMetrics._ingestDuration,
		skippedSearch = perfMetrics._skippedSearch[perfMetrics._skippedFramesCursor],
		skippedIngest = perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor],
		occludedVoxelCount = perfMetrics._occludedVoxelCount,
		averageObjectDeltaTime = perfMetrics._averageObjectDeltaTime,
	}
end

return CullThrottle
