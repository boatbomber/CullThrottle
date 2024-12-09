--!strict
--!optimize 2
--!native

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

if RunService:IsServer() and not RunService:IsEdit() then
	error("CullThrottle is a client side effect and cannot be used on the server")
end

local types = require(script.types)
local PriorityQueue = require(script.PriorityQueue)
local Config = require(script.Config)
local GoodSignal = require(script.Utilities.GoodSignal)
local ObjectDimensions = require(script.Utilities.ObjectDimensions)
local CameraCache = require(script.Utilities.CameraCache)

local EPSILON = 1e-4
local P0_THRESHOLD = 0.90
local RESIZE_TABLES_RATE = 5
local SKIPPED_FRAMES_LOOKBACK = 4
local LAST_VISIBILITY_GRACE_PERIOD = 0.2
local NEARBY_DISTANCE_THRESHOLD = 30

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

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type CullThrottleProto = {
	ObjectEnteredView: any, -- TODO: Anyone got strict typing for GoodSignal?
	ObjectExitedView: any,

	_config: Config.Config,
	_voxels: { [types.VoxelKey]: types.Voxel },
	_objects: { [Instance]: types.ObjectData },
	_physicsObjects: { Instance },
	_updateObjectVoxelsQueue: PriorityQueue.PriorityQueue,
	_visibleObjectsQueue: PriorityQueue.PriorityQueue,
	_visibleVoxelKeys: { types.VoxelKey },
	_objectVisibilityTimestamps: { [Instance]: number },
	_physicsObjectIterIndex: number,
	_lastTableResize: number,
	_lastVoxelVisibility: { [types.VoxelKey]: number },
	_tagConnections: { [string]: { RBXScriptConnection } },
	_renderConnection: RBXScriptConnection,
	_processedVisibilityThisFrame: boolean,
	_volumesToCheck: { types.Volume },
	_numberOfVolumesToCheck: number,

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

function CullThrottle._resizeTables(self: CullThrottle)
	-- We've got a couple arrays that we clear without shrinking their size
	-- so we occasionally resize them to avoid wasting space
	local visibleVoxelKeys = table.create(#self._visibleVoxelKeys)
	table.move(self._visibleVoxelKeys, 1, #self._visibleVoxelKeys, 1, visibleVoxelKeys)
	self._visibleVoxelKeys = visibleVoxelKeys

	local volumesToCheck = table.create(#self._volumesToCheck)
	table.move(self._volumesToCheck, 1, #self._volumesToCheck, 1, volumesToCheck)
	self._volumesToCheck = volumesToCheck
end

function CullThrottle._addVoxelKeyToVisible(self: CullThrottle, voxelKey: types.VoxelKey)
	-- Sort by voxelKeys by manhattan distance to camera in voxel space
	local voxelSize = self._config.voxelSize
	local cameraVoxelKey = CameraCache.Position // voxelSize
	local difference = voxelKey - cameraVoxelKey
	local manhattanDist = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)

	local visibleVoxelKeys = self._visibleVoxelKeys
	local left = 1
	local right = #visibleVoxelKeys

	while left <= right do
		local mid = math.floor((left + right) / 2)
		local otherVoxelKey = visibleVoxelKeys[mid]
		if otherVoxelKey == voxelKey then
			return
		end

		local otherDifference = otherVoxelKey - cameraVoxelKey
		local otherManhattanDist = math.abs(otherDifference.X)
			+ math.abs(otherDifference.Y)
			+ math.abs(otherDifference.Z)

		if otherManhattanDist < manhattanDist then
			left = mid + 1
		else
			right = mid - 1
		end
	end

	table.insert(visibleVoxelKeys, left, voxelKey)
end

function CullThrottle._updateDesiredVoxelKeys(
	self: CullThrottle,
	object: Instance,
	objectData: types.ObjectData
): { [types.VoxelKey]: boolean }
	local voxelSize = self._config.voxelSize
	local radiusThresholdForCorners = self._config._radiusThresholdForCorners
	local desiredVoxelKeys = {}

	-- We'll get the voxelKeys for the center and the 8 corners of the object
	local cframe, halfBoundingBox = objectData.cframe, objectData.halfBoundingBox
	local position = cframe.Position

	local desiredVoxelKey = position // voxelSize
	desiredVoxelKeys[desiredVoxelKey] = true

	if objectData.radius > radiusThresholdForCorners then
		-- Object is large enough that we need to consider the corners as well
		local corners = {
			(cframe * CFrame.new(halfBoundingBox.X, halfBoundingBox.Y, halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(-halfBoundingBox.X, -halfBoundingBox.Y, -halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(-halfBoundingBox.X, halfBoundingBox.Y, halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(-halfBoundingBox.X, -halfBoundingBox.Y, halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(-halfBoundingBox.X, halfBoundingBox.Y, -halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(halfBoundingBox.X, halfBoundingBox.Y, -halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(halfBoundingBox.X, -halfBoundingBox.Y, -halfBoundingBox.Z)).Position,
			(cframe * CFrame.new(halfBoundingBox.X, -halfBoundingBox.Y, halfBoundingBox.Z)).Position,
		}

		for _, corner in corners do
			local voxelKey = corner // voxelSize
			desiredVoxelKeys[voxelKey] = true
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

	objectData.desiredVoxelKeys = desiredVoxelKeys

	if next(desiredVoxelKeys) and not self._updateObjectVoxelsQueue:contains(object) then
		-- Use a cheap manhattan distance check for priority
		local difference = position - CameraCache.Position
		local priority = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)

		self._updateObjectVoxelsQueue:addToIncomingBatch(object, priority)
	end

	return desiredVoxelKeys
end

function CullThrottle._insertToVoxel(self: CullThrottle, voxelKey: types.VoxelKey, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		-- New voxel, init the list with this object inside
		self._voxels[voxelKey] = { object }
	else
		-- Existing voxel, add this object to its list
		table.insert(voxel, object)
	end
end

function CullThrottle._removeFromVoxel(self: CullThrottle, voxelKey: types.VoxelKey, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		return
	end

	local objectIndex = table.find(voxel, object)
	if not objectIndex then
		return
	end

	local n = #voxel
	if n == 1 then
		-- Lets just cleanup this now empty voxel instead
		self._voxels[voxelKey] = nil
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
	local startIndex = self._physicsObjectIterIndex

	if #self._physicsObjects == 0 then
		debug.profileend()
		return
	end

	local cameraPos = CameraCache.Position
	while os.clock() - now < timeBudget do
		local object = self._physicsObjects[self._physicsObjectIterIndex]
		self._physicsObjectIterIndex = self._physicsObjectIterIndex % #self._physicsObjects + 1

		if not object then
			continue
		end

		local objectData = self._objects[object]
		if not objectData then
			warn("Physics object", object, "is missing objectData, this shouldn't happen!")
			continue
		end

		-- Update the object's cframe
		local cframe = ObjectDimensions.getObjectCFrame(objectData)
		if cframe then
			objectData.cframe = cframe
			objectData.distance = (cframe.Position - cameraPos).Magnitude
			self:_updateDesiredVoxelKeys(object, objectData)
		end

		if startIndex == self._physicsObjectIterIndex then
			-- We've looped through the entire list, no need to continue
			break
		end
	end
	debug.profileend()
end

function CullThrottle._areBoundsInFrustum(
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
	debug.profilebegin("areBoundsInFrustum")

	-- IMPORTANT: Ensure x0 <= x1, y0 <= y1, z0 <= z1 or this math is gonna be wrong

	-- Convert volume to world coordinates
	local voxelSize = self._config.voxelSize
	local x0W, x1W = x0 * voxelSize, x1 * voxelSize
	local y0W, y1W = y0 * voxelSize, y1 * voxelSize
	local z0W, z1W = z0 * voxelSize, z1 * voxelSize

	-- Define the volume center and half-extents
	local center = Vector3.new((x0W + x1W) / 2, (y0W + y1W) / 2, (z0W + z1W) / 2)
	local extentsX, extentsY, extentsZ = (x1W - x0W) / 2, (y1W - y0W) / 2, (z1W - z0W) / 2

	local completelyInside = true

	-- Check each frustum plane
	for i = 1, #frustumPlanes, 2 do
		local planePos, planeNormal = frustumPlanes[i], frustumPlanes[i + 1]

		-- Compute the distance from volume center to the plane
		local dist = (center - planePos):Dot(planeNormal)

		-- Compute the projection interval radius of volume onto the plane normal
		local radius = math.abs(extentsX * planeNormal.X)
			+ math.abs(extentsY * planeNormal.Y)
			+ math.abs(extentsZ * planeNormal.Z)

		-- If the distance is greater than the radius, the volume is outside the frustum
		if dist > radius + EPSILON then
			debug.profileend()
			return false, false
		end

		-- If the distance plus the radius is positive, the volume is not completely inside this plane
		if checkForCompletelyInside and dist + radius > EPSILON then
			completelyInside = false
		end
	end

	-- If we've made it here, the box is either inside or intersecting the frustum
	debug.profileend()
	return true, completelyInside
end

function CullThrottle._ingestVoxel(self: CullThrottle, now: number, voxel: types.Voxel)
	local cameraPos = CameraCache.Position
	local renderDistance = self._config._renderDistance
	local bestRefreshRate = self._config.bestRefreshRate
	local worstRefreshRate = self._config.worstRefreshRate
	local refreshRateRange = self._config._refreshRateRange

	local objectVisibilityTimestamps = self._objectVisibilityTimestamps

	for _, object in voxel do
		local objectData = self._objects[object]
		if not objectData then
			continue
		end

		if objectData.lastCheckClock == now then
			-- Avoid duplicate checks on this object
			continue
		end
		objectData.lastCheckClock = now

		local distance = (objectData.cframe.Position - cameraPos).Magnitude
		objectData.distance = distance
		if distance > renderDistance then
			-- Object is outside what we consider visible
			continue
		end

		local screenSize = ObjectDimensions.getScreenSize(distance, objectData.radius)
		local elapsed = now - objectData.lastUpdateClock
		local jitteredElapsed = elapsed + objectData.jitterOffset

		local objectPriority = 0

		if jitteredElapsed <= bestRefreshRate then
			-- No need to refresh faster than our best rate
			-- so make this super low priority
			objectPriority = (1 - screenSize) * 1e6
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

		self._visibleObjectsQueue:addToIncomingBatch(object, objectPriority)

		if objectVisibilityTimestamps[object] == nil then
			-- This object wasn't visible last frame but it is now
			self.ObjectEnteredView:Fire(object)
		end
		objectVisibilityTimestamps[object] = now
	end
end

function CullThrottle._fastApproxIngestRemainingVoxels(self: CullThrottle, now: number, startIndex: number)
	local voxels = self._voxels
	local visibleVoxelKeys = self._visibleVoxelKeys
	local objectVisibilityTimestamps = self._objectVisibilityTimestamps

	for voxelIndex = startIndex, #visibleVoxelKeys do
		-- Just dump all the objects into the visible objects list
		local voxelKey = visibleVoxelKeys[voxelIndex]
		local voxel = voxels[voxelKey]
		if not voxel then
			continue
		end

		self._visibleObjectsQueue:addMultipleToIncomingBatch(voxel, table.create(#voxel, voxelIndex * 1e4))

		for _, object in voxel do
			if objectVisibilityTimestamps[object] == nil then
				-- This object wasn't visible last frame but it is now
				self.ObjectEnteredView:Fire(object)
			end
			objectVisibilityTimestamps[object] = now
		end
	end

	self._perfMetrics._skippedIngest[1] = 1 + #visibleVoxelKeys - startIndex
end

function CullThrottle._createVolumeFromBounds(
	self: CullThrottle,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): types.Volume
	return {
		x0,
		y0,
		z0,
		x1,
		y1,
		z1,
		self:_getVoxelKeysContainedInBounds(x0, y0, z0, x1, y1, z1),
	}
end

function CullThrottle._splitContainedVoxelKeysByBounds(
	_self: CullThrottle,
	containedVoxelKeys: { Vector3 },
	x0A: number, -- Parameter spam is gross, but makes a real perf difference in this hot path
	y0A: number,
	z0A: number,
	x1A: number,
	y1A: number,
	z1A: number,
	x0B: number,
	y0B: number,
	z0B: number,
	x1B: number,
	y1B: number,
	z1B: number
): ({ Vector3 }, { Vector3 })
	debug.profilebegin("splitContainedVoxelKeysByBounds")
	local containsA, containsAIndex = {}, 0
	local containsB, containsBIndex = {}, 0

	for _, voxelKey in containedVoxelKeys do
		local x, y, z = voxelKey.X, voxelKey.Y, voxelKey.Z
		if x >= x0A and x < x1A and y >= y0A and y < y1A and z >= z0A and z < z1A then
			containsAIndex += 1
			containsA[containsAIndex] = voxelKey
		elseif x >= x0B and x < x1B and y >= y0B and y < y1B and z >= z0B and z < z1B then
			containsBIndex += 1
			containsB[containsBIndex] = voxelKey
		end
	end

	debug.profileend()
	return containsA, containsB
end

function CullThrottle._getVoxelKeysContainedInBounds(
	self: CullThrottle,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): { Vector3 }
	debug.profilebegin("getVoxelKeysContainedInBounds")

	-- I've tried using octrees & kdtrees to get all voxelKeys contained in the volume,
	-- but somehow just iterating through all the voxels is faster.
	local voxels = self._voxels

	local totalPossibleVoxels = (x1 - x0) * (y1 - y0) * (z1 - z0)
	local containedVoxelKeys = table.create(totalPossibleVoxels // 10)
	for x = x0, x1 - 1 do
		for y = y0, y1 - 1 do
			for z = z0, z1 - 1 do
				local voxelKey = Vector3.new(x, y, z)
				if not voxels[voxelKey] then
					continue
				end

				table.insert(containedVoxelKeys, Vector3.new(x, y, z))
			end
		end
	end

	debug.profileend()
	return containedVoxelKeys
end

function CullThrottle._insertVolumeToCheck(self: CullThrottle, volume: types.Volume)
	if #volume[7] == 0 then
		-- No voxels in this volume, no need to check it
		return
	end

	self._numberOfVolumesToCheck += 1
	self._volumesToCheck[self._numberOfVolumesToCheck] = volume
end

function CullThrottle._searchBounds(
	self: CullThrottle,
	now: number,
	frustumPlanes: { Vector3 },
	containedVoxelKeys: { types.VoxelKey },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
)
	local isSingleVoxel = x1 - x0 == 1 and y1 - y0 == 1 and z1 - z0 == 1
	local lastVoxelVisibility = self._lastVoxelVisibility

	local JITTERED_LAST_VISIBILITY_GRACE_PERIOD = LAST_VISIBILITY_GRACE_PERIOD * (1 + (math.random() * 0.1 - 0.05))

	-- Special case for volumes of a single voxel
	if isSingleVoxel then
		local voxelKey = containedVoxelKeys[1]

		if now - (lastVoxelVisibility[voxelKey] or 0) < JITTERED_LAST_VISIBILITY_GRACE_PERIOD then
			-- If this voxel was visible a moment ago, assume it still is
			self:_addVoxelKeyToVisible(voxelKey)
			return
		end

		if self:_areBoundsInFrustum(false, frustumPlanes, x0, y0, z0, x1, y1, z1) then
			-- Voxel is currently visible
			lastVoxelVisibility[voxelKey] = now
			self:_addVoxelKeyToVisible(voxelKey)
		else
			-- Not visible anymore, clear the cache
			lastVoxelVisibility[voxelKey] = nil
		end

		return
	end

	debug.profilebegin("checkBoxVisibilityCache")
	local allVoxelsVisible = true
	for _, voxelKey in containedVoxelKeys do
		if now - (lastVoxelVisibility[voxelKey] or 0) >= JITTERED_LAST_VISIBILITY_GRACE_PERIOD then
			allVoxelsVisible = false
			break
		end
	end
	debug.profileend()

	-- If all voxels in this volume were visible a moment ago, just assume they still are
	if allVoxelsVisible then
		debug.profilebegin("allVoxelsVisible")
		for _, voxelKey in containedVoxelKeys do
			self:_addVoxelKeyToVisible(voxelKey)
		end
		debug.profileend()
		return
	end

	-- Alright, we actually do need to check if this volume is visible
	local isInside, isCompletelyInside = self:_areBoundsInFrustum(true, frustumPlanes, x0, y0, z0, x1, y1, z1)

	if not isInside then
		-- This volume is completely outside, so we can stop checking now
		debug.profilebegin("clearBoxVisibilityCache")
		for _, voxelKey in containedVoxelKeys do
			lastVoxelVisibility[voxelKey] = nil
		end
		debug.profileend()
	elseif isCompletelyInside then
		-- This volume is completely inside, so all contained voxels are visible
		debug.profilebegin("isCompletelyInside")
		for _, voxelKey in containedVoxelKeys do
			lastVoxelVisibility[voxelKey] = now
			self:_addVoxelKeyToVisible(voxelKey)
		end
		debug.profileend()
	else
		-- This volume is partially inside, so we need to split it up further
		-- to determine which voxels within it are the ones inside
		-- Calculate the lengths of each axis
		local lengthX = x1 - x0
		local lengthY = y1 - y0
		local lengthZ = z1 - z0

		-- Split along the axis with the greatest length
		local volumeA: types.Volume, volumeB: types.Volume
		if lengthX >= lengthY and lengthX >= lengthZ then
			local splitCoord = (x0 + x1) // 2

			volumeA = { x0, y0, z0, splitCoord, y1, z1 }
			volumeB = { splitCoord, y0, z0, x1, y1, z1 }
		elseif lengthY >= lengthX and lengthY >= lengthZ then
			local splitCoord = (y0 + y1) // 2
			volumeA = { x0, y0, z0, x1, splitCoord, z1 }
			volumeB = { x0, splitCoord, z0, x1, y1, z1 }
		else
			local splitCoord = (z0 + z1) // 2
			volumeA = { x0, y0, z0, x1, y1, splitCoord }
			volumeB = { x0, y0, splitCoord, x1, y1, z1 }
		end

		-- Divy up the contained voxel keys into the two new volumes
		-- (Cheaper than recalculating all the voxel keys contained in each volume)
		local containedA, containedB = self:_splitContainedVoxelKeysByBounds(
			containedVoxelKeys,
			volumeA[1],
			volumeA[2],
			volumeA[3],
			volumeA[4],
			volumeA[5],
			volumeA[6],
			volumeB[1],
			volumeB[2],
			volumeB[3],
			volumeB[4],
			volumeB[5],
			volumeB[6]
		)

		volumeA[7] = containedA
		volumeB[7] = containedB

		-- Randomize order to avoid worst case where only the first volume
		-- gets checked before the budget is up
		if math.random(1, 2) == 1 then
			self:_insertVolumeToCheck(volumeA)
			self:_insertVolumeToCheck(volumeB)
		else
			self:_insertVolumeToCheck(volumeB)
			self:_insertVolumeToCheck(volumeA)
		end
	end
end

function CullThrottle._reuseCachedVisibilityForRemainingVolumes(self: CullThrottle)
	local lastVoxelVisibility = self._lastVoxelVisibility

	local skipped = 0

	for _, volume in self._volumesToCheck do
		-- Run through the voxels contained in this volume
		for _, voxelKey in volume[7] do
			skipped += 1
			if lastVoxelVisibility[voxelKey] then
				self:_addVoxelKeyToVisible(voxelKey)
			end
		end
	end

	self._perfMetrics._skippedSearch[1] = skipped
end

function CullThrottle._clearVisibleObjects(self: CullThrottle)
	table.clear(self._visibleVoxelKeys)
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

	for object, lastSeen in objectVisibilityTimestamps do
		if lastSeen ~= now then
			-- Object was visible last frame but not this frame
			objectVisibilityTimestamps[object] = nil
			self.ObjectExitedView:Fire(object)
		end
	end

	debug.profileend()
end

function CullThrottle._findVisibleObjects(self: CullThrottle, now: number)
	debug.profilebegin("findVisibleObjects")
	debug.profilebegin("setup")

	-- Clear any objects left over from last frame
	self:_clearVisibleObjects()

	self._perfMetrics._skippedIngest[SKIPPED_FRAMES_LOOKBACK] = nil
	self._perfMetrics._skippedSearch[SKIPPED_FRAMES_LOOKBACK] = nil
	table.insert(self._perfMetrics._skippedIngest, 1, 0)
	table.insert(self._perfMetrics._skippedSearch, 1, 0)

	local searchTimeBudget = self._config.searchTimeBudget
	local ingestTimeBudget = self._config.ingestTimeBudget
	local voxelSize = self._config.voxelSize
	local renderDistance = self._config._renderDistance

	local frustumPlanes, minBound, maxBound = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

	local minX = minBound.X
	local minY = minBound.Y
	local minZ = minBound.Z
	local maxX = maxBound.X + 1
	local maxY = maxBound.Y + 1
	local maxZ = maxBound.Z + 1

	local volumesToCheck = self._volumesToCheck
	table.clear(volumesToCheck)
	self._numberOfVolumesToCheck = 0

	-- Split into smaller boxes to start off since the frustum bounding volume
	-- obviously intersects the frustum planes.
	if minX == maxX or minY == maxY or minZ == maxZ then
		-- If the bounds are not divisible then don't split early
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(minX, minY, minZ, maxX, maxY, maxZ))
	else
		local midBound = (minBound + maxBound) // 2
		local midX = midBound.X
		local midY = midBound.Y
		local midZ = midBound.Z

		self:_insertVolumeToCheck(self:_createVolumeFromBounds(minX, minY, minZ, midX, midY, midZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(midX, minY, minZ, maxX, midY, midZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(minX, minY, midZ, midX, midY, maxZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(midX, minY, midZ, maxX, midY, maxZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(minX, midY, minZ, midX, maxY, midZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(midX, midY, minZ, maxX, maxY, midZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(minX, midY, midZ, midX, maxY, maxZ))
		self:_insertVolumeToCheck(self:_createVolumeFromBounds(midX, midY, midZ, maxX, maxY, maxZ))

		-- Shuffle the quandrant volumes to avoid a worst-case where
		-- only the first volume is checked before budget is up
		for i = self._numberOfVolumesToCheck, 2, -1 do
			local j = math.random(1, i)
			volumesToCheck[i], volumesToCheck[j] = volumesToCheck[j], volumesToCheck[i]
		end
	end

	local voxels = self._voxels

	debug.profileend()
	debug.profilebegin("searchVolumes")
	while self._numberOfVolumesToCheck > 0 do
		-- TODO: Workers pop volumes from the list and check them in parallel

		local n = self._numberOfVolumesToCheck
		local volume = self._volumesToCheck[n]
		self._volumesToCheck[n] = nil
		self._numberOfVolumesToCheck -= 1

		-- Search the volume for visible voxels
		self:_searchBounds(
			now,
			frustumPlanes,
			volume[7],
			volume[1],
			volume[2],
			volume[3],
			volume[4],
			volume[5],
			volume[6]
		)

		if os.clock() - now >= searchTimeBudget then
			-- We've run out of time!
			debug.profilebegin("reuseCachedVisibilityForRemainingVolumes")
			self:_reuseCachedVisibilityForRemainingVolumes()
			debug.profileend()
			break
		end
	end
	self._perfMetrics._searchDuration = os.clock() - now
	debug.profileend()

	debug.profilebegin("ingestVoxels")
	local visibleVoxelKeys = self._visibleVoxelKeys
	local startIngestClock = os.clock()
	for voxelIndex, voxelKey in visibleVoxelKeys do
		local voxel = voxels[voxelKey]
		if not voxel then
			continue
		end

		self:_ingestVoxel(now, voxel)

		if os.clock() - startIngestClock >= ingestTimeBudget then
			-- We've run out of time!
			debug.profilebegin("fastApproxIngestRemainingVoxels")
			self:_fastApproxIngestRemainingVoxels(now, voxelIndex + 1)
			debug.profileend()
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

	if
		self._perfMetrics._getAverage(self._perfMetrics._skippedIngest) ~= 0
		or self._perfMetrics._getAverage(self._perfMetrics._skippedSearch) ~= 0 -- We're not able to truly process all the voxels
		or self._perfMetrics._averageObjectDeltaTime >= self._config._refreshRateMidpoint -- We're not refreshing fast enough
		or self._perfMetrics._searchDuration / self._config.searchTimeBudget > 1
		or self._perfMetrics._ingestDuration / self._config.ingestTimeBudget > 1 -- We're going over the time budget
	then
		self._config._renderDistance = math.max(
			self._config._renderDistance - (self._config.renderDistanceTarget * 0.03),
			self._config._minRenderDistance
		)
	elseif self._perfMetrics._averageObjectDeltaTime <= self._config.bestRefreshRate then
		-- We're doing amazing, we can take on more
		self._config._renderDistance = math.min(
			self._config._renderDistance + (self._config.renderDistanceTarget * 0.015),
			self._config._maxRenderDistance
		)
	end
end

function CullThrottle._processObjectVisibility(self: CullThrottle, start: number)
	if self._processedVisibilityThisFrame then
		-- Already processed!
		return
	end

	debug.profilebegin("CullThrottle.processObjectVisibility")

	-- Make sure our voxels are up to date for up to 0.1 ms
	self:_pollPhysicsObjects(5e-5, start)
	self:_updateObjectVoxels(5e-5, os.clock())

	-- Find the objects that are visible this frame
	self:_findVisibleObjects(start)

	-- Signal the visibility changes to the event handler
	self:_signalVisibilityChanges(start)

	-- Adjust dynamic render distance to hit the budgets
	self:_adjustDynamicRenderDistance()

	self._processedVisibilityThisFrame = true
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

	self._perfMetrics = {
		_skippedSearch = table.create(SKIPPED_FRAMES_LOOKBACK, 0),
		_skippedIngest = table.create(SKIPPED_FRAMES_LOOKBACK, 0),
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
	self._objects = {}
	self._physicsObjects = {}
	self._physicsObjectIterIndex = 1
	self._updateObjectVoxelsQueue = PriorityQueue.new()
	self._visibleObjectsQueue = PriorityQueue.new()
	self._visibleVoxelKeys = {}
	self._objectVisibilityTimestamps = {}
	self._lastVoxelVisibility = {}
	self._lastTableResize = os.clock()
	self._processedVisibilityThisFrame = false
	self._volumesToCheck = table.create(8)
	self._numberOfVolumesToCheck = 0
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

function CullThrottle.AddObject(self: CullThrottle, object: Instance)
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
	objectData.distance = (CameraCache.Position - cframe.Position).Magnitude

	local boundingBox = ObjectDimensions.getObjectBoundingBox(objectData)
	if not boundingBox then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	objectData.halfBoundingBox = boundingBox / 2
	objectData.radius = math.max(boundingBox.X, boundingBox.Y, boundingBox.Z) / 2

	ObjectDimensions.subscribeToDimensionChanges(objectData, function(newCFrame: CFrame)
		-- Update CFrame
		objectData.cframe = newCFrame
		objectData.distance = (newCFrame.Position - CameraCache.Position).Magnitude
		self:_updateDesiredVoxelKeys(object, objectData)
	end, function(newBoundingBox: Vector3)
		-- Update bounding box and radius
		objectData.halfBoundingBox = newBoundingBox / 2
		objectData.radius = math.max(newBoundingBox.X, newBoundingBox.Y, newBoundingBox.Z) / 2

		self:_updateDesiredVoxelKeys(object, objectData)
	end)
	self:_updateDesiredVoxelKeys(object, objectData)

	self._objects[object] = objectData

	for voxelKey, desired in objectData.desiredVoxelKeys do
		if desired then
			self:_insertToVoxel(voxelKey, object)
			objectData.voxelKeys[voxelKey] = true
			objectData.desiredVoxelKeys[voxelKey] = nil
		end
	end

	return objectData
end

function CullThrottle.AddPhysicsObject(self: CullThrottle, object: BasePart)
	self:AddObject(object)

	-- Also add it to the physics objects table for polling position changes
	-- (physics based movement doesn't trigger the normal connection)
	table.insert(self._physicsObjects, object)
end

function CullThrottle.RemoveObject(self: CullThrottle, object: Instance)
	local objectData = self._objects[object]
	if not objectData then
		return
	end

	self._objects[object] = nil

	local physicsObjectIndex = table.find(self._physicsObjects, object)
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
end

function CullThrottle.CaptureTag(self: CullThrottle, tag: string)
	self._tagConnections[tag] = {
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(object: Instance)
			if object:IsA("BasePart") and object.Anchored == false then
				self:AddPhysicsObject(object)
			else
				self:AddObject(object)
			end
		end),
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(object: Instance)
			self:RemoveObject(object)
		end),
	}

	for _, object in CollectionService:GetTagged(tag) do
		if object:IsA("BasePart") and object.Anchored == false then
			self:AddPhysicsObject(object)
		else
			self:AddObject(object)
		end
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
end

function CullThrottle.RemoveObjectsWithTag(self: CullThrottle, tag: string)
	for object in self._objects do
		if object:HasTag(tag) then
			self:RemoveObject(object)
		end
	end
end

function CullThrottle.GetVisibleObjects(self: CullThrottle): { Instance }
	-- Process visibility if we haven't already processed this frame yet
	self:_processObjectVisibility(os.clock())

	return table.clone(self._visibleObjectsQueue._incomingBatch.items)
end

function CullThrottle.IterateObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?, number?)
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

	return function()
		if queue:isEmpty() then
			debug.profileend()

			self._perfMetrics._averageObjectDeltaTime = sumOfObjectDeltaTimes / updatedObjects
			return
		end

		local budget = if queue:peekPriority() < P0_THRESHOLD then p0UpdateTimeBudget else updateTimeBudget
		if os.clock() - updateStartClock >= budget then
			-- Out of time, can't update the rest this frame.
			-- That's okay, they'll be higher priority next time.

			-- Just in case the user iterates multiple times in a single frame,
			-- lets clear out the leftovers so they don't spill into the second iter
			self._visibleObjectsQueue:clear()

			debug.profileend()

			self._perfMetrics._averageObjectDeltaTime = sumOfObjectDeltaTimes / updatedObjects
			return
		end

		local object = queue:dequeue()
		if not object then
			debug.profileend()

			self._perfMetrics._averageObjectDeltaTime = sumOfObjectDeltaTimes / updatedObjects
			return
		end

		local objectData = self._objects[object]
		if not objectData then
			debug.profileend()

			self._perfMetrics._averageObjectDeltaTime = sumOfObjectDeltaTimes / updatedObjects
			return
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

		return object, objectDeltaTime, objectData.distance
	end
end

function CullThrottle.SetVoxelSize(self: CullThrottle, voxelSize: number)
	self._config.voxelSize = voxelSize
	self._config._halfVoxelSizeVec = Vector3.one * (voxelSize / 2)
	self._config._radiusThresholdForCorners = voxelSize * (1 / 8)

	-- We need to move all the objects around to their new voxels
	self._voxels = {}

	for object, objectData in self._objects do
		self:_updateDesiredVoxelKeys(object, objectData)
	end

	self:_updateObjectVoxels(5, os.clock())
end

function CullThrottle.SetRenderDistanceTarget(self: CullThrottle, renderDistanceTarget: number)
	self._config.renderDistanceTarget = renderDistanceTarget
	self._config._renderDistance = renderDistanceTarget
	self._config._minRenderDistance = renderDistanceTarget / 3
	self._config._maxRenderDistance = renderDistanceTarget * 5
end

function CullThrottle.SetTimeBudgets(
	self: CullThrottle,
	searchTimeBudget: number,
	ingestTimeBudget: number,
	updateTimeBudget: number
)
	self._config.searchTimeBudget = searchTimeBudget
	self._config.ingestTimeBudget = ingestTimeBudget
	self._config.updateTimeBudget = updateTimeBudget
end

function CullThrottle.SetRefreshRates(self: CullThrottle, best: number, worst: number)
	if best > 2 then
		best = 1 / best
	end
	if worst > 2 then
		worst = 1 / worst
	end

	self._config.bestRefreshRate = best
	self._config.worstRefreshRate = worst
	self._config._refreshRateRange = worst - best
	self._config._refreshRateMidpoint = (worst + best) / 2
end

function CullThrottle.SetComputeVisibilityOnlyOnDemand(self: CullThrottle, computeVisibilityOnlyOnDemand: boolean)
	self._config.computeVisibilityOnlyOnDemand = computeVisibilityOnlyOnDemand
end

function CullThrottle.SetStrictlyEnforcedWorstRefreshRate(self: CullThrottle, strictlyEnforceWorstRefreshRate: boolean)
	self._config.strictlyEnforceWorstRefreshRate = strictlyEnforceWorstRefreshRate
end

function CullThrottle.SetDynamicRenderDistance(self: CullThrottle, dynamicRenderDistance: boolean)
	self._config.dynamicRenderDistance = dynamicRenderDistance
end

return CullThrottle
