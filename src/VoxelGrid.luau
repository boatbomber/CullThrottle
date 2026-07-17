--!strict
--!optimize 2
--!native

--[[
	This module maintains the voxel grid the tracked objects live in. It figures
	out which voxels each object should occupy (a single cell for small objects,
	an oriented-box fill for large ones), handles the insert/remove bookkeeping
	as objects move, and keeps the coarse-bucket index over occupied voxels that
	the visibility search seeds from.
]]

local types = require(script.Parent.types)
local Config = require(script.Parent.Config)
local PriorityQueue = require(script.Parent.PriorityQueue)
local VisibilityCache = require(script.Parent.VisibilityCache)
local CameraCache = require(script.Parent.Utilities.CameraCache)

local tableInsert = table.insert
local tableFind = table.find
local tableClear = table.clear

-- The visibility search collects occupied voxel keys once per frame. To avoid
-- touching empty cells, occupied voxel keys are also bucketed into a coarse grid
-- (each bucket spans COARSE_VOXEL_SIZE voxels per axis) so the collection iterates
-- only the occupied keys it overlaps instead of every cell within the bounds.
local COARSE_VOXEL_SIZE = 4

local VoxelGrid = {}
VoxelGrid.__index = VoxelGrid

VoxelGrid.COARSE_VOXEL_SIZE = COARSE_VOXEL_SIZE

type VoxelGridProto = {
	_config: Config.Config,
	_visibilityCache: VisibilityCache.VisibilityCache,
	-- This is an alias of ObjectLifecycle's tracked-object map, injected so the
	-- grid can look up queued objects without a module dependency on its owner.
	-- It's only ever mutated in place, never reassigned.
	_objects: { [Instance]: types.ObjectData },

	_voxels: { [types.VoxelKey]: types.Voxel },
	_coarseVoxels: { [types.CoarseVoxelKey]: { types.VoxelKey } },
	_coarseBucketCount: number,
	-- The bounding box (inclusive, in coarse-cell coordinates) of the occupied
	-- coarse buckets clamps the seed scan to space that can actually hold voxels.
	-- It goes dirty after a boundary bucket is removed, and the next scan lazily
	-- recomputes it.
	_coarseBoundsDirty: boolean,
	_coarseMinX: number,
	_coarseMinY: number,
	_coarseMinZ: number,
	_coarseMaxX: number,
	_coarseMaxY: number,
	_coarseMaxZ: number,
	-- This counts every change to the set of occupied voxel keys, meaning a
	-- voxel created or emptied, plus the wholesale clears. The search's
	-- whole-frame replay compares it across frames, because with the camera
	-- holding still the visible voxel set can only change through this set.
	_occupancyGeneration: number,
	_updateObjectVoxelsQueue: PriorityQueue.PriorityQueue<Instance>,
}

export type VoxelGrid = typeof(setmetatable({} :: VoxelGridProto, VoxelGrid))

--[[
	Builds an empty grid over the given tracked-object map.
]]
function VoxelGrid.new(
	config: Config.Config,
	visibilityCache: VisibilityCache.VisibilityCache,
	objects: { [Instance]: types.ObjectData }
): VoxelGrid
	local self = setmetatable({
		_config = config,
		_visibilityCache = visibilityCache,
		_objects = objects,
		_voxels = {},
		_coarseVoxels = {},
		_coarseBucketCount = 0,
		_coarseBoundsDirty = false,
		_coarseMinX = 0,
		_coarseMinY = 0,
		_coarseMinZ = 0,
		_coarseMaxX = 0,
		_coarseMaxY = 0,
		_coarseMaxZ = 0,
		_occupancyGeneration = 0,
		_updateObjectVoxelsQueue = PriorityQueue.new(),
	}, VoxelGrid)

	return self
end

--[[
	Clips a z-row's [lo, hi] span (measured in voxel steps from the row's first
	voxel) to where the voxel center stays within `reach` of the box along one box
	axis. The center's coordinate down the row is `coord + t * step`, so the test
	|coord + t * step| <= reach is an interval of t that we intersect into [lo, hi].
	When the axis doesn't vary down the row (`varies` is false because the box axis
	is perpendicular to world Z, leaving step ~ 0) the coordinate is constant, so it
	either leaves the whole row eligible or, if it's already out of reach, empties it.
]]
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
		-- It's out of reach for the entire row, so return an empty span (lo > hi).
		return 1, 0
	end

	return lo, hi
end

