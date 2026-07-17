--!strict
--!optimize 2
--!native

--[[
	This module turns the frame's visible voxels into a prioritized update
	queue. The visible voxels arrive from the search sorted closest-first,
	then the precise pass scores each object (screen size, refresh urgency,
	distance) until its time budget runs out. Whatever remains is dumped by
	the fast pass with a coarse priority derived from each voxel's search
	order.
]]

local types = require(script.Parent.types)
local BandedQueue = require(script.Parent.BandedQueue)
local Config = require(script.Parent.Config)
local VoxelGrid = require(script.Parent.VoxelGrid)
local VisibilitySearch = require(script.Parent.VisibilitySearch)
local VisibilitySignals = require(script.Parent.VisibilitySignals)
local CameraCache = require(script.Parent.Utilities.CameraCache)

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local tableClear = table.clear
local tableCreate = table.create
local tableMove = table.move

-- Priority scores below this are p0 (must refresh this frame), and
-- IterateObjectsToUpdate grants its overrun budget to exactly those bands.
local P0_THRESHOLD = 0.90
-- This is in studs. Objects closer than this to the camera are prioritized to
-- refresh nearly every frame regardless of screen size.
local NEARBY_DISTANCE_THRESHOLD = 30
-- A distance of zero would make screen size infinite and feed -inf into the
-- priority math, so distance clamps to a tiny positive minimum.
local MIN_SCREEN_SIZE_DISTANCE = 1e-4

-- The ingest loop checks its time budget once per batch of this many objects,
-- so the worst-case overrun is one batch's worth of work.
local INGEST_CLOCK_CHECK_OBJECT_INTERVAL = 16

-- This weight favors larger objects, which contribute the most visually.
local SCREEN_SIZE_PRIORITY_WEIGHT = 85
-- This weight pulls everything toward the same refresh rate, trading some
-- big-object updates for the little ones so the scene refreshes evenly.
local REFRESH_RATE_PRIORITY_WEIGHT = 13
-- This weight favors nearby objects regardless of size, since they're
-- a more likely focus when many objects have similar screen sizes.
local DISTANCE_PRIORITY_WEIGHT = 2

-- The queue relaxes exact priority order into bands (see BandedQueue), and
-- each scoring branch below computes its band at staging time. The regions
-- stack back to back in dequeue order, p0 and nearby, then fair, then
-- fast-pass, then over-refresh at the very back. The ingest scoring section
-- of docs/SYSTEM.md walks the layout in full.
local P0_BAND_COUNT = 18
local P0_BAND_SCALE = P0_BAND_COUNT / P0_THRESHOLD
local FAIR_PRIORITY_MAX = SCREEN_SIZE_PRIORITY_WEIGHT + REFRESH_RATE_PRIORITY_WEIGHT + DISTANCE_PRIORITY_WEIGHT
local FAIR_BAND_OFFSET = P0_BAND_COUNT + 1
local FAST_BAND_OFFSET = FAIR_BAND_OFFSET + FAIR_PRIORITY_MAX + 1
-- The fast tiers keep one band per voxel this deep, deeper than the precise
-- pass typically leaves unscored, and voxels beyond it share the last tier.
local FAST_VOXEL_TIER_CAP = 89
local OVER_BAND_OFFSET = FAST_BAND_OFFSET + FAST_VOXEL_TIER_CAP + 1
local OVER_BAND_COUNT = 10
local QUEUE_BAND_COUNT = OVER_BAND_OFFSET + OVER_BAND_COUNT - 1

local Ingest = {}
Ingest.__index = Ingest

-- The band layout is exported for the update iterator's overrun boundary and
-- for the tests.
Ingest.P0_BAND_COUNT = P0_BAND_COUNT
Ingest.P0_BAND_SCALE = P0_BAND_SCALE
Ingest.FAIR_BAND_OFFSET = FAIR_BAND_OFFSET
Ingest.FAST_BAND_OFFSET = FAST_BAND_OFFSET
Ingest.FAST_VOXEL_TIER_CAP = FAST_VOXEL_TIER_CAP
Ingest.OVER_BAND_OFFSET = OVER_BAND_OFFSET
Ingest.OVER_BAND_COUNT = OVER_BAND_COUNT

