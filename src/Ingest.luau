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
local BandedQueue = require(script.Parent.BandedQueue)
local Config = require(script.Parent.Config)
local VoxelGrid = require(script.Parent.VoxelGrid)
local VisibilitySearch = require(script.Parent.VisibilitySearch)
local VisibilitySignals = require(script.Parent.VisibilitySignals)
local CameraCache = require(script.Parent.Utilities.CameraCache)

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local vectorAbs = (vector.abs :: any) :: (Vector3 | vector) -> Vector3
local tableClear = table.clear

-- Dotting a componentwise absolute value against this sums its three lanes,
-- which is how the voxel sort gets a manhattan distance in two vector ops.
local VECTOR_ONE = Vector3.one

-- Priority scores below this are p0 (must refresh this frame). The p0 region's
-- bands slice [0, P0_THRESHOLD), and IterateObjectsToUpdate grants its overrun
-- budget to exactly those bands.
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

-- The visible-objects queue relaxes exact priority order into bands (see
-- BandedQueue), and each scoring branch below computes its band directly at
-- staging time, since the branch already knows which region its score landed
-- in. The regions stack back to back in dequeue order. The p0 and nearby
-- region under P0_THRESHOLD gets P0_BAND_COUNT equal slices, so bigger p0
-- objects still go first at a coarse grain. The fair region gets one band per
-- whole point of score, which is about one percent of the screen-size weight.
-- The fast-pass region gets one band per voxel in search order, so nearer
-- voxels always dequeue ahead of farther ones, saturating at the tier cap
-- where the deepest voxels share one band. The over-refresh region at the
-- very back gets a few coarse screen-size slices, since those objects only
-- ever drain on leftover budget.
local P0_BAND_COUNT = 18
local P0_BAND_SCALE = P0_BAND_COUNT / P0_THRESHOLD
local FAIR_PRIORITY_MAX = SCREEN_SIZE_PRIORITY_WEIGHT + REFRESH_RATE_PRIORITY_WEIGHT + DISTANCE_PRIORITY_WEIGHT
local FAIR_BAND_OFFSET = P0_BAND_COUNT + 1
local FAST_BAND_OFFSET = FAIR_BAND_OFFSET + FAIR_PRIORITY_MAX + 1
-- The fast tiers keep one band per voxel this deep, which is deeper than the
-- precise pass typically leaves unscored, and voxels beyond it share the last
-- tier. The cap bounds the fast region's share of the band table.
local FAST_VOXEL_TIER_CAP = 89
local OVER_BAND_OFFSET = FAST_BAND_OFFSET + FAST_VOXEL_TIER_CAP + 1
local OVER_BAND_COUNT = 10
local QUEUE_BAND_COUNT = OVER_BAND_OFFSET + OVER_BAND_COUNT - 1

local Ingest = {}
Ingest.__index = Ingest

