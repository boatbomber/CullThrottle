--!strict
--!optimize 2
--!native

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

if _G.__DEV__ then
	print("Allowing CullThrottle on server during dev for unit test purposes")
else
	if RunService:IsServer() and not RunService:IsEdit() then
		error("CullThrottle is a client side effect and cannot be used on the server")
	end
end

local types = require(script.types)
local PriorityQueue = require(script.PriorityQueue)
local Config = require(script.Config)
local GoodSignal = require(script.Utilities.GoodSignal)
local ObjectDimensions = require(script.Utilities.ObjectDimensions)
local CameraCache = require(script.Utilities.CameraCache)
local Gizmo = if _G.__DEV__ then require(script.Utilities.Gizmo) else nil :: any

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local tableInsert = table.insert
local tableFind = table.find
local tableMove = table.move
local tableCreate = table.create
local tableClear = table.clear
local tableClone = table.clone

local EPSILON = 1e-4
local P0_THRESHOLD = 0.90
local RESIZE_TABLES_RATE = 5
local SKIPPED_FRAMES_LOOKBACK = 4
local LAST_VISIBILITY_GRACE_PERIOD = 0.2
local NEARBY_DISTANCE_THRESHOLD = 30

-- The visibility search collects occupied voxel keys once per frame. To avoid
-- touching empty cells, occupied voxel keys are also bucketed into a coarse grid
-- (each bucket spans COARSE_VOXEL_SIZE voxels per axis) so the collection iterates
-- only the occupied keys it overlaps instead of every cell within the bounds.
local COARSE_VOXEL_SIZE = 4

-- Axis selectors for the in-place voxel-key partition used to split search volumes.
local AXIS_X = 1
local AXIS_Y = 2
local AXIS_Z = 3

-- Per-frame voxel upkeep budgets, spent before the visibility search. Each is
-- 0.05 ms, so the combined voxel maintenance is capped at ~0.1 ms per frame.
local PHYSICS_POLL_TIME_BUDGET = 5e-5
local VOXEL_MAINTENANCE_TIME_BUDGET = 5e-5

-- Dynamic render distance is an adaptive controller to avoid bouncing up and down.
local DYNAMIC_RENDER_DISTANCE_SEARCH_WEIGHT = 1.3
local DYNAMIC_RENDER_DISTANCE_INGEST_WEIGHT = 1.0
local DYNAMIC_RENDER_DISTANCE_DELTA_WEIGHT = 0.8
-- Grow only when the worst weighted load is below this fraction of budget.
local DYNAMIC_RENDER_DISTANCE_GROW_HEADROOM = 0.6
-- Step size as a fraction of the render distance range midpoint, adapted each frame.
local DYNAMIC_RENDER_DISTANCE_MIN_STEP = 0.0002
local DYNAMIC_RENDER_DISTANCE_MAX_STEP = 0.025
-- Shrink the step when we reverse/settle, grow it when the scene really changed.
local DYNAMIC_RENDER_DISTANCE_STEP_DAMPING = 0.35
local DYNAMIC_RENDER_DISTANCE_STEP_GAIN = 1.2

-- This weight gives more update priority to larger objects,
-- focusing on the objects that contribute the most visually
local SCREEN_SIZE_PRIORITY_WEIGHT = 85
-- This weight tries to make everything the same refresh rate,
-- sacrificing some updates to big objects for the little ones
-- for a smoother overall vibe
local REFRESH_RATE_PRIORITY_WEIGHT = 13
-- This weight gives more priority to nearby objects regardless of size
-- which can help prioritize objects that are likely the real focus
-- in cases where there are many objects of similar screen size
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

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type CullThrottleProto = {
	ObjectEnteredView: GoodSignal.Signal,
	ObjectExitedView: GoodSignal.Signal,
	ObjectAdded: GoodSignal.Signal,
	ObjectRemoved: GoodSignal.Signal,

	_config: Config.Config,
	_voxels: { [types.VoxelKey]: types.Voxel },
	_coarseVoxels: { [types.CoarseVoxelKey]: { types.VoxelKey } },
	_searchVoxelKeys: { types.VoxelKey },
	_objects: { [Instance]: types.ObjectData },
	_objectCount: number,
	_physicsObjects: { Instance },
	_updateObjectVoxelsQueue: PriorityQueue.PriorityQueue,
	_visibleObjectsQueue: PriorityQueue.PriorityQueue,
	_visibleVoxelKeys: { types.VoxelKey },
	_visibleVoxelCount: number,
	_pendingVoxelKeys: { types.VoxelKey },
	_pendingVoxelDistances: { number },
	_voxelDistanceCounts: { number },
	_objectVisibilityTimestamps: { [Instance]: number },
	_physicsObjectIterIndex: number,
	_lastTableResize: number,
	_lastVoxelVisibility: { [types.VoxelKey]: number },
	_tagConnections: { [string]: { RBXScriptConnection } },
	_renderConnection: RBXScriptConnection,
	_processedVisibilityThisFrame: boolean,
	_volumesToCheck: { number },
	_volumesToCheckSize: number,
	_volumeRotationCounter: number,

	-- Visibility signals are deferred so a handler can't mutate while we're still iterating
	_pendingEnteredView: { Instance },
	_pendingEnteredViewSize: number,
	_pendingExitedView: { Instance },
	_pendingExitedViewSize: number,

	_perfMetrics: {
		_skippedSearch: { number },
		_skippedIngest: { number },
		_searchDuration: number,
		_ingestDuration: number,
		_averageObjectDeltaTime: number,
		_getAverage: ({ number }) -> number,
	},
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

if _G.__DEV__ then
	function CullThrottle._drawBox(
		self: CullThrottle,
		color: Color3,
		transparency: number,
		x0: number,
		y0: number,
		z0: number,
		x1: number,
		y1: number,
		z1: number
	)
		if not _G.__VISUALIZE__ then
			return
		end
		local voxelSize = self._config.voxelSize
		local x0World, y0World, z0World = x0 * voxelSize, y0 * voxelSize, z0 * voxelSize
		local x1World, y1World, z1World = x1 * voxelSize, y1 * voxelSize, z1 * voxelSize

		local cf = CFrame.new((x0World + x1World) / 2, (y0World + y1World) / 2, (z0World + z1World) / 2)
		local size = Vector3.new(math.abs(x0World - x1World), math.abs(y0World - y1World), math.abs(z0World - z1World))
			- (Vector3.one * 2)

		Gizmo.setColor3(color)
		Gizmo.setTransparency(transparency)
		Gizmo.drawWireBox(cf, size)
	end
end

function CullThrottle._resizeTables(self: CullThrottle)
	-- We've got a couple arrays that we clear without shrinking their size
	-- so we occasionally resize them to avoid wasting space
	local visibleVoxelCount = self._visibleVoxelCount

	local visibleVoxelKeys = tableCreate(visibleVoxelCount)
	tableMove(self._visibleVoxelKeys, 1, visibleVoxelCount, 1, visibleVoxelKeys)
	self._visibleVoxelKeys = visibleVoxelKeys

	local pendingVoxelKeys = tableCreate(visibleVoxelCount)
	tableMove(self._pendingVoxelKeys, 1, visibleVoxelCount, 1, pendingVoxelKeys)
	self._pendingVoxelKeys = pendingVoxelKeys

	self._pendingVoxelDistances = tableCreate(visibleVoxelCount)

	local volumesSize = self._volumesToCheckSize
	local volumesToCheck = tableCreate(volumesSize)
	tableMove(self._volumesToCheck, 1, volumesSize, 1, volumesToCheck)
	self._volumesToCheck = volumesToCheck

	self._pendingEnteredView = tableCreate(self._pendingEnteredViewSize)
	self._pendingExitedView = tableCreate(self._pendingExitedViewSize)
end

function CullThrottle._addVoxelKeyToVisible(self: CullThrottle, voxelKey: types.VoxelKey)
	-- Accumulate visible voxels unsorted (an O(1) append)
	-- _sortVisibleVoxelKeys orders the whole batch closest-first once the search finishes.
	--
	-- We don't dedupe: the search volumes partition space, so a voxel is only ever
	-- added once per frame, and any object that spans several voxels is deduped
	-- downstream by objectData.lastCheckClock during ingest.
	local count = self._visibleVoxelCount + 1
	self._visibleVoxelCount = count
	self._pendingVoxelKeys[count] = voxelKey
end

function CullThrottle._sortVisibleVoxelKeys(self: CullThrottle)
	-- Order this frame's visible voxels closest-first by manhattan distance to the
	-- camera (in voxel space). The ingest passes rely on that order: nearer voxels
	-- get precise ingestion, and once the budget runs out _fastApproxIngestRemainingVoxels
	-- uses the index as a coarse priority. The ordering is only a soft heuristic
	-- (manhattan distance is itself an approximation).
	--
	-- Distances are small non-negative integers, so a counting sort orders them in
	-- O(n + maxDistance) with no element shuffling, and cameraVoxelKey is computed
	-- just once for the whole batch.
	local count = self._visibleVoxelCount
	local pendingVoxelKeys = self._pendingVoxelKeys
	local visibleVoxelKeys = self._visibleVoxelKeys

	if count == 0 then
		return
	elseif count == 1 then
		visibleVoxelKeys[1] = pendingVoxelKeys[1]
		return
	end

	local cameraVoxelKey = CameraCache.Position // self._config.voxelSize
	local distances = self._pendingVoxelDistances
	local counts = self._voxelDistanceCounts

	-- Manhattan distance for every pending voxel, plus the max (the bucket range).
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

-- Clip a z-row's [lo, hi] span (measured in voxel steps from the row's first
-- voxel) to where the voxel center stays within `reach` of the box along one box
-- axis. The center's coordinate down the row is `coord + t * step`, so the test
-- |coord + t * step| <= reach is an interval of t that we intersect into [lo, hi].
-- When the axis doesn't vary down the row (`varies` is false because the box axis
-- is perpendicular to world Z, leaving step ~ 0) the coordinate is constant: it
-- either leaves the whole row eligible or, if already out of reach, empties it.
local function clampRowToAxis(
	lo: number,
	hi: number,
	coord: number,
	reach: number,
	invStep: number,
	varies: boolean
): (number, number)
	if varies then
		local t1 = (-reach - coord) * invStep
		local t2 = (reach - coord) * invStep
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		return math.max(lo, t1), math.min(hi, t2)
	elseif coord > reach or coord < -reach then
		-- Out of reach for the entire row, so return an empty span (lo > hi).
		return 1, 0
	end

	return lo, hi