--[[
	Reports whether a number is finite, meaning it's neither NaN nor an
	infinity. Every NaN comparison is false and these two bounds pin the value
	strictly inside the infinities, so this one pair rejects every non-finite
	value at once.
]]
local function isFinite(value: number): boolean
	return value > -math.huge and value < math.huge
end

--[[
	Recomputes which voxels the object should occupy. That's the cell holding
	its center plus, for an object large enough to span multiple voxels, every
	cell its oriented bounding box truly overlaps. Differences from the object's
	current voxels are recorded in objectData.desiredVoxelKeys (true means
	enter, false means leave) and the object is queued for updateObjectVoxels
	to apply them, prioritized by its distance to the camera. Pass skipQueue when
	the caller applies the returned diff itself this frame, so the object isn't
	queued for the deferred pass that would only dequeue the now-empty diff and
	discard it.
]]
function VoxelGrid.updateDesiredVoxelKeys(
	self: VoxelGrid,
	object: Instance,
	objectData: types.ObjectData,
	skipQueue: boolean?
): { [types.VoxelKey]: boolean }
	debug.profilebegin("updateDesiredVoxelKeys")
	local voxelSize = self._config.voxelSize
	local multiVoxelRadiusThreshold = self._config.multiVoxelRadiusThreshold

	-- The diff table is cleared and reused to avoid allocation churn. That's
	-- safe even while the object sits in the update queue, since the queue
	-- stores only the object and reads this table at dequeue time, so a
	-- recompute simply supersedes the old diff.
	local desiredVoxelKeys = objectData.desiredVoxelKeys
	tableClear(desiredVoxelKeys)

	local cframe, halfBoundingBox = objectData.cframe, objectData.halfBoundingBox
	local position = cframe.Position

	if not (isFinite(position.X) and isFinite(position.Y) and isFinite(position.Z) and isFinite(objectData.radius)) then
		-- A non-finite position or extent poisons the voxel coordinate math. A
		-- NaN can't even be used as a voxel key, and it would feed a NaN into the
		-- queue priority that corrupts the heap's dequeue order, while an infinite
		-- extent makes the multi-voxel fill loop's bounds never advance and hangs
		-- the frame. We leave the object in its current voxels and reslot it once
		-- it has finite geometry again. The diff was cleared above, so returning
		-- it now enqueues nothing.
		return desiredVoxelKeys
	end

	local desiredVoxelKey = position // voxelSize
	desiredVoxelKeys[desiredVoxelKey] = true

	if objectData.radius > multiVoxelRadiusThreshold then
		-- The bounding box is oriented, so we can't just fill its world-space
		-- AABB. For a rotated object that AABB bulges past the box and its corner
		-- voxels would be empty. Instead the AABB only bounds which voxels are
		-- worth checking, and we keep a voxel only if it truly overlaps the box.
		--
		-- Overlap is a separating-axis test against the box's own 3 face axes.
		-- (The 3 world axes are already covered by the AABB candidate range, so
		-- no candidate can be separated along them.) We skip the 9 edge-edge
		-- cross-product axes. Omitting them can only ever over-include, never
		-- wrongly cull, and it leaves at most a thin sliver of corner voxels.
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cframe:GetComponents()
		local hx, hy, hz = halfBoundingBox.X, halfBoundingBox.Y, halfBoundingBox.Z
		local halfVoxel = voxelSize / 2

		-- The box axes in world space are the columns of the rotation matrix:
		-- axisX = (r00, r10, r20), axisY = (r01, r11, r21), axisZ = (r02, r12, r22).
		-- A voxel (an axis-aligned cube) projected onto a box axis reaches
		-- halfVoxel * (|axis.X| + |axis.Y| + |axis.Z|), and adding the box's own
		-- extent gives the separation threshold along that axis.
		local reachX = hx + halfVoxel * (math.abs(r00) + math.abs(r10) + math.abs(r20))
		local reachY = hy + halfVoxel * (math.abs(r01) + math.abs(r11) + math.abs(r21))
		local reachZ = hz + halfVoxel * (math.abs(r02) + math.abs(r12) + math.abs(r22))

		-- The world-space AABB of the oriented box bounds the candidate voxels.
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
		-- row index, so every reach test reduces to an interval of z, and the run
		-- we fill is the integers common to all three intervals.
		--
		-- As the inner loop steps one voxel along world Z, each box-local coordinate
		-- moves by a fixed amount, the world-Z component of that box axis times the
		-- voxel size. We precompute those per-step increments so a row reduces to
		-- lx + t * lxStep (and likewise ly and lz), where t counts steps from the
		-- row's first voxel.
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

				-- These are the box-local coordinates of the row's first voxel center (z = minVoxelKey.Z).
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

	-- Diff the desired set against the current voxels. After this loop the table
	-- holds only the changes, where true means enter that voxel, false means
	-- leave it, and a voxel the object already occupies and keeps drops out of
	-- the table entirely.
	for voxelKey in objectData.voxelKeys do
		if desiredVoxelKeys[voxelKey] then
			desiredVoxelKeys[voxelKey] = nil
		else
			desiredVoxelKeys[voxelKey] = false
		end
	end

	if not skipQueue and next(desiredVoxelKeys) and not self._updateObjectVoxelsQueue:contains(object) then
		-- Manhattan distance to the camera is close enough for ordering the
		-- queue and skips the square root.
		local difference = position - CameraCache.Position
		local priority = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)

		self._updateObjectVoxelsQueue:addToIncomingBatch(object, priority)
	end

	debug.profileend()
	return desiredVoxelKeys