-- The update iterator keys its overrun budget off the p0 region boundary, and
-- the tests pin scores to regions through the other landmarks, so the band
-- layout is exported.
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
	-- This is the frame's staged batch, appended inline by both ingest passes
	-- (an object record and its precomputed queue band per slot) and handed to
	-- the queue whole when the facade lays the drain out. The facade also
	-- answers GetVisibleObjects straight off the objects array.
	_stagedObjects: { types.ObjectData },
	_stagedBands: { number },
	_stagedSize: number,
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
		-- The visible-objects queue is banded (see BandedQueue and the banding
		-- constants above), which fits how it's used. The staged batch is
		-- built once per frame with lastCheckClock deduping, nothing removes
		-- from it mid-frame, and the drain only pops front to back. It holds
		-- ObjectData records so the update iterator reads everything it
		-- yields straight off the record instead of paying an objects-map
		-- lookup per object.
		_visibleObjectsQueue = BandedQueue.new(QUEUE_BAND_COUNT),
		_stagedObjects = {},
		_stagedBands = {},
		_stagedSize = 0,
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
		local distance = vectorDot(vectorAbs(pendingVoxelKeys[i] - cameraVoxelKey), VECTOR_ONE)
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
	-- Staging is a pair of inline array writes, and the visibility stamp is an
	-- inline field write, so the per-object steady state pays no calls at all.
	-- Only the rare flip into view pays one, through markEnteredView.
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
				-- into the queue where it would corrupt the band arithmetic.
				continue
			end

			local radius = objectData.radius

			-- Cull objects whose bounding sphere falls fully outside the view
			-- frustum's side planes. The signed distance from the object's center to
			-- a side plane is |lateral| * cos(halfFov) - forward * sin(halfFov), so
			-- the sphere is outside once that exceeds the radius on either axis.
			--
			-- This only applies to objects whose center is in front of the camera.
			-- Centers behind it are kept without testing. Skipping a cull is always
			-- safe, and the case is rare anyway, since an object back there can only
			-- reach ingest through a voxel the search already called visible.
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
				-- This was refreshed within the best rate, so push it into the
				-- over-refresh bands at the very back, sliced by screen size so
				-- bigger objects still lead on leftover budget.
				local overTier = (1 - math.min(screenSize, 1)) * OVER_BAND_COUNT // 1
				band = OVER_BAND_OFFSET + (if overTier >= OVER_BAND_COUNT then OVER_BAND_COUNT - 1 else overTier)
			elseif jitteredElapsed >= worstRefreshPeriod then
				-- To maintain the worst refresh rate, make this p0 priority.
				-- The p0 slices sort by screen size, and a score pushed far
				-- negative by a huge object clamps into the front band.
				local p0Band = (P0_THRESHOLD - screenSize) * P0_BAND_SCALE // 1 + 1
				band = if p0Band < 1 then 1 else p0Band
			elseif distance < NEARBY_DISTANCE_THRESHOLD then
				-- Objects right by the camera should update basically every
				-- frame. The score is the distance fraction, so most of these
				-- take p0 slices and the farthest sliver takes the first fair
				-- band.
				local priority = distance / NEARBY_DISTANCE_THRESHOLD
				band = if priority < P0_THRESHOLD then priority * P0_BAND_SCALE // 1 + 1 else FAIR_BAND_OFFSET
			else
				-- Figure out the fair object priority. The screen size clamps to 1
				-- so a screen-filling object can't push the term negative and land
				-- below the p0 threshold, taking the overrun budget from objects
				-- that must refresh this frame.
				local screenSizePriority = SCREEN_SIZE_PRIORITY_WEIGHT * (1 - math.min(screenSize, 1))
				local refreshPriority = REFRESH_RATE_PRIORITY_WEIGHT
					* (1 - (jitteredElapsed - bestRefreshPeriod) / refreshPeriodRange)
				local distancePriority = DISTANCE_PRIORITY_WEIGHT * (distance / renderDistance)

				local priority = screenSizePriority + refreshPriority + distancePriority
				-- One band per whole point of score, except that a score
				-- dipping under the p0 threshold takes the matching p0 slice
				-- (and the p0 budget treatment that comes with it), which only
				-- a nearly-due object filling the screen reaches.
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
				-- We've run out of time! Dump the remaining voxels through the
				-- fast approximate pass, committing the staged count first so
				-- it appends behind this pass's work.
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
				-- This object was already ingested this frame (here or in the precise
				-- pass), so we skip it to avoid duplicating an object that spans voxels.
				continue
			end
			objectData.lastCheckClock = now

			local distance = vectorMagnitude(objectData.position - cameraPos)
			objectData.distance = distance
			if not (distance <= renderDistance) then
				-- Like the precise pass, this is phrased so a NaN distance
				-- fails into the cull rather than staging a doomed object.
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
	-- The frame loop advanced the ring cursor and zeroed this frame's slot before
	-- ingest ran, so frames where this fallback never runs stay recorded as zero.
	perfMetrics._skippedIngest[perfMetrics._skippedFramesCursor] = 1 + visibleVoxelCount - startIndex
end

--[[
	Lays the staged batch out into the visible-objects queue in band order. The
	facade calls this at most once per processed frame, on the first iteration,
	so frames where nobody iterates never pay for the layout.
]]
function Ingest.enqueueStagedObjects(self: Ingest)
	self._visibleObjectsQueue:enqueueBatch(self._stagedObjects, self._stagedBands, self._stagedSize)
end

--[[
	Empties the staged batch without touching the queue proper.
]]
function Ingest.clearStagedObjects(self: Ingest)
	self._stagedSize = 0
	tableClear(self._stagedObjects)
	tableClear(self._stagedBands)
end

--[[
	Clears the staged batch, the visible-objects queue, and the sort's scratch
	counts so everything they referenced can be garbage collected.
]]
function Ingest.destroy(self: Ingest)
	tableClear(self._voxelDistanceCounts)
	self:clearStagedObjects()
	self._visibleObjectsQueue:clear()
end

return Ingest