end

function CullThrottle._updateDesiredVoxelKeys(
	self: CullThrottle,
	object: Instance,
	objectData: types.ObjectData
): { [types.VoxelKey]: boolean }
	debug.profilebegin("_updateDesiredVoxelKeys")
	local voxelSize = self._config.voxelSize
	local multiVoxelRadiusThreshold = self._config.multiVoxelRadiusThreshold

	-- Update desiredVoxelKeys table in place rather than reallocating
	local desiredVoxelKeys = objectData.desiredVoxelKeys
	tableClear(desiredVoxelKeys)

	-- We'll get the voxelKeys for the center and the 8 corners of the object
	local cframe, halfBoundingBox = objectData.cframe, objectData.halfBoundingBox
	local position = cframe.Position

	local desiredVoxelKey = position // voxelSize
	desiredVoxelKeys[desiredVoxelKey] = true

	if objectData.radius > multiVoxelRadiusThreshold then
		-- Object is large enough that it may span more than its center voxel.
		--
		-- The bounding box is oriented, so we can't just fill its world-space
		-- AABB: for a rotated object that AABB bulges past the box and its corner
		-- voxels would be empty. Instead the AABB only bounds which voxels are
		-- worth checking, and we keep a voxel only if it truly overlaps the box.
		--
		-- Overlap is a separating-axis test against the box's own 3 face axes.
		-- (The 3 world axes are already covered by the AABB candidate range, so
		-- no candidate can be separated along them.) We skip the 9 edge-edge
		-- cross-product axes; omitting them can only ever over-include, never
		-- wrongly cull, and leaves at most a thin sliver of corner voxels.
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cframe:GetComponents()
		local hx, hy, hz = halfBoundingBox.X, halfBoundingBox.Y, halfBoundingBox.Z
		local halfVoxel = voxelSize / 2

		-- The box axes in world space are the columns of the rotation matrix:
		-- axisX = (r00, r10, r20), axisY = (r01, r11, r21), axisZ = (r02, r12, r22).
		-- A voxel (an axis-aligned cube) projected onto a box axis reaches
		-- halfVoxel * (|axis.X| + |axis.Y| + |axis.Z|); add the box's own extent
		-- to get the separation threshold along that axis.
		local reachX = hx + halfVoxel * (math.abs(r00) + math.abs(r10) + math.abs(r20))
		local reachY = hy + halfVoxel * (math.abs(r01) + math.abs(r11) + math.abs(r21))
		local reachZ = hz + halfVoxel * (math.abs(r02) + math.abs(r12) + math.abs(r22))

		-- World-space AABB of the oriented box bounds the candidate voxels.
		local worldHalf = Vector3.new(
			math.abs(r00) * hx + math.abs(r01) * hy + math.abs(r02) * hz,
			math.abs(r10) * hx + math.abs(r11) * hy + math.abs(r12) * hz,
			math.abs(r20) * hx + math.abs(r21) * hy + math.abs(r22) * hz
		)
		local minVoxelKey = (position - worldHalf) // voxelSize
		local maxVoxelKey = (position + worldHalf) // voxelSize

		-- Within one z-row (fixed x and y) the voxels that pass form a single
		-- contiguous run, because the passing region (the box, inflated by half a
		-- voxel on each axis) is convex. Each box-local coordinate is linear in the
		-- row index, so every reach test reduces to an interval of z; the run we
		-- fill is the integers common to all three intervals.
		--
		-- As the inner loop steps one voxel along world Z, each box-local coordinate
		-- moves by a fixed amount: the world-Z component of that box axis times the
		-- voxel size. Precompute those per-step increments so a row reduces to
		-- lx + t * lxStep (and likewise ly, lz), where t counts steps from the row's
		-- first voxel.
		local lxStep, lyStep, lzStep = voxelSize * r20, voxelSize * r21, voxelSize * r22
		local firstRowDz = (minVoxelKey.Z + 0.5) * voxelSize - position.Z
		local rowLen = maxVoxelKey.Z - minVoxelKey.Z

		-- A box axis perpendicular to world Z has a ~zero step, so its coordinate is
		-- constant down the row. Flag those (we hold them constant rather than divide
		-- by ~zero) and precompute reciprocals of the steps that do vary.
		local stepEpsilon = 1e-9
		local lxVaries = math.abs(lxStep) > stepEpsilon
		local lyVaries = math.abs(lyStep) > stepEpsilon
		local lzVaries = math.abs(lzStep) > stepEpsilon
		local invLxStep = if lxVaries then 1 / lxStep else 0
		local invLyStep = if lyVaries then 1 / lyStep else 0
		local invLzStep = if lzVaries then 1 / lzStep else 0

		-- Round the surviving span outward by a hair so a center sitting exactly on
		-- the boundary is kept rather than lost to float error.
		local boundaryBias = 1e-6

		for x = minVoxelKey.X, maxVoxelKey.X do
			local dx = (x + 0.5) * voxelSize - position.X
			local dxR00, dxR01, dxR02 = dx * r00, dx * r01, dx * r02

			for y = minVoxelKey.Y, maxVoxelKey.Y do
				local dy = (y + 0.5) * voxelSize - position.Y

				-- Box-local coordinates of the row's first voxel center (z = minVoxelKey.Z).
				local lx = dxR00 + dy * r10 + firstRowDz * r20
				local ly = dxR01 + dy * r11 + firstRowDz * r21
				local lz = dxR02 + dy * r12 + firstRowDz * r22

				-- Start from the whole row, then clip it to each box axis's reach.
				-- What survives is the run of voxels this row actually occupies.
				local lo, hi = 0, rowLen
				lo, hi = clampRowToAxis(lo, hi, lx, reachX, invLxStep, lxVaries)
				lo, hi = clampRowToAxis(lo, hi, ly, reachY, invLyStep, lyVaries)
				lo, hi = clampRowToAxis(lo, hi, lz, reachZ, invLzStep, lzVaries)

				-- Round the surviving [lo, hi] span to the integer voxels it covers.
				local firstZ = minVoxelKey.Z + math.ceil(lo - boundaryBias)
				local lastZ = minVoxelKey.Z + math.floor(hi + boundaryBias)
				for z = firstZ, lastZ do
					desiredVoxelKeys[Vector3.new(x, y, z)] = true
				end
			end
		end
	end

	for voxelKey in objectData.voxelKeys do
		if desiredVoxelKeys[voxelKey] then
			-- Already in this desired voxel
			desiredVoxelKeys[voxelKey] = nil
		else
			-- No longer want to be in this voxel
			desiredVoxelKeys[voxelKey] = false
		end
	end

	if next(desiredVoxelKeys) and not self._updateObjectVoxelsQueue:contains(object) then
		-- Use a cheap manhattan distance check for priority
		local difference = position - CameraCache.Position
		local priority = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)

		self._updateObjectVoxelsQueue:addToIncomingBatch(object, priority)
	end

	debug.profileend()
	return desiredVoxelKeys
end