type IngestProto = {
	_config: Config.Config,
	_grid: VoxelGrid.VoxelGrid,
	_search: VisibilitySearch.VisibilitySearch,
	_signals: VisibilitySignals.VisibilitySignals,
	_perfMetrics: types.PerfMetrics,

	_visibleObjectsQueue: BandedQueue.BandedQueue<types.ObjectData>,
	-- The frame's staged batch holds an object record and its precomputed
	-- queue band per slot.
	_stagedObjects: { types.ObjectData },
	_stagedBands: { number },
	_stagedSize: number,
	-- This guards the queue layout to at most once per staged batch, so a
	-- second same-frame iteration doesn't replay objects the first one already
	-- updated.
	_enqueuedStagedBatch: boolean,
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
		_visibleObjectsQueue = BandedQueue.new(QUEUE_BAND_COUNT),
		_stagedObjects = {},
		_stagedBands = {},
		_stagedSize = 0,
		_enqueuedStagedBatch = false,
	}, Ingest)

	return self
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

	-- Everything the per-object loop reads is hoisted here and paid once per frame.
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
	-- Staging is all inline writes, so the per-object steady state pays no
	-- calls. Only the rare flip into view pays one, through markEnteredView.
	local stagedObjects = self._stagedObjects
	local stagedBands = self._stagedBands
	local stagedSize = self._stagedSize
	local markEnteredView = signals.markEnteredView

	local objectsSinceClockCheck = 0
	local startIngestClock = os.clock()

	for voxelIndex = 1, visibleVoxelCount do
		local voxel = voxels[visibleVoxelKeys[voxelIndex]]
		if not voxel then
			continue
		end

		local voxelObjectCount = #voxel
		for objectIndex = 1, voxelObjectCount do
			local objectData = voxel[objectIndex]
			if objectData.lastCheckClock == now then
				-- An object spanning several visible voxels only does the work
				-- on its first visit this frame.
				continue
			end
			objectData.lastCheckClock = now

			local dirToObject: Vector3 = objectData.position - cameraPos
			local distance = vectorMagnitude(dirToObject)
			objectData.distance = distance
			if not (distance <= renderDistance) then
				-- The cull is phrased so a NaN distance fails into it instead
				-- of feeding a NaN priority into the band arithmetic.
				continue
			end

			local radius = objectData.radius
			if not (radius < math.huge) then
				-- A non-finite radius would ride the screen-size arithmetic
				-- into a NaN band, so the object waits here until its geometry
				-- recovers.
				continue
			end

			-- Cull objects whose bounding sphere falls fully outside the frustum's
			-- side planes. The signed distance from the center to a side plane is
			-- |lateral| * cos(halfFov) - forward * sin(halfFov), so the sphere is
			-- outside once that exceeds the radius on either axis. Centers behind
			-- the camera are kept without testing, since skipping a cull is always
			-- safe and the case is rare.
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

			local screenSize = radius / (math.max(distance, MIN_SCREEN_SIZE_DISTANCE) * tanHalfVerticalFov)
			local elapsed = now - objectData.lastUpdateClock
			local jitteredElapsed = elapsed + objectData.jitterOffset

			local band

			if jitteredElapsed <= bestRefreshPeriod then
				-- Refreshed within the best rate, so it goes to the over-refresh
				-- bands at the very back, sliced by screen size.
				local overTier = (1 - math.min(screenSize, 1)) * OVER_BAND_COUNT // 1
				band = OVER_BAND_OFFSET + (if overTier >= OVER_BAND_COUNT then OVER_BAND_COUNT - 1 else overTier)
			elseif jitteredElapsed >= worstRefreshPeriod then
				-- Due at the worst refresh rate, so it takes a p0 slice sorted
				-- by screen size, clamped into the p0 region at both edges.
				local p0Band = (P0_THRESHOLD - screenSize) * P0_BAND_SCALE // 1 + 1
				band = if p0Band < 1 then 1 elseif p0Band > P0_BAND_COUNT then P0_BAND_COUNT else p0Band
			elseif distance < NEARBY_DISTANCE_THRESHOLD then
				-- Objects right by the camera should update basically every
				-- frame, so the distance fraction takes p0 slices and the
				-- farthest sliver takes the first fair band.
				local priority = distance / NEARBY_DISTANCE_THRESHOLD
				band = if priority < P0_THRESHOLD then priority * P0_BAND_SCALE // 1 + 1 else FAIR_BAND_OFFSET
			else
				-- The screen size clamps to 1 so a screen-filling object can't
				-- push the term negative and land below the p0 threshold,
				-- taking the overrun budget from objects that must refresh.
				local screenSizePriority = SCREEN_SIZE_PRIORITY_WEIGHT * (1 - math.min(screenSize, 1))
				local refreshPriority = REFRESH_RATE_PRIORITY_WEIGHT
					* (1 - (jitteredElapsed - bestRefreshPeriod) / refreshPeriodRange)
				local distancePriority = DISTANCE_PRIORITY_WEIGHT * (distance / renderDistance)

				local priority = screenSizePriority + refreshPriority + distancePriority
				-- One band per whole point of score, except that a score under
				-- the p0 threshold takes the matching p0 slice, which only a
				-- nearly-due object filling the screen reaches.
				band = if priority < P0_THRESHOLD
					then priority * P0_BAND_SCALE // 1 + 1
					else FAIR_BAND_OFFSET + priority // 1
			end

			stagedSize += 1
			stagedObjects[stagedSize] = objectData
			stagedBands[stagedSize] = band
			if objectData.lastVisibleClock == 0 then
				markEnteredView(signals, objectData, now)
			end
			objectData.lastVisibleClock = now
		end

		objectsSinceClockCheck += voxelObjectCount
		if objectsSinceClockCheck >= INGEST_CLOCK_CHECK_OBJECT_INTERVAL then
			objectsSinceClockCheck = 0
			if os.clock() - startIngestClock >= ingestTimeBudget then
				-- The budget is spent, so the remaining voxels fall to the fast
				-- pass, with the staged count committed first so it appends
				-- behind this pass's work.
				self._stagedSize = stagedSize
				self:fastApproxIngestRemainingVoxels(now, voxelIndex + 1)
				self._perfMetrics._ingestDuration = os.clock() - startIngestClock
				debug.profileend()
				return
			end
		end
	end

	self._stagedSize = stagedSize
	self._perfMetrics._ingestDuration = os.clock() - startIngestClock

	debug.profileend()