end

--[[
	Adds one object to a voxel's list, creating the voxel when it was empty (and
	registering the fresh voxel in its coarse bucket, growing the occupied
	bounding box as needed). A fresh voxel changes the occupied key set, so the
	occupancy generation moves with it.
]]
function VoxelGrid.insertToVoxel(self: VoxelGrid, voxelKey: types.VoxelKey, objectData: types.ObjectData)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		self._voxels[voxelKey] = { objectData }
		self._occupancyGeneration += 1

		-- This voxel just became occupied, so add it to its coarse bucket.
		local coarseX = voxelKey.X // COARSE_VOXEL_SIZE
		local coarseY = voxelKey.Y // COARSE_VOXEL_SIZE
		local coarseZ = voxelKey.Z // COARSE_VOXEL_SIZE
		local coarseKey = Vector3.new(coarseX, coarseY, coarseZ)
		local bucket = self._coarseVoxels[coarseKey]
		if bucket then
			tableInsert(bucket, voxelKey)
		else
			self._coarseVoxels[coarseKey] = { voxelKey }

			-- Grow the occupied coarse bounding box. While the bounds are dirty
			-- they may be loose, but growing them here keeps them containing every
			-- occupied cell until the lazy recompute tightens them.
			if self._coarseBucketCount == 0 then
				self._coarseMinX, self._coarseMinY, self._coarseMinZ = coarseX, coarseY, coarseZ
				self._coarseMaxX, self._coarseMaxY, self._coarseMaxZ = coarseX, coarseY, coarseZ
				self._coarseBoundsDirty = false
			else
				if coarseX < self._coarseMinX then
					self._coarseMinX = coarseX
				elseif coarseX > self._coarseMaxX then
					self._coarseMaxX = coarseX
				end
				if coarseY < self._coarseMinY then
					self._coarseMinY = coarseY
				elseif coarseY > self._coarseMaxY then
					self._coarseMaxY = coarseY
				end
				if coarseZ < self._coarseMinZ then
					self._coarseMinZ = coarseZ
				elseif coarseZ > self._coarseMaxZ then
					self._coarseMaxZ = coarseZ
				end
			end
			self._coarseBucketCount += 1
		end
	else
		tableInsert(voxel, objectData)
	end
end