function CullThrottle._insertToVoxel(self: CullThrottle, voxelKey: types.VoxelKey, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		-- New voxel, init the list with this object inside
		self._voxels[voxelKey] = { object }

		-- This voxel just became occupied, so add it to its coarse bucket
		local coarseKey = Vector3.new(
			voxelKey.X // COARSE_VOXEL_SIZE,
			voxelKey.Y // COARSE_VOXEL_SIZE,
			voxelKey.Z // COARSE_VOXEL_SIZE
		)
		local bucket = self._coarseVoxels[coarseKey]
		if bucket then
			tableInsert(bucket, voxelKey)
		else
			self._coarseVoxels[coarseKey] = { voxelKey }
		end
	else
		-- Existing voxel, add this object to its list
		tableInsert(voxel, object)
	end
end

function CullThrottle._removeFromVoxel(self: CullThrottle, voxelKey: types.VoxelKey, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		return
	end

	local objectIndex = tableFind(voxel, object)
	if not objectIndex then
		return
	end

	local n = #voxel
	if n == 1 then
		-- Lets just cleanup this now empty voxel instead
		self._voxels[voxelKey] = nil
		self._lastVoxelVisibility[voxelKey] = nil

		-- This voxel is no longer occupied, so remove it from its coarse bucket
		local coarseKey = Vector3.new(
			voxelKey.X // COARSE_VOXEL_SIZE,
			voxelKey.Y // COARSE_VOXEL_SIZE,
			voxelKey.Z // COARSE_VOXEL_SIZE
		)
		local bucket = self._coarseVoxels[coarseKey]
		if bucket then
			local bucketIndex = tableFind(bucket, voxelKey)
			if bucketIndex then
				local bucketN = #bucket
				if bucketN == 1 then
					-- Last voxel in this bucket, so drop the bucket entirely
					self._coarseVoxels[coarseKey] = nil
				else
					-- Swap with the last key to avoid shifting the array
					bucket[bucketIndex] = bucket[bucketN]
					bucket[bucketN] = nil
				end
			end
		end
	elseif n == objectIndex then
		-- This object is at the end, so we can remove it without needing
		-- to shift anything or fill gaps
		voxel[objectIndex] = nil
	else
		-- To avoid shifting the whole array, we take the
		-- last object and move it to overwrite this one
		-- since order doesn't matter in this list
		local lastObject = voxel[n]
		voxel[n] = nil
		voxel[objectIndex] = lastObject
	end
end

function CullThrottle._updateObjectVoxels(self: CullThrottle, timeBudget: number, now: number)
	debug.profilebegin("updateObjectVoxels")

	self._updateObjectVoxelsQueue:enqueueIncomingBatch()
	self._updateObjectVoxelsQueue:clearIncomingBatch()

	while (not self._updateObjectVoxelsQueue:isEmpty()) and (os.clock() - now < timeBudget) do
		local object = self._updateObjectVoxelsQueue:dequeue()
		local objectData = self._objects[object]
		if (not objectData) or not next(objectData.desiredVoxelKeys) then
			continue
		end

		for voxelKey, desired in objectData.desiredVoxelKeys do
			if desired then
				self:_insertToVoxel(voxelKey, object)
				objectData.voxelKeys[voxelKey] = true
				objectData.desiredVoxelKeys[voxelKey] = nil
			else
				self:_removeFromVoxel(voxelKey, object)
				objectData.voxelKeys[voxelKey] = nil
				objectData.desiredVoxelKeys[voxelKey] = nil
			end
		end
	end

	debug.profileend()
end

function CullThrottle._pollPhysicsObjects(self: CullThrottle, timeBudget: number, now: number)
	debug.profilebegin("pollPhysicsObjects")
	local numPhysicsObjects = #self._physicsObjects
	if numPhysicsObjects == 0 then
		debug.profileend()
		return
	end

	local startIndex = math.clamp(self._physicsObjectIterIndex, 1, numPhysicsObjects)

	local cameraPos = CameraCache.Position
	while os.clock() - now < timeBudget do
		local object = self._physicsObjects[self._physicsObjectIterIndex]
		self._physicsObjectIterIndex = self._physicsObjectIterIndex % #self._physicsObjects + 1

		if object then
			local objectData = self._objects[object]
			if objectData then
				-- Update the object's cframe
				local cframe = ObjectDimensions.getObjectCFrame(objectData)
				if cframe then
					-- The oriented-box voxel fill is the expensive part of a poll,
					-- so only redo it when the object actually moved.
					-- Distance is refreshed every poll since the camera
					-- may have moved even when the object did not.
					local moved = cframe ~= objectData.cframe
					objectData.cframe = cframe
					objectData.distance = vectorMagnitude(cframe.Position - cameraPos)
					if moved then
						self:_updateDesiredVoxelKeys(object, objectData)
					end
				end
			end
		end

		if startIndex == self._physicsObjectIterIndex then
			-- We've looped through the entire list, no need to continue
			break
		end
	end
	debug.profileend()
end

function CullThrottle._isBoxInFrustum(
	self: CullThrottle,
	checkForCompletelyInside: boolean,
	frustumPlanes: { Vector3 }, -- {pos, normal, pos, normal, ...}
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (boolean, boolean) -- Returns (intersects, completelyInside)
	debug.profilebegin("isBoxInFrustum")
	local voxelSize = self._config.voxelSize
	-- Ensure x0 <= x1, y0 <= y1, z0 <= z1
	local x0W, x1W = x0 * voxelSize, x1 * voxelSize
	local y0W, y1W = y0 * voxelSize, y1 * voxelSize
	local z0W, z1W = z0 * voxelSize, z1 * voxelSize

	local minX, maxX = math.min(x0W, x1W), math.max(x0W, x1W)
	local minY, maxY = math.min(y0W, y1W), math.max(y0W, y1W)
	local minZ, maxZ = math.min(z0W, z1W), math.max(z0W, z1W)

	-- Define the box center and half-extents
	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	local extents = Vector3.new((maxX - minX) / 2, (maxY - minY) / 2, (maxZ - minZ) / 2)

	-- We test the radius of the sphere that circumscribes the box
	-- If the sphere is fully inside/outside, we can skip the more exact check
	local sphereRadius = vectorMagnitude(extents)

	local completelyInside = true

	-- Check each frustum plane
	for i = 1, #frustumPlanes, 2 do
		local planePos, planeNormal = frustumPlanes[i], frustumPlanes[i + 1]

		-- Compute the distance from box center to the plane
		local dist = vectorDot(center - planePos, planeNormal)

		if dist > sphereRadius + EPSILON then
			-- The circumscribing sphere is fully outside this plane, so the box is too
			debug.profileend()
			return false, false
		elseif dist > -sphereRadius then
			-- The box straddles this plane, so fall back to the exact projection
			-- interval radius of the box onto the plane normal
			local radius = math.abs(extents.X * planeNormal.X)
				+ math.abs(extents.Y * planeNormal.Y)
				+ math.abs(extents.Z * planeNormal.Z)

			-- If the distance is greater than the radius, the box is outside the frustum
			if dist > radius + EPSILON then
				debug.profileend()
				return false, false
			end

			-- If the distance plus the radius is positive, the box is not completely inside this plane
			if checkForCompletelyInside and dist + radius > EPSILON then
				completelyInside = false
			end
		end
	end

	-- If we've made it here, the box is either inside or intersecting the frustum
	debug.profileend()
	return true, completelyInside
end

function CullThrottle._ingestVoxel(self: CullThrottle, now: number, voxel: types.Voxel)
	debug.profilebegin("ingestVoxel")
	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position
	local cameraLookVector = cameraCFrame.LookVector
	local cameraRightVector = cameraCFrame.RightVector
	local cameraUpVector = cameraCFrame.UpVector
	local halfHorizontalFov = CameraCache.HalfHorizontalFOV
	local halfVerticalFov = CameraCache.HalfVerticalFOV
	local renderDistance = self._config.renderDistance
	local bestRefreshRate = self._config.bestRefreshRate
	local worstRefreshRate = self._config.worstRefreshRate
	local refreshRateRange = self._config.refreshRateRange

	local objectVisibilityTimestamps = self._objectVisibilityTimestamps
	local visibleObjectsQueue = self._visibleObjectsQueue
	local objects = self._objects
	local pendingEnteredView = self._pendingEnteredView
	local pendingEnteredViewSize = self._pendingEnteredViewSize

	for _, object in voxel do
		local objectData = objects[object]
		if not objectData then
			continue
		end

		if objectData.lastCheckClock == now then
			-- Avoid duplicate checks on this object
			continue
		end
		objectData.lastCheckClock = now

		local dirToObject: Vector3 = objectData.cframe.Position - cameraPos
		local distance = vectorMagnitude(dirToObject)
		objectData.distance = distance
		if distance > renderDistance then
			-- Object is outside what we consider visible
			continue
		end

		-- Cull objects that fall fully outside the view frustum.
		--
		-- This only applies to objects whose center is in front of the camera.
		-- Once the center passes behind the camera plane, a large object can still
		-- wrap its body into view while the per-axis angle test no longer holds, so
		-- we keep it. The voxel search already discards voxels fully behind us.
		local forward = vectorDot(cameraLookVector, dirToObject)
		if forward > 0 then
			local right = vectorDot(cameraRightVector, dirToObject)
			local up = vectorDot(cameraUpVector, dirToObject)
			local radius = objectData.radius

			local horizontalDistance = math.sqrt(right * right + forward * forward)
			local verticalDistance = math.sqrt(up * up + forward * forward)
			local horizontalAngle = math.atan2(math.abs(right), forward)
				- math.asin(math.min(radius / horizontalDistance, 1))
			local verticalAngle = math.atan2(math.abs(up), forward) - math.asin(math.min(radius / verticalDistance, 1))
			if horizontalAngle > halfHorizontalFov or verticalAngle > halfVerticalFov then
				continue
			end
		end

		local screenSize = ObjectDimensions.getScreenSize(distance, objectData.radius)
		local elapsed = now - objectData.lastUpdateClock
		local jitteredElapsed = elapsed + objectData.jitterOffset

		local objectPriority = 0

		if jitteredElapsed <= bestRefreshRate then
			-- This was refreshed within the best rate, so push it far down the queue.
			objectPriority = P0_THRESHOLD + (1 - math.min(screenSize, 1)) * OVER_REFRESH_PRIORITY_SCALE
		elseif jitteredElapsed >= worstRefreshRate then
			-- To maintain the worst refresh rate, make this p0 priority
			-- Sort these p0s by screen size
			objectPriority = P0_THRESHOLD - screenSize
		elseif distance < NEARBY_DISTANCE_THRESHOLD then
			-- Objects right by camera should update basically every frame
			objectPriority = distance / NEARBY_DISTANCE_THRESHOLD
		else
			-- Determine the fair object priority
			local screenSizePriority = SCREEN_SIZE_PRIORITY_WEIGHT * (1 - screenSize)
			local refreshPriority = REFRESH_RATE_PRIORITY_WEIGHT
				* (1 - (jitteredElapsed - bestRefreshRate) / refreshRateRange)
			local distancePriority = DISTANCE_PRIORITY_WEIGHT * (distance / renderDistance)

			objectPriority = screenSizePriority + refreshPriority + distancePriority
		end

		visibleObjectsQueue:addToIncomingBatch(object, objectPriority)

		if objectVisibilityTimestamps[object] == nil then
			-- This object wasn't visible last frame but it is now
			pendingEnteredViewSize += 1
			pendingEnteredView[pendingEnteredViewSize] = object
		end
		objectVisibilityTimestamps[object] = now
	end

	self._pendingEnteredViewSize = pendingEnteredViewSize

	debug.profileend()
end

function CullThrottle._fastApproxIngestRemainingVoxels(self: CullThrottle, now: number, startIndex: number)
	local voxels = self._voxels
	local visibleVoxelKeys = self._visibleVoxelKeys
	local visibleVoxelCount = self._visibleVoxelCount
	local objectVisibilityTimestamps = self._objectVisibilityTimestamps
	local objects = self._objects
	local visibleObjectsQueue = self._visibleObjectsQueue
	local pendingEnteredView = self._pendingEnteredView
	local pendingEnteredViewSize = self._pendingEnteredViewSize

	for voxelIndex = startIndex, visibleVoxelCount do
		-- Just dump all the objects into the visible objects list,
		-- approximating priority by voxel order (closer voxels were searched first)
		local voxelKey = visibleVoxelKeys[voxelIndex]
		local voxel = voxels[voxelKey]
		if not voxel then
			continue
		end

		local approxPriority = voxelIndex * FAST_APPROX_VOXEL_PRIORITY_SCALE

		for _, object in voxel do
			local objectData = objects[object]
			if not objectData then
				continue
			end

			if objectData.lastCheckClock == now then
				-- Already ingested this frame (here or in the precise pass),
				-- so skip it to avoid duplicating an object that spans voxels
				continue
			end
			objectData.lastCheckClock = now

			visibleObjectsQueue:addToIncomingBatch(object, approxPriority)

			if objectVisibilityTimestamps[object] == nil then
				-- This object wasn't visible last frame but it is now
				pendingEnteredViewSize += 1
				pendingEnteredView[pendingEnteredViewSize] = object
			end
			objectVisibilityTimestamps[object] = now
		end
	end

	self._pendingEnteredViewSize = pendingEnteredViewSize

	self._perfMetrics._skippedIngest[1] = 1 + visibleVoxelCount - startIndex
end

local function partitionVoxelKeys(
	buffer: { types.VoxelKey },
	lo: number,
	hi: number,
	axis: number,
	splitCoord: number
): number
	-- Reorder buffer[lo..hi] in place so every key whose coordinate on the chosen
	-- axis is below splitCoord comes first. Returns mid, the first index of the
	-- high group: buffer[lo..mid-1] are below splitCoord, buffer[mid..hi] are at or
	-- above it. An empty range (hi < lo) returns lo. This is a Lomuto partition; the
	-- order within each group does not matter since the visible batch is sorted later.
	local mid = lo
	if axis == AXIS_X then
		for i = lo, hi do
			local k = buffer[i]
			if k.X < splitCoord then
				buffer[i], buffer[mid] = buffer[mid], buffer[i]
				mid += 1
			end
		end
	elseif axis == AXIS_Y then
		for i = lo, hi do
			local k = buffer[i]
			if k.Y < splitCoord then
				buffer[i], buffer[mid] = buffer[mid], buffer[i]
				mid += 1
			end
		end
	else
		for i = lo, hi do
			local k = buffer[i]
			if k.Z < splitCoord then
				buffer[i], buffer[mid] = buffer[mid], buffer[i]
				mid += 1
			end
		end
	end
	return mid
end

function CullThrottle._pushVolume(
	self: CullThrottle,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	lo: number,
	hi: number
)
	-- Append one volume (6 bounds plus its [lo, hi] slice of _searchVoxelKeys) onto
	-- the flat stack.
	local volumesToCheck = self._volumesToCheck
	local base = self._volumesToCheckSize
	volumesToCheck[base + 1] = x0
	volumesToCheck[base + 2] = y0
	volumesToCheck[base + 3] = z0
	volumesToCheck[base + 4] = x1
	volumesToCheck[base + 5] = y1
	volumesToCheck[base + 6] = z1
	volumesToCheck[base + 7] = lo
	volumesToCheck[base + 8] = hi
	self._volumesToCheckSize = base + 8
end

function CullThrottle._getVoxelKeysInVolume(
	self: CullThrottle,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	-- Fill _searchVoxelKeys with the occupied voxel keys inside the half-open box
	-- [x0,x1) x [y0,y1) x [z0,z1) and return how many there are. We walk only the
	-- coarse buckets the box overlaps and pull occupied keys straight out of them, so
	-- empty cells within the box are never visited.
	local coarseVoxels = self._coarseVoxels
	local searchVoxelKeys = self._searchVoxelKeys
	local count = 0

	-- (x1 - 1) // COARSE_VOXEL_SIZE so a box ending exactly on a bucket boundary doesn't reach into
	-- the empty bucket just past its edge.
	local cx0, cx1 = x0 // COARSE_VOXEL_SIZE, (x1 - 1) // COARSE_VOXEL_SIZE
	local cy0, cy1 = y0 // COARSE_VOXEL_SIZE, (y1 - 1) // COARSE_VOXEL_SIZE
	local cz0, cz1 = z0 // COARSE_VOXEL_SIZE, (z1 - 1) // COARSE_VOXEL_SIZE

	for cx = cx0, cx1 do
		local interiorX = cx * COARSE_VOXEL_SIZE >= x0 and (cx + 1) * COARSE_VOXEL_SIZE <= x1
		for cy = cy0, cy1 do
			local interiorXY = interiorX and cy * COARSE_VOXEL_SIZE >= y0 and (cy + 1) * COARSE_VOXEL_SIZE <= y1
			for cz = cz0, cz1 do
				local bucket = coarseVoxels[Vector3.new(cx, cy, cz)]
				if not bucket then
					-- No occupied voxels in this coarse cell
					continue
				end

				-- A bucket sitting fully inside the box needs no per-key filtering
				if interiorXY and cz * COARSE_VOXEL_SIZE >= z0 and (cz + 1) * COARSE_VOXEL_SIZE <= z1 then
					for i = 1, #bucket do
						count += 1
						searchVoxelKeys[count] = bucket[i]
					end
				else
					-- Edge bucket, so keep only the keys that fall inside the box
					for i = 1, #bucket do
						local voxelKey = bucket[i]
						local kx, ky, kz = voxelKey.X, voxelKey.Y, voxelKey.Z
						if kx >= x0 and kx < x1 and ky >= y0 and ky < y1 and kz >= z0 and kz < z1 then
							count += 1
							searchVoxelKeys[count] = voxelKey
						end
					end
				end
			end
		end
	end

	return count
end

function CullThrottle._searchVolume(
	self: CullThrottle,
	now: number,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	lo: number,
	hi: number
)
	-- This volume owns the occupied voxel keys in _searchVoxelKeys[lo..hi]. The buffer
	-- was seeded once at the root and is partitioned in place as volumes split, so
	-- there is nothing to gather here.
	if hi < lo then
		-- No occupied voxels in this box
		return
	end

	local lastVoxelVisibility = self._lastVoxelVisibility
	local searchVoxelKeys = self._searchVoxelKeys

	-- We add jitter so that we don't end up with every voxel ending grace on the same frame
	local JITTERED_LAST_VISIBILITY_GRACE_PERIOD = LAST_VISIBILITY_GRACE_PERIOD * (1 + (math.random() * 0.1 - 0.05))

	-- Special case for volumes of a single voxel
	if x1 - x0 == 1 and y1 - y0 == 1 and z1 - z0 == 1 then
		-- A single cell holds at most one occupied key, and the slice is non-empty here
		local voxelKey = searchVoxelKeys[lo]

		-- If this voxel was visible a moment ago, assume it still is
		if now - (lastVoxelVisibility[voxelKey] or 0) < JITTERED_LAST_VISIBILITY_GRACE_PERIOD then
			self:_addVoxelKeyToVisible(voxelKey)
			if _G.__DEV__ then
				self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
			end
			return
		end

		-- Alright, we actually do need to check if this voxel is visible
		local isInside = self:_isBoxInFrustum(false, frustumPlanes, x0, y0, z0, x1, y1, z1)
		if not isInside then
			-- Remove voxel visibility
			lastVoxelVisibility[voxelKey] = nil
			return
		end

		-- This voxel is visible
		lastVoxelVisibility[voxelKey] = now
		self:_addVoxelKeyToVisible(voxelKey)

		if _G.__DEV__ then
			self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		end

		return
	end

	-- Check whether every voxel here was visible a moment ago. We speculatively add
	-- each one to the visible set as we go; if we hit a stale voxel we roll those
	-- adds back and fall through to the real frustum check below. This relies on
	-- _searchVolume running serially (it does today); parallel volume workers would
	-- race on the shared visible set here.
	debug.profilebegin("checkBoxVisibilityCache")
	local startCount = self._visibleVoxelCount
	local allVoxelsVisible = true
	for i = lo, hi do
		local voxelKey = searchVoxelKeys[i]
		self:_addVoxelKeyToVisible(voxelKey)
		if now - (lastVoxelVisibility[voxelKey] or 0) >= JITTERED_LAST_VISIBILITY_GRACE_PERIOD then
			allVoxelsVisible = false
			self._visibleVoxelCount = startCount
			break
		end
	end
	debug.profileend()

	-- If all voxels in this box were visible a moment ago, just assume they still
	-- are. They were already added to the visible set during the check above. We
	-- deliberately don't refresh their grace timestamps here, so each will get a
	-- real frustum recheck once its grace period lapses.
	if allVoxelsVisible then
		if _G.__DEV__ then
			self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		end
		return
	end

	-- Alright, we actually do need to check if this box is visible
	local isInside, isCompletelyInside = self:_isBoxInFrustum(true, frustumPlanes, x0, y0, z0, x1, y1, z1)

	-- If the box is outside the frustum, stop checking now
	if not isInside then
		-- All voxels within this box are not visible and should clear their cache
		debug.profilebegin("clearBoxVisibilityCache")
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			if lastVoxelVisibility[voxelKey] then
				lastVoxelVisibility[voxelKey] = nil
			end
		end
		debug.profileend()
		return
	end

	-- If the box is entirely inside, then we know all voxels contained inside are in the frustum
	-- and we can process them now and not split further
	if isCompletelyInside then
		debug.profilebegin("isCompletelyInside")
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			lastVoxelVisibility[voxelKey] = now
			self:_addVoxelKeyToVisible(voxelKey)
		end
		debug.profileend()
		if _G.__DEV__ then
			self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		end
		return
	end

	-- We are partially inside, so we need to split this box up further
	-- to figure out which voxels within it are the ones inside

	-- Calculate the lengths of each axis
	local lengthX = x1 - x0
	local lengthY = y1 - y0
	local lengthZ = z1 - z0

	-- Split along the axis with the greatest length into two halves A and B.
	local axis, splitCoord
	local ax0, ay0, az0, ax1, ay1, az1
	local bx0, by0, bz0, bx1, by1, bz1
	if lengthX >= lengthY and lengthX >= lengthZ then
		axis = AXIS_X
		splitCoord = (x0 + x1) // 2
		ax0, ay0, az0, ax1, ay1, az1 = x0, y0, z0, splitCoord, y1, z1
		bx0, by0, bz0, bx1, by1, bz1 = splitCoord, y0, z0, x1, y1, z1
	elseif lengthY >= lengthX and lengthY >= lengthZ then
		axis = AXIS_Y
		splitCoord = (y0 + y1) // 2
		ax0, ay0, az0, ax1, ay1, az1 = x0, y0, z0, x1, splitCoord, z1
		bx0, by0, bz0, bx1, by1, bz1 = x0, splitCoord, z0, x1, y1, z1
	else
		axis = AXIS_Z
		splitCoord = (z0 + z1) // 2
		ax0, ay0, az0, ax1, ay1, az1 = x0, y0, z0, x1, y1, splitCoord
		bx0, by0, bz0, bx1, by1, bz1 = x0, y0, splitCoord, x1, y1, z1
	end

	-- Partition this volume's slice around the split plane: keys below splitCoord (the
	-- low half A) move to [lo, mid-1], the rest (the high half B) to [mid, hi]. The two
	-- child slices are disjoint and tile this one, so the search can keep partitioning
	-- each child's own range without disturbing any other volume on the stack.
	local mid = partitionVoxelKeys(searchVoxelKeys, lo, hi, axis, splitCoord)
	local aHasVoxels = mid - 1 >= lo
	local bHasVoxels = hi >= mid

	-- Alternate the order to ensure each volume gets its turn being processed
	-- first. The stack is LIFO, so the volume pushed last is searched first. Empty
	-- halves hold no occupied voxels, so we skip pushing them.
	if self._volumeRotationCounter % 2 == 0 then
		if aHasVoxels then
			self:_pushVolume(ax0, ay0, az0, ax1, ay1, az1, lo, mid - 1)
		end
		if bHasVoxels then
			self:_pushVolume(bx0, by0, bz0, bx1, by1, bz1, mid, hi)
		end
	else
		if bHasVoxels then
			self:_pushVolume(bx0, by0, bz0, bx1, by1, bz1, mid, hi)
		end
		if aHasVoxels then
			self:_pushVolume(ax0, ay0, az0, ax1, ay1, az1, lo, mid - 1)
		end
	end
end

function CullThrottle._reuseCachedVisibilityForRemainingVolumes(self: CullThrottle)
	debug.profilebegin("reuseCachedVisibilityForRemainingVolumes")
	local lastVoxelVisibility = self._lastVoxelVisibility
	local searchVoxelKeys = self._searchVoxelKeys

	local skipped = 0

	-- Each leftover volume still owns an intact [lo, hi] slice of the search buffer
	-- (a volume is only partitioned when it is popped, and these were never popped),
	-- so we just re-mark every key that was visible a moment ago.
	local volumesToCheck = self._volumesToCheck
	for base = 0, self._volumesToCheckSize - 1, 8 do
		local lo, hi = volumesToCheck[base + 7], volumesToCheck[base + 8]
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			skipped += 1
			if lastVoxelVisibility[voxelKey] then
				self:_addVoxelKeyToVisible(voxelKey)
			end
		end
	end

	self._perfMetrics._skippedSearch[1] = skipped
	debug.profileend()
end

function CullThrottle._clearVisibleObjects(self: CullThrottle)
	-- Resetting the count is enough; the search overwrites slots 1..count from the
	-- start each frame, so any stale trailing entries in the reused buffers are never read.
	self._visibleVoxelCount = 0
	self._visibleObjectsQueue:clearIncomingBatch()
	self._visibleObjectsQueue:clear()
end

function CullThrottle._fillVisibleObjectsQueue(self: CullThrottle)
	debug.profilebegin("fillVisibleObjectsQueue")
	self._visibleObjectsQueue:enqueueIncomingBatch()
	debug.profileend()
end

function CullThrottle._signalVisibilityChanges(self: CullThrottle, now: number)
	debug.profilebegin("signalVisibilityChanges")
	local objectVisibilityTimestamps = self._objectVisibilityTimestamps
	local pendingExitedView = self._pendingExitedView
	local pendingExitedViewSize = self._pendingExitedViewSize

	for object, lastSeen in objectVisibilityTimestamps do
		if lastSeen ~= now then
			-- Object was visible last frame but not this frame
			objectVisibilityTimestamps[object] = nil
			pendingExitedViewSize += 1
			pendingExitedView[pendingExitedViewSize] = object
		end
	end

	self._pendingExitedViewSize = pendingExitedViewSize

	debug.profileend()
end

function CullThrottle._flushVisibilitySignals(self: CullThrottle)
	-- Fire the visibility signals buffered during this frame's search/ingest.
	-- By the time we get here all of CullThrottle's own iteration over _voxels,
	-- _objects, and _objectVisibilityTimestamps is finished, so a handler is now
	-- free to mutate the tracked set (AddObject/RemoveObject) without corrupting
	-- an in-progress loop. We null out each slot as we go so a removed/destroyed
	-- instance isn't pinned in the buffer until the next frame overwrites it.
	debug.profilebegin("flushVisibilitySignals")

	local enteredView = self.ObjectEnteredView
	local pendingEnteredView = self._pendingEnteredView
	local enteredCount = self._pendingEnteredViewSize
	self._pendingEnteredViewSize = 0
	for i = 1, enteredCount do
		local object = pendingEnteredView[i]
		pendingEnteredView[i] = nil
		enteredView:Fire(object)
	end

	local exitedView = self.ObjectExitedView
	local pendingExitedView = self._pendingExitedView
	local exitedCount = self._pendingExitedViewSize
	self._pendingExitedViewSize = 0
	for i = 1, exitedCount do
		local object = pendingExitedView[i]
		pendingExitedView[i] = nil
		exitedView:Fire(object)
	end

	debug.profileend()
end

function CullThrottle._findVisibleObjects(self: CullThrottle, now: number)
	debug.profilebegin("findVisibleObjects")

	-- Clear any objects left over from last frame
	self:_clearVisibleObjects()

	self._perfMetrics._skippedIngest[SKIPPED_FRAMES_LOOKBACK] = nil
	self._perfMetrics._skippedSearch[SKIPPED_FRAMES_LOOKBACK] = nil
	tableInsert(self._perfMetrics._skippedIngest, 1, 0)
	tableInsert(self._perfMetrics._skippedSearch, 1, 0)

	local searchTimeBudget = self._config.searchTimeBudget
	local ingestTimeBudget = self._config.ingestTimeBudget
	local voxelSize = self._config.voxelSize
	local renderDistance = self._config.renderDistance

	local frustumPlanes, minBound, maxBound = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

	local minX = minBound.X
	local minY = minBound.Y
	local minZ = minBound.Z
	local maxX = maxBound.X + 1
	local maxY = maxBound.Y + 1
	local maxZ = maxBound.Z + 1

	local volumesToCheck = self._volumesToCheck
	self._volumesToCheckSize = 0

	-- Seed the search buffer once with every occupied voxel key inside the frustum
	-- bounds. The search reads and partitions this buffer in place from here on, so
	-- the sparse voxel set is never rescanned per box.
	debug.profilebegin("seedSearchVoxelKeys")
	local total = self:_getVoxelKeysInVolume(minX, minY, minZ, maxX, maxY, maxZ)

	-- Split into smaller boxes to start off since the frustum bounding volume
	-- obviously intersects the frustum planes.
	if minX == maxX or minY == maxY or minZ == maxZ then
		-- If the bounds are not divisible then don't split early
		self:_pushVolume(minX, minY, minZ, maxX, maxY, maxZ, 1, total)
	else
		local midBound = (minBound + maxBound) // 2
		local midX = midBound.X
		local midY = midBound.Y
		local midZ = midBound.Z

		-- Partition the seeded keys into the eight octant slices matching the boxes
		-- pushed below: by X at midX, then Y within each X half, then Z within each of
		-- the four. Every octant ends up owning a contiguous range. Some ranges may be
		-- empty (lo > hi); those octants are still pushed so the rotation below always
		-- operates on exactly eight blocks, and they return immediately when searched.
		local searchVoxelKeys = self._searchVoxelKeys
		local mx = partitionVoxelKeys(searchVoxelKeys, 1, total, AXIS_X, midX)
		local myLo = partitionVoxelKeys(searchVoxelKeys, 1, mx - 1, AXIS_Y, midY)
		local myHi = partitionVoxelKeys(searchVoxelKeys, mx, total, AXIS_Y, midY)
		local mz1 = partitionVoxelKeys(searchVoxelKeys, 1, myLo - 1, AXIS_Z, midZ)
		local mz2 = partitionVoxelKeys(searchVoxelKeys, myLo, mx - 1, AXIS_Z, midZ)
		local mz3 = partitionVoxelKeys(searchVoxelKeys, mx, myHi - 1, AXIS_Z, midZ)
		local mz4 = partitionVoxelKeys(searchVoxelKeys, myHi, total, AXIS_Z, midZ)

		self:_pushVolume(minX, minY, minZ, midX, midY, midZ, 1, mz1 - 1)
		self:_pushVolume(midX, minY, minZ, maxX, midY, midZ, mx, mz3 - 1)
		self:_pushVolume(minX, minY, midZ, midX, midY, maxZ, mz1, myLo - 1)
		self:_pushVolume(midX, minY, midZ, maxX, midY, maxZ, mz3, myHi - 1)
		self:_pushVolume(minX, midY, minZ, midX, maxY, midZ, myLo, mz2 - 1)
		self:_pushVolume(midX, midY, minZ, maxX, maxY, midZ, myHi, mz4 - 1)
		self:_pushVolume(minX, midY, midZ, midX, maxY, maxZ, mz2, mx - 1)
		self:_pushVolume(midX, midY, midZ, maxX, maxY, maxZ, mz4, total)

		-- Ensures each octant gets its turn being processed first. The stack is
		-- LIFO, so move the chosen octant's 8 numbers into the top block (8).
		local firstVolumeIndex = self._volumeRotationCounter % 8 + 1
		if firstVolumeIndex == 8 then
			-- Octant 8 is already on top, so no swap is needed. Reset the counter
			-- to 0 so the next frame selects octant 1 and the full 1..8 rotation
			-- continues.
			self._volumeRotationCounter = 0
		else
			local chosenBase = (firstVolumeIndex - 1) * 8
			local topBase = 7 * 8
			for k = 1, 8 do
				volumesToCheck[chosenBase + k], volumesToCheck[topBase + k] =
					volumesToCheck[topBase + k], volumesToCheck[chosenBase + k]
			end
			self._volumeRotationCounter += 1
		end
	end
	debug.profileend()

	local voxels = self._voxels

	debug.profilebegin("searchVolumes")
	while self._volumesToCheckSize > 0 do
		-- Pop the top volume (8 numbers: 6 bounds plus its [lo, hi] slice). We read
		-- everything into locals before shrinking the stack so _searchVolume can reuse
		-- the just-freed slots for any child volumes it pushes.
		local n = self._volumesToCheckSize
		local x0 = volumesToCheck[n - 7]
		local y0 = volumesToCheck[n - 6]
		local z0 = volumesToCheck[n - 5]
		local x1 = volumesToCheck[n - 4]
		local y1 = volumesToCheck[n - 3]
		local z1 = volumesToCheck[n - 2]
		local lo = volumesToCheck[n - 1]
		local hi = volumesToCheck[n]
		self._volumesToCheckSize = n - 8

		-- Search the volume for visible voxels
		self:_searchVolume(now, frustumPlanes, x0, y0, z0, x1, y1, z1, lo, hi)

		if os.clock() - now >= searchTimeBudget then
			-- We've run out of time!
			self:_reuseCachedVisibilityForRemainingVolumes()
			break
		end
	end
	self._perfMetrics._searchDuration = os.clock() - now
	debug.profileend()

	-- The search appended visible voxels in subdivision order; order them
	-- closest-first so the ingest below spends its budget on the nearest voxels.
	debug.profilebegin("sortVisibleVoxels")
	self:_sortVisibleVoxelKeys()
	debug.profileend()

	debug.profilebegin("ingestVoxels")
	local visibleVoxelKeys = self._visibleVoxelKeys
	local visibleVoxelCount = self._visibleVoxelCount
	local startIngestClock = os.clock()
	for voxelIndex = 1, visibleVoxelCount do
		local voxelKey = visibleVoxelKeys[voxelIndex]
		local voxel = voxels[voxelKey]
		if not voxel then
			continue
		end

		self:_ingestVoxel(now, voxel)

		if os.clock() - startIngestClock >= ingestTimeBudget then
			-- We've run out of time!
			self:_fastApproxIngestRemainingVoxels(now, voxelIndex + 1)
			break
		end
	end

	self._perfMetrics._ingestDuration = os.clock() - startIngestClock
	debug.profileend()

	debug.profileend()
end

function CullThrottle._adjustDynamicRenderDistance(self: CullThrottle)
	if not self._config.dynamicRenderDistance then
		return
	end

	local config = self._config
	local perfMetrics = self._perfMetrics

	-- Skipped frames mean we couldn't even keep up, regardless of budget load.
	local isSkipping = perfMetrics._getAverage(perfMetrics._skippedIngest) ~= 0
		or perfMetrics._getAverage(perfMetrics._skippedSearch) ~= 0

	-- Normalize each constraint to where 1 means at budget, weighted by how costly
	-- an overrun is, and let the worst one drive the decision.
	local load = math.max(
		(perfMetrics._searchDuration / config.searchTimeBudget) * DYNAMIC_RENDER_DISTANCE_SEARCH_WEIGHT,
		(perfMetrics._ingestDuration / config.ingestTimeBudget) * DYNAMIC_RENDER_DISTANCE_INGEST_WEIGHT,
		(perfMetrics._averageObjectDeltaTime / config.refreshRateMidpoint) * DYNAMIC_RENDER_DISTANCE_DELTA_WEIGHT
	)

	-- -1 shrink, 0 hold (within the deadband), 1 grow
	local direction = if isSkipping or load > 1 then -1 elseif load < DYNAMIC_RENDER_DISTANCE_GROW_HEADROOM then 1 else 0

	-- Adapt the step rather than slamming on any signal.
	local step = config.renderDistanceStep
	local lastDirection = config.renderDistanceDirection
	if direction == 0 or (lastDirection ~= 0 and direction ~= lastDirection) then
		-- Settled in the deadband, or reversed past the sustainable edge: damp to settle.
		step *= DYNAMIC_RENDER_DISTANCE_STEP_DAMPING
	else
		-- Consistent direction (or first move from rest): accelerate to catch up.
		step *= DYNAMIC_RENDER_DISTANCE_STEP_GAIN
	end
	step = math.clamp(step, DYNAMIC_RENDER_DISTANCE_MIN_STEP, DYNAMIC_RENDER_DISTANCE_MAX_STEP)

	config.renderDistanceStep = step
	config.renderDistanceDirection = direction

	if direction ~= 0 then
		config.renderDistance = math.clamp(
			config.renderDistance + direction * step * config.renderDistanceMidpoint,
			config.minRenderDistance,
			config.maxRenderDistance
		)
	end
end

function CullThrottle._processObjectVisibility(self: CullThrottle, start: number)
	if self._processedVisibilityThisFrame then
		-- Already processed!
		return
	end

	debug.profilebegin("CullThrottle.processObjectVisibility")

	-- Keep our voxels up to date before searching for visibility
	self:_pollPhysicsObjects(PHYSICS_POLL_TIME_BUDGET, start)
	self:_updateObjectVoxels(VOXEL_MAINTENANCE_TIME_BUDGET, os.clock())

	-- Find the objects that are visible this frame
	self:_findVisibleObjects(start)

	-- Signal the visibility changes to the event handler
	self:_signalVisibilityChanges(start)

	-- Adjust dynamic render distance to hit the budgets
	self:_adjustDynamicRenderDistance()

	-- Mark the frame done before flushing so a signal handler that re-enters
	-- (e.g. calls GetVisibleObjects/IterateObjectsToUpdate) short-circuits
	-- instead of recomputing visibility from inside the flush.
	self._processedVisibilityThisFrame = true

	-- All of our own iteration is finished, so it's now safe to fire the
	-- visibility signals we buffered during the search/ingest pass.
	self:_flushVisibilitySignals()

	debug.profileend()
end

--[[
	Public APIs
--]]

function CullThrottle.new(): CullThrottle
	local self = setmetatable({}, CullThrottle)

	self._config = Config.new()

	self.ObjectEnteredView = GoodSignal.new()
	self.ObjectExitedView = GoodSignal.new()
	self.ObjectAdded = GoodSignal.new()
	self.ObjectRemoved = GoodSignal.new()

	self._perfMetrics = {
		_skippedSearch = tableCreate(SKIPPED_FRAMES_LOOKBACK, 0),
		_skippedIngest = tableCreate(SKIPPED_FRAMES_LOOKBACK, 0),
		_searchDuration = 0,
		_ingestDuration = 0,
		_averageObjectDeltaTime = self._config.bestRefreshRate,
		_getAverage = function(values: { number }): number
			local sum = 0
			for _, value in values do
				sum += value
			end
			return sum / SKIPPED_FRAMES_LOOKBACK
		end,
	}

	self._voxels = {}
	self._coarseVoxels = {}
	self._searchVoxelKeys = {}
	self._objects = {}
	self._objectCount = 0
	self._physicsObjects = {}
	self._physicsObjectIterIndex = 1
	self._updateObjectVoxelsQueue = PriorityQueue.new()
	self._visibleObjectsQueue = PriorityQueue.new()
	self._visibleVoxelKeys = {}
	self._visibleVoxelCount = 0
	self._pendingVoxelKeys = {}
	self._pendingVoxelDistances = {}
	self._voxelDistanceCounts = {}
	self._objectVisibilityTimestamps = {}
	self._lastVoxelVisibility = {}
	self._lastTableResize = os.clock()
	self._processedVisibilityThisFrame = false
	self._volumesToCheck = tableCreate(64)
	self._volumesToCheckSize = 0
	self._volumeRotationCounter = 0
	self._pendingEnteredView = {}
	self._pendingEnteredViewSize = 0
	self._pendingExitedView = {}
	self._pendingExitedViewSize = 0
	self._tagConnections = {}
	self._renderConnection = RunService.PreRender:Connect(function()
		self._processedVisibilityThisFrame = false

		local now = os.clock()

		-- Resize tables every now and then
		if now - self._lastTableResize > RESIZE_TABLES_RATE then
			self._lastTableResize = now
			self:_resizeTables()
		end

		if
			self._config.computeVisibilityOnlyOnDemand == false
			or self.ObjectEnteredView._connectionCount > 0
			or self.ObjectExitedView._connectionCount > 0
		then
			self:_processObjectVisibility(now)
		end
	end)

	return self
end

function CullThrottle.Destroy(self: CullThrottle)
	-- Stop the per-frame processing loop. This is the most important step;
	-- without it the PreRender connection keeps this instance (and everything
	-- it references) alive forever.
	self._renderConnection:Disconnect()

	-- Disconnect all CollectionService tag listeners
	for _, tagConnections in self._tagConnections do
		for _, connection in tagConnections do
			connection:Disconnect()
		end
	end
	tableClear(self._tagConnections)

	-- Disconnect the per-object dimension change listeners
	for _, objectData in self._objects do
		for _, connection in objectData.changeConnections do
			connection:Disconnect()
		end
	end

	-- Drop all handlers on our signals so nothing fires after destruction
	self.ObjectEnteredView:DisconnectAll()
	self.ObjectExitedView:DisconnectAll()
	self.ObjectAdded:DisconnectAll()
	self.ObjectRemoved:DisconnectAll()

	-- Clear out all tracked state so it can be garbage collected
	tableClear(self._voxels)
	tableClear(self._coarseVoxels)
	tableClear(self._objects)
	self._objectCount = 0
	tableClear(self._physicsObjects)
	tableClear(self._objectVisibilityTimestamps)
	tableClear(self._lastVoxelVisibility)
	tableClear(self._visibleVoxelKeys)
	self._visibleVoxelCount = 0
	tableClear(self._pendingVoxelKeys)
	tableClear(self._pendingVoxelDistances)
	tableClear(self._voxelDistanceCounts)
	tableClear(self._volumesToCheck)
	self._volumesToCheckSize = 0
	tableClear(self._pendingEnteredView)
	self._pendingEnteredViewSize = 0
	tableClear(self._pendingExitedView)
	self._pendingExitedViewSize = 0
	self._updateObjectVoxelsQueue:clearIncomingBatch()
	self._updateObjectVoxelsQueue:clear()
	self._visibleObjectsQueue:clearIncomingBatch()
	self._visibleObjectsQueue:clear()
end

function CullThrottle.AddObject(self: CullThrottle, object: Instance)
	if self._objects[object] then
		return
	end

	local cframeSource, cframeType = ObjectDimensions.getObjectCFrameSource(object)
	local boundingBoxSource, boundingBoxType = ObjectDimensions.getObjectBoundingBoxSource(object)

	if not cframeSource or not cframeType then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, cframe is unknown")
	end

	if not boundingBoxSource or not boundingBoxType then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	local objectData: types.ObjectData = {
		cframe = CFrame.new(),
		distance = 1,
		halfBoundingBox = Vector3.one,
		radius = 0.5,
		voxelKeys = {},
		desiredVoxelKeys = {},
		lastCheckClock = 0,
		lastUpdateClock = 0,
		jitterOffset = math.random(-1000, 1000) / 500000,
		changeConnections = {},
		cframeSource = cframeSource,
		cframeType = cframeType,
		boundingBoxSource = boundingBoxSource,
		boundingBoxType = boundingBoxType,
	}

	local cframe = ObjectDimensions.getObjectCFrame(objectData)
	if not cframe then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, cframe is unknown")
	end

	objectData.cframe = cframe
	objectData.distance = vectorMagnitude(CameraCache.Position - cframe.Position)

	local boundingBox = ObjectDimensions.getObjectBoundingBox(objectData)
	if not boundingBox then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	objectData.halfBoundingBox = boundingBox / 2
	objectData.radius = vectorMagnitude(objectData.halfBoundingBox)

	ObjectDimensions.subscribeToDimensionChanges(objectData, function(newCFrame: CFrame)
		-- Update CFrame
		objectData.cframe = newCFrame
		objectData.distance = vectorMagnitude(newCFrame.Position - CameraCache.Position)
		self:_updateDesiredVoxelKeys(object, objectData)
	end, function(newBoundingBox: Vector3)
		-- Update bounding box and radius
		objectData.halfBoundingBox = newBoundingBox / 2
		objectData.radius = vectorMagnitude(objectData.halfBoundingBox)

		self:_updateDesiredVoxelKeys(object, objectData)
	end)

	tableInsert(
		objectData.changeConnections,
		object.Destroying:Connect(function()
			self:RemoveObject(object)
		end)
	)

	self:_updateDesiredVoxelKeys(object, objectData)

	self._objects[object] = objectData
	-- Only reached for genuinely new objects; the early-return above makes
	-- AddObject idempotent, so a repeat add can't double-count.
	self._objectCount += 1

	for voxelKey, desired in objectData.desiredVoxelKeys do
		if desired then
			self:_insertToVoxel(voxelKey, object)
			objectData.voxelKeys[voxelKey] = true
			objectData.desiredVoxelKeys[voxelKey] = nil
		end
	end

	self.ObjectAdded:Fire(object)
end

function CullThrottle.AddPhysicsObject(self: CullThrottle, object: BasePart)
	self:AddObject(object)

	-- Also add it to the physics objects table for polling position changes
	-- (physics based movement doesn't trigger the normal connection).
	--
	-- Guard against duplicate registration. AddObject above is idempotent, but
	-- without this check a second AddPhysicsObject call would insert the same
	-- object into _physicsObjects again.
	-- Using tableFind (rather than an early-return on self._objects[object])
	-- still lets an already-added static object be upgraded to a physics object.
	if not tableFind(self._physicsObjects, object) then
		tableInsert(self._physicsObjects, object)
	end
end

function CullThrottle.RemoveObject(self: CullThrottle, object: Instance)
	local objectData = self._objects[object]
	if not objectData then
		return
	end

	self._objects[object] = nil
	-- Guarded by the early-return above, so an untracked remove can't underflow.
	self._objectCount -= 1

	-- Drop the visibility timestamp so the next _signalVisibilityChanges pass
	-- doesn't fire a spurious ObjectExitedView for an object we've already removed
	-- (and already fired ObjectRemoved for). Removal is signalled by
	-- ObjectRemoved, not ObjectExitedView.
	self._objectVisibilityTimestamps[object] = nil

	local physicsObjectIndex = tableFind(self._physicsObjects, object)
	if physicsObjectIndex then
		-- Fast unordered remove
		local n = #self._physicsObjects
		if physicsObjectIndex ~= n then
			self._physicsObjects[physicsObjectIndex] = self._physicsObjects[n]
		end
		self._physicsObjects[n] = nil
	end

	for _, connection in objectData.changeConnections do
		connection:Disconnect()
	end
	for voxelKey in objectData.voxelKeys do
		self:_removeFromVoxel(voxelKey, object)
	end

	self.ObjectRemoved:Fire(object)
end

function CullThrottle.CaptureTag(self: CullThrottle, tag: string)
	-- Release prior capture to avoid leaking connections
	self:ReleaseTag(tag)

	-- Capturing a tag is a bulk, declarative operation: the caller tags a set of
	-- instances and expects CullThrottle to track whatever it can. But a tagged
	-- instance may be something we can't size or position (a Folder, a
	-- Configuration, a Beam without attachments, ...), and AddObject/AddPhysicsObject
	-- error() on those. We pcall each add so one un-addable instance can't abort
	-- capture of the rest, nor throw out of a CollectionService signal handler.
	-- Direct AddObject calls still error() for fail-fast misuse detection; only this
	-- tag-driven path is made tolerant.
	local function tryAddTaggedObject(object: Instance)
		local ok, err = pcall(function()
			if object:IsA("BasePart") and object.Anchored == false then
				self:AddPhysicsObject(object)
			else
				self:AddObject(object)
			end
		end)
		if not ok then
			warn(`[CullThrottle] Skipping tagged instance {object:GetFullName()}: {err}`)
		end
	end

	self._tagConnections[tag] = {
		CollectionService:GetInstanceAddedSignal(tag):Connect(tryAddTaggedObject),
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(object: Instance)
			self:RemoveObject(object)
		end),
	}

	for _, object in CollectionService:GetTagged(tag) do
		tryAddTaggedObject(object)
	end
end

function CullThrottle.ReleaseTag(self: CullThrottle, tag: string)
	local tagConnections = self._tagConnections[tag]
	if not tagConnections then
		return
	end

	for _, connection in tagConnections do
		connection:Disconnect()
	end

	self._tagConnections[tag] = nil
end

function CullThrottle.RemoveObjectsWithTag(self: CullThrottle, tag: string)
	-- Snapshot the matching objects before removing any. RemoveObject mutates
	-- _objects (and fires ObjectRemoved, whose handler may mutate it further),
	-- so iterating _objects directly while removing would be undefined.
	local toRemove = {}
	local count = 0
	for object in self._objects do
		if object:HasTag(tag) then
			count += 1
			toRemove[count] = object
		end
	end

	for i = 1, count do
		self:RemoveObject(toRemove[i])
	end
end

function CullThrottle.GetVisibleObjects(self: CullThrottle): { Instance }
	-- Process visibility if we haven't already processed this frame yet
	self:_processObjectVisibility(os.clock())

	return tableClone(self._visibleObjectsQueue._incomingBatch.items)
end

function CullThrottle.IterateObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?, number?, CFrame?)
	debug.profilebegin("CullThrottle.iterObjects")

	-- Process visibility if we haven't already processed this frame yet
	self:_processObjectVisibility(os.clock())

	-- We need to put the visibleObjects into our priority queue,
	-- which we then empty as we iterate through the objects
	self:_fillVisibleObjectsQueue()

	local updateStartClock = os.clock()
	local queue = self._visibleObjectsQueue
	local updateTimeBudget = self._config.updateTimeBudget
	-- p0s can go a little over budget.
	-- If we're trying to enforce the worst refresh rate, then they can go hugely over budget.
	local p0UpdateTimeBudget = if self._config.strictlyEnforceWorstRefreshRate then 1 else updateTimeBudget * 1.15

	local updatedObjects = 0
	local sumOfObjectDeltaTimes = 0

	local function finish()
		debug.profileend()

		if updatedObjects > 0 then
			self._perfMetrics._averageObjectDeltaTime = sumOfObjectDeltaTimes / updatedObjects
		end

		return nil
	end

	return function()
		if queue:isEmpty() then
			return finish()
		end

		local budget = if queue:peekPriority() < P0_THRESHOLD then p0UpdateTimeBudget else updateTimeBudget
		if os.clock() - updateStartClock >= budget then
			-- Out of time, can't update the rest this frame.
			-- That's okay, they'll be higher priority next time.

			-- Just in case the user iterates multiple times in a single frame,
			-- lets clear out the leftovers so they don't spill into the second iter
			queue:clear()

			return finish()
		end

		local object = queue:dequeue()
		if not object then
			return finish()
		end

		local objectData = self._objects[object]
		if not objectData then
			return finish()
		end

		local objectDeltaTime = updateStartClock - objectData.lastUpdateClock
		objectData.lastUpdateClock = updateStartClock

		if objectDeltaTime < 1 then
			-- If dt is over a second, that's just an object we haven't seen in a while,
			-- not indicative of the object's actual refresh rate.
			-- (If we're running at 1Hz fr, then we have bigger problems lol)
			sumOfObjectDeltaTimes += objectDeltaTime
			updatedObjects += 1
		end

		return object, objectDeltaTime, objectData.distance, objectData.cframe
	end
end

function CullThrottle.SetVoxelSize(self: CullThrottle, voxelSize: number)
	if voxelSize <= 0 then
		-- A zero or negative voxel size divides by zero in the voxel coordinate math
		error("SetVoxelSize expects a voxel size greater than zero")
	end

	self._config.voxelSize = voxelSize
	self._config.multiVoxelRadiusThreshold = voxelSize * 0.25

	-- We need to move all the objects around to their new voxels
	self._voxels = {}
	self._coarseVoxels = {}

	for object, objectData in self._objects do
		self:_updateDesiredVoxelKeys(object, objectData)
	end

	self:_updateObjectVoxels(5, os.clock())
end

function CullThrottle.SetRenderDistanceRange(self: CullThrottle, renderDistanceRange: NumberRange)
	local minRenderDistance = renderDistanceRange.Min
	local maxRenderDistance = renderDistanceRange.Max
	if minRenderDistance <= 0 then
		-- The render distance is a divisor in the priority math and seeds the
		-- min/max bounds, so a zero or negative distance corrupts visibility state.
		-- (NumberRange already guarantees Min <= Max, so checking Min covers Max.)
		error("SetRenderDistanceRange expects render distances greater than zero")
	end

	local config = self._config
	config.minRenderDistance = minRenderDistance
	config.maxRenderDistance = maxRenderDistance
	config.renderDistanceMidpoint = (minRenderDistance + maxRenderDistance) / 2
	-- Dynamic render distance is implied by a range that spans more than one value.
	-- A zero-width range (Min == Max) pins the distance and disables the controller.
	config.dynamicRenderDistance = minRenderDistance ~= maxRenderDistance
	-- Reset the live distance to the range's baseline; the controller floats from here.
	config.renderDistance = config.renderDistanceMidpoint
end

function CullThrottle.SetTimeBudgets(
	self: CullThrottle,
	searchTimeBudget: number,
	ingestTimeBudget: number,
	updateTimeBudget: number
)
	if searchTimeBudget < 0 or ingestTimeBudget < 0 or updateTimeBudget < 0 then
		-- Budgets are per-frame time allowances in seconds; a negative budget
		-- silently starves the corresponding pass. Zero is allowed (skip the work).
		error("SetTimeBudgets expects non-negative time budgets in seconds")
	end

	self._config.searchTimeBudget = searchTimeBudget
	self._config.ingestTimeBudget = ingestTimeBudget
	self._config.updateTimeBudget = updateTimeBudget
end

function CullThrottle.SetRefreshRates(self: CullThrottle, refreshRates: NumberRange)
	-- Rates are in Hz. The most frequent (best) rate is the higher number, so it
	-- maps to the range's Max; the least frequent (worst) rate maps to Min.
	-- NumberRange already guarantees Min <= Max, so the best rate can never be
	-- slower than the worst, and checking Min > 0 covers Max too.
	local worstHz = refreshRates.Min
	local bestHz = refreshRates.Max
	if worstHz <= 0 then
		error("SetRefreshRates expects refresh rates in Hz greater than zero")
	end

	local bestPeriod = 1 / bestHz
	local worstPeriod = 1 / worstHz

	local config = self._config
	config.bestRefreshRate = bestPeriod
	config.worstRefreshRate = worstPeriod
	config.refreshRateRange = worstPeriod - bestPeriod
	config.refreshRateMidpoint = (worstPeriod + bestPeriod) / 2
end

function CullThrottle.SetComputeVisibilityOnlyOnDemand(self: CullThrottle, computeVisibilityOnlyOnDemand: boolean)
	self._config.computeVisibilityOnlyOnDemand = computeVisibilityOnlyOnDemand
end

function CullThrottle.SetStrictlyEnforceWorstRefreshRate(self: CullThrottle, strictlyEnforceWorstRefreshRate: boolean)
	self._config.strictlyEnforceWorstRefreshRate = strictlyEnforceWorstRefreshRate
end

function CullThrottle.GetVoxelSize(self: CullThrottle): number
	return self._config.voxelSize
end

function CullThrottle.GetRenderDistanceRange(self: CullThrottle): NumberRange
	-- Mirrors SetRenderDistanceRange. The configured [min, max] bounds the live
	-- distance floats within; an equal min and max disables dynamic adjustment.
	local config = self._config
	return NumberRange.new(config.minRenderDistance, config.maxRenderDistance)
end

function CullThrottle.GetRenderDistance(self: CullThrottle): number
	-- The live, effective render distance. With dynamic render distance enabled
	-- this is the value the controller has settled on and may differ from the
	-- configured range's midpoint (see GetRenderDistanceRange).
	return self._config.renderDistance
end

function CullThrottle.GetTimeBudgets(self: CullThrottle): (number, number, number)
	-- Mirrors SetTimeBudgets: search, ingest, update, all in seconds.
	local config = self._config
	return config.searchTimeBudget, config.ingestTimeBudget, config.updateTimeBudget
end

function CullThrottle.GetRefreshRates(self: CullThrottle): NumberRange
	-- Mirrors SetRefreshRates, returning rates in Hz. The config stores them as
	-- seconds-between-refreshes periods, so we invert back to Hz here rather than
	-- leaking the internal unit (keeps the Hz-only contract symmetric). The worst
	-- (least frequent) rate is the lower number, so it is the range's Min.
	local config = self._config
	return NumberRange.new(1 / config.worstRefreshRate, 1 / config.bestRefreshRate)
end

function CullThrottle.GetComputeVisibilityOnlyOnDemand(self: CullThrottle): boolean
	return self._config.computeVisibilityOnlyOnDemand
end

function CullThrottle.GetStrictlyEnforceWorstRefreshRate(self: CullThrottle): boolean
	return self._config.strictlyEnforceWorstRefreshRate
end

function CullThrottle.GetDynamicRenderDistance(self: CullThrottle): boolean
	-- Derived, read-only: dynamic adjustment is active whenever the render distance
	-- range spans more than a single value. Set the range via SetRenderDistanceRange;
	-- a zero-width range (Min == Max) pins the distance and disables the controller.
	return self._config.dynamicRenderDistance
end

function CullThrottle.IsTracking(self: CullThrottle, object: Instance): boolean
	return self._objects[object] ~= nil
end

function CullThrottle.GetTrackedObjects(self: CullThrottle): { Instance }
	-- Fresh array snapshot so callers can iterate/mutate it freely without
	-- touching CullThrottle's internal state.
	local objects = tableCreate(self._objectCount)
	local count = 0
	for object in self._objects do
		count += 1
		objects[count] = object
	end
	return objects
end

function CullThrottle.GetTrackedObjectCount(self: CullThrottle): number
	return self._objectCount
end

function CullThrottle.GetPerformanceMetrics(self: CullThrottle): {
	searchDuration: number,
	ingestDuration: number,
	skippedSearch: number,
	skippedIngest: number,
	averageObjectDeltaTime: number,
}
	-- Read-only snapshot of the latest perf metrics with public field names, so
	-- callers never get a reference to the internal _perfMetrics table. Durations
	-- and averageObjectDeltaTime are in seconds; the skipped counts are the most
	-- recent frame's tallies.
	local perfMetrics = self._perfMetrics
	return {
		searchDuration = perfMetrics._searchDuration,
		ingestDuration = perfMetrics._ingestDuration,
		skippedSearch = perfMetrics._skippedSearch[1],
		skippedIngest = perfMetrics._skippedIngest[1],
		averageObjectDeltaTime = perfMetrics._averageObjectDeltaTime,
	}
end

return CullThrottle