end

--[[
	This is the cheap fallback ingest. It dumps every object in the remaining
	visible voxels into the staged batch with a coarse band derived from each
	voxel's search order, tallying the skipped-ingest metric. It skips the
	precise scoring but still refreshes each object's distance (the iterator
	yields the stored value, and nothing else updates it for a static object)
	and culls past the render distance.
]]
function Ingest.fastApproxIngestRemainingVoxels(self: Ingest, now: number, startIndex: number)
	local search = self._search
	local signals = self._signals
	local voxels = self._grid._voxels
	local visibleVoxelKeys = search._visibleVoxelKeys
	local visibleVoxelCount = search._visibleVoxelCount
	local stagedObjects = self._stagedObjects
	local stagedBands = self._stagedBands
	local stagedSize = self._stagedSize
	local markEnteredView = signals.markEnteredView
	local cameraPos = CameraCache.Position
	local renderDistance = self._config.renderDistance

	for voxelIndex = startIndex, visibleVoxelCount do
		local voxelKey = visibleVoxelKeys[voxelIndex]
		local voxel = voxels[voxelKey]
		if not voxel then
			continue
		end

		local approxBand = FAST_BAND_OFFSET
			+ (if voxelIndex < FAST_VOXEL_TIER_CAP then voxelIndex else FAST_VOXEL_TIER_CAP)

		local voxelObjectCount = #voxel
		for objectIndex = 1, voxelObjectCount do
			local objectData = voxel[objectIndex]
			if objectData.lastCheckClock == now then
				-- Already ingested this frame, likely an object spanning multiple voxels.
				continue
			end
			objectData.lastCheckClock = now

			local distance = vectorMagnitude(objectData.position - cameraPos)
			objectData.distance = distance
			if not (distance <= renderDistance) then
				-- Like the precise pass, this is phrased so a NaN distance
				-- fails into the cull.
				continue
			end

			stagedSize += 1
			stagedObjects[stagedSize] = objectData
			stagedBands[stagedSize] = approxBand
			if objectData.lastVisibleClock == 0 then
				markEnteredView(signals, objectData, now)
			end
			objectData.lastVisibleClock = now
		end
	end

	self._stagedSize = stagedSize

	local perfMetrics = self._perfMetrics
	-- The frame loop zeroed this frame's ring slot before ingest ran, so frames
	-- where this fallback never runs stay recorded as zero.
	perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor] = 1 + visibleVoxelCount - startIndex
end

--[[
	Lays the staged batch out into the visible-objects queue in band order, at
	most once per staged batch (clearing the batch re-arms the guard). The
	facade calls this on the first iteration of a frame, so frames where
	nobody iterates never pay for the layout, and a repeat iteration the same
	frame keeps draining the existing layout instead of restarting it.
]]
function Ingest.enqueueStagedObjects(self: Ingest)
	if self._enqueuedStagedBatch then
		return
	end
	self._enqueuedStagedBatch = true

	debug.profilebegin("enqueueStagedObjects")
	self._visibleObjectsQueue:enqueueBatch(self._stagedObjects, self._stagedBands, self._stagedSize)
	debug.profileend()
end

--[[
	Empties the staged batch without touching the queue proper, re-arming the
	once-per-batch layout guard.
]]
function Ingest.clearStagedObjects(self: Ingest)
	self._stagedSize = 0
	self._enqueuedStagedBatch = false
	tableClear(self._stagedObjects)
	tableClear(self._stagedBands)
end

--[[
	Resets the frame's ingest output, both the staged batch and the queue
	layout built from it, for the start of a fresh visibility pass.
]]
function Ingest.clearFrame(self: Ingest)
	self:clearStagedObjects()
	self._visibleObjectsQueue:clear()
end

--[[
	Rebuilds the cleared-without-shrinking staging arrays (and the queue's
	layout) at current occupancy, so a one-off burst doesn't leave permanently
	oversized arrays. Contents are preserved, since the staged batch backs
	GetVisibleObjects until the next frame restages it.
]]
function Ingest.resizeBuffers(self: Ingest)
	local stagedSize = self._stagedSize

	local stagedObjects = tableCreate(stagedSize)
	tableMove(self._stagedObjects, 1, stagedSize, 1, stagedObjects)
	self._stagedObjects = stagedObjects

	local stagedBands = tableCreate(stagedSize)
	tableMove(self._stagedBands, 1, stagedSize, 1, stagedBands)
	self._stagedBands = stagedBands

	self._visibleObjectsQueue:resize()
end

--[[
	Clears the staged batch and the visible-objects queue so everything they
	referenced can be garbage collected.
]]
function Ingest.destroy(self: Ingest)
	self:clearFrame()
end

return Ingest