--[[
	Removes one object from a voxel's list with an unordered swap-remove. An
	emptied voxel is deleted along with its cached proof, and an emptied coarse
	bucket is dropped along with its cached verdict, dirtying the occupied
	bounding box when the bucket sat on its surface. An emptied voxel changes
	the occupied key set, so the occupancy generation moves with it.
]]
function VoxelGrid.removeFromVoxel(self: VoxelGrid, voxelKey: types.VoxelKey, objectData: types.ObjectData)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		return
	end

	local objectIndex = tableFind(voxel, objectData)
	if not objectIndex then
		return
	end

	local n = #voxel
	if n == 1 then
		self._voxels[voxelKey] = nil
		self._occupancyGeneration += 1
		self._visibilityCache._voxelProofs[voxelKey] = nil

		-- This voxel is no longer occupied, so remove it from its coarse bucket.
		local coarseX = voxelKey.X // COARSE_VOXEL_SIZE
		local coarseY = voxelKey.Y // COARSE_VOXEL_SIZE
		local coarseZ = voxelKey.Z // COARSE_VOXEL_SIZE
		local coarseKey = Vector3.new(coarseX, coarseY, coarseZ)
		local bucket = self._coarseVoxels[coarseKey]
		if bucket then
			local bucketIndex = tableFind(bucket, voxelKey)
			if bucketIndex then
				local bucketN = #bucket
				if bucketN == 1 then
					-- This was the last voxel in this bucket, so drop the bucket
					-- entirely, along with any cached verdict for it.
					self._coarseVoxels[coarseKey] = nil
					self._visibilityCache._bucketVerdicts[coarseKey] = nil
					self._coarseBucketCount -= 1

					-- Only a bucket on the surface of the occupied bounding box can
					-- tighten it. The recompute is deferred to the next seed scan.
					if
						coarseX == self._coarseMinX
						or coarseX == self._coarseMaxX
						or coarseY == self._coarseMinY
						or coarseY == self._coarseMaxY
						or coarseZ == self._coarseMinZ
						or coarseZ == self._coarseMaxZ
					then
						self._coarseBoundsDirty = true
					end
				else
					-- Swap with the last key to avoid shifting the array.
					bucket[bucketIndex] = bucket[bucketN]
					bucket[bucketN] = nil
				end
			end
		end
	elseif n == objectIndex then
		voxel[objectIndex] = nil
	else
		-- To avoid shifting the whole array, we take the
		-- last object and move it to overwrite this one,
		-- since order doesn't matter in this list.
		local lastObject = voxel[n]
		voxel[n] = nil
		voxel[objectIndex] = lastObject
	end
end

--[[
	Applies the voxel membership changes recorded by updateDesiredVoxelKeys,
	closest objects first, until the time budget runs out. Whatever remains
	stays queued for the next frame.
]]
function VoxelGrid.updateObjectVoxels(self: VoxelGrid, timeBudget: number, now: number)
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
				self:insertToVoxel(voxelKey, objectData)
				objectData.voxelKeys[voxelKey] = true
				objectData.desiredVoxelKeys[voxelKey] = nil
			else
				self:removeFromVoxel(voxelKey, objectData)
				objectData.voxelKeys[voxelKey] = nil
				objectData.desiredVoxelKeys[voxelKey] = nil
			end
		end
	end

	debug.profileend()
end

--[[
	Rebuilds the tight bounding box of occupied coarse cells with one pass over
	the occupied buckets. It only runs when a removal may have shrunk the box.
]]
function VoxelGrid.recomputeCoarseBounds(self: VoxelGrid)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for coarseKey in self._coarseVoxels do
		local x, y, z = coarseKey.X, coarseKey.Y, coarseKey.Z
		if x < minX then
			minX = x
		end
		if x > maxX then
			maxX = x
		end
		if y < minY then
			minY = y
		end
		if y > maxY then
			maxY = y
		end
		if z < minZ then
			minZ = z
		end
		if z > maxZ then
			maxZ = z
		end
	end

	self._coarseMinX, self._coarseMinY, self._coarseMinZ = minX, minY, minZ
	self._coarseMaxX, self._coarseMaxY, self._coarseMaxZ = maxX, maxY, maxZ
	self._coarseBoundsDirty = false
end

--[[
	Empties the whole grid by replacing the voxel tables outright, for a voxel
	size change that is about to reslot every object into fresh cells. Every
	object's voxelKeys bookkeeping is emptied to match, since otherwise the
	reslot would diff against voxels that no longer exist and cancel out any
	key that coincides under the old and new sizes, stranding the object
	outside the rebuilt grid. Pending queue entries survive because the reslot
	pass that follows reuses the queue.
]]
function VoxelGrid.clearAll(self: VoxelGrid)
	self._voxels = {}
	self._coarseVoxels = {}
	self._coarseBucketCount = 0
	self._coarseBoundsDirty = false
	self._occupancyGeneration += 1

	for _, objectData in self._objects do
		tableClear(objectData.voxelKeys)
	end
end

--[[
	Clears the grid and its pending update queue so everything it referenced
	can be garbage collected.
]]
function VoxelGrid.destroy(self: VoxelGrid)
	tableClear(self._voxels)
	tableClear(self._coarseVoxels)
	self._coarseBucketCount = 0
	self._coarseBoundsDirty = false
	self._occupancyGeneration += 1
	self._updateObjectVoxelsQueue:clearIncomingBatch()
	self._updateObjectVoxelsQueue:clear()
end

return VoxelGrid
