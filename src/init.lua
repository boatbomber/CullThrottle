--!strict
--!optimize 2

local RunService = game:GetService("RunService")

if RunService:IsServer() and not RunService:IsEdit() then
	error("CullThrottle is a client side effect and cannot be used on the server")
end

local PriorityQueue = require(script.PriorityQueue)
local CameraCache = require(script.CameraCache)
local Utility = require(script.Utility)

local EPSILON = 1e-4
local LAST_VISIBILITY_GRACE_PERIOD = 0.15
local MIN_SCREEN_SIZE = 1 / 100
local MAX_SCREEN_SIZE = 10 / 100
local SCREEN_SIZE_RANGE = MAX_SCREEN_SIZE - MIN_SCREEN_SIZE

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type ObjectData = {
	cframe: CFrame,
	halfBoundingBox: Vector3,
	radius: number,
	voxelKeys: { [Vector3]: true },
	desiredVoxelKeys: { [Vector3]: boolean },
	lastCheckClock: number,
	lastUpdateClock: number,
	jitterOffset: number,
	changeConnections: { RBXScriptConnection },
}

type CullThrottleProto = {
	DEBUG_MODE: boolean,
	_bestRefreshRate: number,
	_worstRefreshRate: number,
	_refreshRateRange: number,
	_renderDistance: number,
	_targetPerformanceTime: number,
	_performanceFalloffFactor: number,
	_voxelSize: number,
	_halfVoxelSizeVec: Vector3,
	_radiusThresholdForCorners: number,
	_voxels: { [Vector3]: { Instance } },
	_objects: { [Instance]: ObjectData },
	_physicsObjects: { Instance },
	_objectRefreshQueue: PriorityQueue.PriorityQueue,
	_physicsObjectIterIndex: number,
	_vertexVisibilityCache: { [Vector3]: boolean },
	_lastVoxelVisibility: { [Vector3]: number },
	_lastCallTimes: { number },
	_lastCallTimeIndex: number,
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

function CullThrottle.new(): CullThrottle
	local self = setmetatable({}, CullThrottle)

	self.DEBUG_MODE = false

	self._voxelSize = 75
	self._halfVoxelSizeVec = Vector3.one * (self._voxelSize / 2)
	self._radiusThresholdForCorners = self._voxelSize * (1 / 8)
	self._renderDistance = 450
	self._targetPerformanceTime = 1.5 / 1000 -- 1.5ms default
	self._bestRefreshRate = 1 / 45
	self._worstRefreshRate = 1 / 15
	self._refreshRateRange = self._worstRefreshRate - self._bestRefreshRate
	self._performanceFalloffFactor = 1
	self._voxels = {}
	self._objects = {}
	self._physicsObjects = {}
	self._physicsObjectIterIndex = 1
	self._objectRefreshQueue = PriorityQueue.new()
	self._vertexVisibilityCache = {}
	self._lastVoxelVisibility = {}
	self._lastCallTimes = table.create(5, 0)
	self._lastCallTimeIndex = 1

	return self
end

function CullThrottle._getAverageCallTime(self: CullThrottle): number
	local sum = 0
	for _, callTime in self._lastCallTimes do
		sum += callTime
	end
	return sum / #self._lastCallTimes
end

function CullThrottle._addCallTime(self: CullThrottle, start: number)
	local callTime = os.clock() - start
	self._lastCallTimes[self._lastCallTimeIndex] = callTime
	self._lastCallTimeIndex = (self._lastCallTimeIndex % 5) + 1
end

function CullThrottle._updatePerformanceFalloffFactor(self: CullThrottle): number
	local averageCallTime = self:_getAverageCallTime()
	local targetCallTime = self._targetPerformanceTime
	local adjustmentFactor = averageCallTime / targetCallTime

	if adjustmentFactor > 1 then
		-- We're overbudget, increase falloff (max 2)
		self._performanceFalloffFactor =
			math.min(self._performanceFalloffFactor * (1 + (adjustmentFactor - 1) * 0.5), 2)
	else
		-- We have extra budget, decrease falloff (min 0.5)
		self._performanceFalloffFactor =
			math.max(self._performanceFalloffFactor * (1 - (1 - adjustmentFactor) * 0.5), 0.5)
	end

	return self._performanceFalloffFactor
end

function CullThrottle._getObjectCFrame(self: CullThrottle, object: Instance): CFrame?
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return nil
	end

	-- TODO: Cache the IsA check in the object data
	if object:IsA("BasePart") then
		return object.CFrame
	elseif object:IsA("Model") then
		return object:GetPivot()
	elseif object:IsA("Bone") then
		return object.TransformedWorldCFrame
	elseif object:IsA("Attachment") then
		return object.WorldCFrame
	elseif object:IsA("Beam") then
		-- Beams are roughly located between their attachments
		local attachment0, attachment1 = object.Attachment0, object.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return nil
		end
		return attachment0.WorldCFrame:Lerp(attachment1.WorldCFrame, 0.5)
	end

	-- We don't know how to get the position of this,
	-- so let's assume it's at the parent position
	if not object.Parent then
		warn("Cannot determine cframe of " .. object.ClassName .. ", unknown class with no parent")
		return nil
	end

	local parentCFrame = self:_getObjectCFrame(object.Parent)
	if not parentCFrame then
		warn("Cannot determine position of " .. object:GetFullName() .. ", ancestry objects lack cframe info")
	end

	return parentCFrame
end

function CullThrottle._connectCFrameChangeEvent(
	self: CullThrottle,
	object: Instance,
	callback: (CFrame) -> ()
): { RBXScriptConnection }
	local connections = {}

	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return connections
	end

	if object:IsA("BasePart") then
		table.insert(
			connections,
			object:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(object.CFrame)
			end)
		)
	elseif object:IsA("Model") then
		if object.PrimaryPart then
			table.insert(
				connections,
				object.PrimaryPart:GetPropertyChangedSignal("CFrame"):Connect(function()
					callback(object:GetPivot())
				end)
			)
		else
			table.insert(
				connections,
				object:GetPropertyChangedSignal("WorldPivot"):Connect(function()
					callback(object:GetPivot())
				end)
			)
		end
	elseif object:IsA("Bone") then
		table.insert(
			connections,
			object:GetPropertyChangedSignal("TransformedWorldCFrame"):Connect(function()
				callback(object.TransformedWorldCFrame)
			end)
		)
	elseif object:IsA("Attachment") then
		table.insert(
			connections,
			object:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(object.WorldCFrame)
			end)
		)
	elseif object:IsA("Beam") then
		-- Beams are roughly located between their attachments
		local attachment0, attachment1 = object.Attachment0, object.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return connections
		end
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(self:_getObjectCFrame(object) or CFrame.identity)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(self:_getObjectCFrame(object) or CFrame.identity)
			end)
		)
	else
		-- We don't know how to get the position of this,
		-- so let's assume it's at the parent position
		if not object.Parent then
			warn("Cannot connect cframe of " .. object.ClassName .. ", unknown class with no parent")
			return connections
		end

		local parentConnections = self:_connectCFrameChangeEvent(object.Parent, callback)
		if not parentConnections then
			warn("Cannot connect cframe of " .. object:GetFullName() .. ", ancestry objects lack cframe info")
		end

		return parentConnections
	end

	return connections
end

function CullThrottle._getObjectBoundingBox(self: CullThrottle, object: Instance): Vector3?
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return nil
	end

	if object:IsA("BasePart") then
		return object.Size
	elseif object:IsA("Model") then
		local _, size = object:GetBoundingBox()
		return size
	elseif object:IsA("Beam") then
		-- Beams sized between their attachments with their defined width
		local attachment0, attachment1 = object.Attachment0, object.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return nil
		end

		local width = math.max(object.Width0, object.Width1)
		local length = (attachment0.WorldPosition - attachment1.WorldPosition).Magnitude
		return Vector3.new(width, width, length)
	elseif object:IsA("PointLight") or object:IsA("SpotLight") then
		return Vector3.one * object.Range
	elseif object:IsA("Sound") then
		return Vector3.one * object.RollOffMaxDistance
	end

	-- We don't know how to get the position of this,
	-- so let's assume it's at the parent position
	if not object.Parent then
		warn("Cannot determine bounding box of " .. object.ClassName .. ", unknown class with no parent")
		return nil
	end

	local parentBoundingBox = self:_getObjectBoundingBox(object.Parent)
	if not parentBoundingBox then
		warn("Cannot determine bounding box of " .. object:GetFullName() .. ", ancestry objects lack bounding box info")
	end

	return parentBoundingBox
end

function CullThrottle._connectBoundingBoxChangeEvent(
	self: CullThrottle,
	object: Instance,
	callback: (Vector3) -> ()
): { RBXScriptConnection }
	local connections = {}

	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return connections
	end

	if object:IsA("BasePart") then
		table.insert(
			connections,
			object:GetPropertyChangedSignal("Size"):Connect(function()
				callback(object.Size)
			end)
		)
	elseif object:IsA("Model") then
		-- TODO: Figure out a decent way to tell when a model size
		-- is changed without scale (ie: new parts added or resized)
		table.insert(
			connections,
			object:GetPropertyChangedSignal("Scale"):Connect(function()
				local _, size = object:GetBoundingBox()
				callback(size)
			end)
		)
	elseif object:IsA("Beam") then
		-- Beams sized between their attachments with their defined width
		local attachment0, attachment1 = object.Attachment0, object.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine bounding box of Beam since it does not have attachments")
			return connections
		end

		table.insert(
			connections,
			object:GetPropertyChangedSignal("Width0"):Connect(function()
				callback(self:_getObjectBoundingBox(object) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			object:GetPropertyChangedSignal("Width1"):Connect(function()
				callback(self:_getObjectBoundingBox(object) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("WorldPosition"):Connect(function()
				callback(self:_getObjectBoundingBox(object) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("WorldPosition"):Connect(function()
				callback(self:_getObjectBoundingBox(object) or Vector3.one)
			end)
		)
	elseif object:IsA("PointLight") or object:IsA("SpotLight") then
		table.insert(
			connections,
			object:GetPropertyChangedSignal("Range"):Connect(function()
				callback(Vector3.one * object.Range)
			end)
		)
	elseif object:IsA("Sound") then
		table.insert(
			connections,
			object:GetPropertyChangedSignal("RollOffMaxDistance"):Connect(function()
				callback(Vector3.one * object.RollOffMaxDistance)
			end)
		)
	else
		-- We don't know how to get the position of this,
		-- so let's assume it's at the parent position
		if not object.Parent then
			warn("Cannot connect cframe of " .. object.ClassName .. ", unknown class with no parent")
			return connections
		end

		local parentConnections = self:_connectBoundingBoxChangeEvent(object.Parent, callback)
		if not parentConnections then
			warn("Cannot connect cframe of " .. object:GetFullName() .. ", ancestry objects lack cframe info")
		end

		return parentConnections
	end

	return connections
end

function CullThrottle._subscribeToDimensionChanges(self: CullThrottle, object: Instance, objectData: ObjectData)
	local cframeChangeConnections = self:_connectCFrameChangeEvent(object, function(cframe: CFrame)
		-- Update CFrame
		objectData.cframe = cframe
		self:_updateDesiredVoxelKeys(object, objectData)
	end)
	local boundingBoxChangeConnections = self:_connectBoundingBoxChangeEvent(object, function(boundingBox: Vector3)
		-- Update bounding box and radius
		objectData.halfBoundingBox = boundingBox / 2
		objectData.radius = math.max(boundingBox.X, boundingBox.Y, boundingBox.Z) / 2

		self:_updateDesiredVoxelKeys(object, objectData)
	end)

	for _, connection in cframeChangeConnections do
		table.insert(objectData.changeConnections, connection)
	end
	for _, connection in boundingBoxChangeConnections do
		table.insert(objectData.changeConnections, connection)
	end
end

function CullThrottle._updateDesiredVoxelKeys(
	self: CullThrottle,
	object: Instance,
	objectData: ObjectData
): { [Vector3]: boolean }
	local voxelSize = self._voxelSize
	local radiusThresholdForCorners = self._radiusThresholdForCorners
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

	if next(desiredVoxelKeys) then
		-- Use a cheap manhattan distance check for priority
		local difference = position - CameraCache.Position
		local priority = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)

		self._objectRefreshQueue:enqueue(object, priority)
	end

	return desiredVoxelKeys
end

function CullThrottle._insertToVoxel(self: CullThrottle, voxelKey: Vector3, object: Instance)
	local voxel = self._voxels[voxelKey]
	if not voxel then
		-- New voxel, init the list with this object inside
		self._voxels[voxelKey] = { object }
	else
		-- Existing voxel, add this object to its list
		table.insert(voxel, object)
	end
end

function CullThrottle._removeFromVoxel(self: CullThrottle, voxelKey: Vector3, object: Instance)
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

function CullThrottle._processObjectRefreshQueue(self: CullThrottle, time_limit: number)
	debug.profilebegin("ObjectRefreshQueue")
	local now = os.clock()
	while (not self._objectRefreshQueue:empty()) and (os.clock() - now < time_limit) do
		local object = self._objectRefreshQueue:dequeue()
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

function CullThrottle._nextPhysicsObject(self: CullThrottle)
	self._physicsObjectIterIndex += 1
	if self._physicsObjectIterIndex > #self._physicsObjects then
		self._physicsObjectIterIndex = 1
	end
end

function CullThrottle._pollPhysicsObjects(self: CullThrottle, time_limit: number)
	debug.profilebegin("PhysicsObjects")
	local now = os.clock()
	local startIndex = self._physicsObjectIterIndex
	while os.clock() - now < time_limit do
		local object = self._physicsObjects[self._physicsObjectIterIndex]
		self:_nextPhysicsObject()

		if not object then
			continue
		end

		local objectData = self._objects[object]
		if not objectData then
			warn("Physics object", object, "is missing objectData, this shouldn't happen!")
			continue
		end

		-- Update the object's cframe
		local cframe = self:_getObjectCFrame(object)
		if cframe then
			objectData.cframe = cframe
			self:_updateDesiredVoxelKeys(object, objectData)
		end

		if startIndex == self._physicsObjectIterIndex then
			-- We've looped through the entire list, no need to continue
			break
		end
	end
	debug.profileend()
end

-- Function to check if a box is inside a frustum using SAT
local verticesToCheck = table.create(8)
function CullThrottle._isBoxInFrustum(
	self: CullThrottle,
	checkForCompletelyInside: boolean,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (boolean, boolean)
	debug.profilebegin("isBoxInFrustum")
	local voxelSize = self._voxelSize
	local vertexVisibilityCache = self._vertexVisibilityCache

	-- Convert the box bounds into the 8 corners of the box in world space
	local x0W, x1W = x0 * voxelSize, x1 * voxelSize
	local y0W, y1W = y0 * voxelSize, y1 * voxelSize
	local z0W, z1W = z0 * voxelSize, z1 * voxelSize
	-- Reuse the same table to avoid allocations and cleanup
	verticesToCheck[1] = Vector3.new(x0W, y0W, z0W)
	verticesToCheck[2] = Vector3.new(x1W, y0W, z0W)
	verticesToCheck[3] = Vector3.new(x0W, y1W, z0W)
	verticesToCheck[4] = Vector3.new(x1W, y1W, z0W)
	verticesToCheck[5] = Vector3.new(x0W, y0W, z1W)
	verticesToCheck[6] = Vector3.new(x1W, y0W, z1W)
	verticesToCheck[7] = Vector3.new(x0W, y1W, z1W)
	verticesToCheck[8] = Vector3.new(x1W, y1W, z1W)

	local isBoxInside = true
	local isBoxCompletelyInside = true

	for i = 1, #frustumPlanes, 2 do
		local pos, normal = frustumPlanes[i], frustumPlanes[i + 1]
		local allCornersOutside = true
		local allCornersInside = true

		-- Check the position of each corner relative to the plane
		for _, vertex in verticesToCheck do
			local isVertexInside = false
			if vertexVisibilityCache[vertex] ~= nil then
				isVertexInside = vertexVisibilityCache[vertex]
			else
				-- Check if corner lies outside the frustum plane
				if normal:Dot(vertex - pos) <= EPSILON then
					isVertexInside = true
					-- This corner is inside
				else
					isVertexInside = false
				end
				vertexVisibilityCache[vertex] = isVertexInside
			end

			if isVertexInside then
				allCornersOutside = false
				if not checkForCompletelyInside then
					-- We can early exit on the first inside corner
					debug.profileend()
					return true, true
				end
			else
				allCornersInside = false
			end
		end

		if allCornersOutside then
			-- If all corners are outside any plane, the box is outside the frustum
			isBoxInside = false
			isBoxCompletelyInside = false
			break -- No need to check the other planes
		end

		-- If any corner is outside this plane, the box is not completely inside
		if not allCornersInside then
			isBoxCompletelyInside = false
		end
	end

	debug.profileend()
	return isBoxInside, isBoxCompletelyInside
end

function CullThrottle._getScreenSize(_self: CullThrottle, distance: number, radius: number): number
	-- Calculate the screen size using the precomputed tan(FoV/2)
	local screenSize = (radius / distance) / CameraCache.HalfTanFOV

	return math.clamp(screenSize, MIN_SCREEN_SIZE, MAX_SCREEN_SIZE)
end

function CullThrottle._processVoxel(
	self: CullThrottle,
	now: number,
	shouldSizeThrottle: boolean,
	updateLastVoxelVisiblity: boolean,
	voxelKey: Vector3,
	voxel: { Instance },
	cameraPos: Vector3,
	bestRefreshRate: number,
	refreshRateRange: number
)
	if updateLastVoxelVisiblity then
		self._lastVoxelVisibility[voxelKey] = now
	end

	if not shouldSizeThrottle then
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

			debug.profilebegin("usersCode")
			coroutine.yield(object)
			debug.profileend()

			objectData.lastUpdateClock = now
		end
		return
	end

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

		debug.profilebegin("sizeThrottle")
		local screenSize = self:_getScreenSize((objectData.cframe.Position - cameraPos).Magnitude, objectData.radius)
		local sizeRatio = ((screenSize - MIN_SCREEN_SIZE) / SCREEN_SIZE_RANGE) ^ self._performanceFalloffFactor
		local refreshDelay = bestRefreshRate + (refreshRateRange * (1 - sizeRatio))
		local elapsed = now - objectData.lastUpdateClock + objectData.jitterOffset
		debug.profileend()

		if self.DEBUG_MODE then
			Utility.applyHeatmapColor(object, sizeRatio)
		end

		if elapsed <= refreshDelay then
			-- It is not yet time to update this one
			continue
		end

		debug.profilebegin("usersCode")
		coroutine.yield(object, elapsed)
		debug.profileend()

		objectData.lastUpdateClock = now
	end
end

function CullThrottle._getFrustumVoxelsInVolume(
	self: CullThrottle,
	now: number,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	callback: (Vector3, { Instance }, boolean) -> ()
)
	local isSingleVoxel = x1 - x0 == 1 and y1 - y0 == 1 and z1 - z0 == 1
	local voxels = self._voxels
	local lastVoxelVisibility = self._lastVoxelVisibility

	-- Special case for volumes of a single voxel
	if isSingleVoxel then
		local voxelKey = Vector3.new(x0, y0, z0)
		local voxel = voxels[voxelKey]

		-- No need to check an empty voxel
		if not voxel then
			return
		end

		-- If this voxel was visible a moment ago, assume it still is
		if now - (lastVoxelVisibility[voxelKey] or 0) < LAST_VISIBILITY_GRACE_PERIOD then
			callback(voxelKey, voxel, false)
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
		callback(voxelKey, voxel, true)
		return
	end

	debug.profilebegin("checkBoxVisibilityCache")
	local allVoxelsVisible = true
	local containsVoxels = false
	for x = x0, x1 - 1 do
		for y = y0, y1 - 1 do
			for z = z0, z1 - 1 do
				local voxelKey = Vector3.new(x, y, z)
				if voxels[voxelKey] then
					containsVoxels = true
					if now - (self._lastVoxelVisibility[voxelKey] or 0) >= LAST_VISIBILITY_GRACE_PERIOD then
						allVoxelsVisible = false
						break
					end
				end
			end
		end
	end
	debug.profileend()

	-- Don't bother checking further if this box doesn't contain any voxels
	if not containsVoxels then
		return
	end

	-- If all voxels in this box were visible a moment ago, just assume they still are
	if allVoxelsVisible then
		debug.profilebegin("allVoxelsVisible")
		for x = x0, x1 - 1 do
			for y = y0, y1 - 1 do
				for z = z0, z1 - 1 do
					local voxelKey = Vector3.new(x, y, z)
					local voxel = voxels[voxelKey]
					if not voxel then
						continue
					end
					callback(voxelKey, voxel, false)
				end
			end
		end
		debug.profileend()
		return
	end

	-- Alright, we actually do need to check if this box is visible
	local isInside, isCompletelyInside = self:_isBoxInFrustum(true, frustumPlanes, x0, y0, z0, x1, y1, z1)

	-- If the box is outside the frustum, stop checking now
	if not isInside then
		return
	end

	-- If the box is entirely inside, then we know all voxels contained inside are in the frustum
	-- and we can process them now and not split further
	if isCompletelyInside then
		debug.profilebegin("isCompletelyInside")
		for x = x0, x1 - 1 do
			for y = y0, y1 - 1 do
				for z = z0, z1 - 1 do
					local voxelKey = Vector3.new(x, y, z)
					local voxel = voxels[voxelKey]
					if not voxel then
						continue
					end
					callback(voxelKey, voxel, true)
				end
			end
		end
		debug.profileend()
		return
	end

	-- We are partially inside, so we need to split this box up further
	-- to figure out which voxels within it are the ones inside

	-- Calculate the lengths of each axis
	local lengthX = x1 - x0
	local lengthY = y1 - y0
	local lengthZ = z1 - z0

	-- Split along the axis with the greatest length
	if lengthX >= lengthY and lengthX >= lengthZ then
		local splitCoord = (x0 + x1) // 2
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, z0, splitCoord, y1, z1, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, splitCoord, y0, z0, x1, y1, z1, callback)
	elseif lengthY >= lengthX and lengthY >= lengthZ then
		local splitCoord = (y0 + y1) // 2
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, z0, x1, splitCoord, z1, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, splitCoord, z0, x1, y1, z1, callback)
	else
		local splitCoord = (z0 + z1) // 2
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, z0, x1, y1, splitCoord, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, x0, y0, splitCoord, x1, y1, z1, callback)
	end
end

function CullThrottle._getPlanesAndBounds(
	_self: CullThrottle,
	renderDistance: number,
	voxelSize: number
): ({ Vector3 }, Vector3, Vector3)
	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position

	local farPlaneHeight2 = CameraCache.HalfTanFOV * renderDistance
	local farPlaneWidth2 = farPlaneHeight2 * CameraCache.AspectRatio
	local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -renderDistance)
	local farPlaneTopLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
	local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)

	local upVec, rightVec = cameraCFrame.UpVector, cameraCFrame.RightVector

	local rightNormal = upVec:Cross(cameraPos - farPlaneBottomRight).Unit
	local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
	local topNormal = rightVec:Cross(farPlaneTopRight - cameraPos).Unit
	local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

	local frustumPlanes: { Vector3 } = {
		cameraPos,
		leftNormal,
		cameraPos,
		rightNormal,
		cameraPos,
		topNormal,
		cameraPos,
		bottomNormal,
		farPlaneCFrame.Position,
		cameraCFrame.LookVector,
	}

	local minBound = Vector3.new(
		math.min(cameraPos.X, farPlaneTopLeft.X, farPlaneBottomLeft.X, farPlaneTopRight.X, farPlaneBottomRight.X)
			// voxelSize,
		math.min(cameraPos.Y, farPlaneTopLeft.Y, farPlaneBottomLeft.Y, farPlaneTopRight.Y, farPlaneBottomRight.Y)
			// voxelSize,
		math.min(cameraPos.Z, farPlaneTopLeft.Z, farPlaneBottomLeft.Z, farPlaneTopRight.Z, farPlaneBottomRight.Z)
			// voxelSize
	)
	local maxBound = Vector3.new(
		math.max(cameraPos.X, farPlaneTopLeft.X, farPlaneBottomLeft.X, farPlaneTopRight.X, farPlaneBottomRight.X)
			// voxelSize,
		math.max(cameraPos.Y, farPlaneTopLeft.Y, farPlaneBottomLeft.Y, farPlaneTopRight.Y, farPlaneBottomRight.Y)
			// voxelSize,
		math.max(cameraPos.Z, farPlaneTopLeft.Z, farPlaneBottomLeft.Z, farPlaneTopRight.Z, farPlaneBottomRight.Z)
			// voxelSize
	)

	return frustumPlanes, minBound, maxBound
end

function CullThrottle._getObjects(self: CullThrottle, shouldSizeThrottle: boolean): () -> (Instance?, number?)
	local now = os.clock()

	table.clear(self._vertexVisibilityCache)

	-- Make sure our voxels are up to date for up to 0.1 ms
	self:_pollPhysicsObjects(5e-5)
	self:_processObjectRefreshQueue(5e-5)

	-- Update the performance falloff factor so
	-- we can adjust our refresh rates to hit our target performance time
	self:_updatePerformanceFalloffFactor()

	local voxelSize = self._voxelSize
	local bestRefreshRate = self._bestRefreshRate
	local refreshRateRange = self._refreshRateRange
	local renderDistance = self._renderDistance
	-- For smaller FOVs, we increase render distance
	if CameraCache.FieldOfView < 60 then
		renderDistance *= 2 - CameraCache.FieldOfView / 60
	end

	local cameraPos = CameraCache.Position
	local frustumPlanes, minBound, maxBound = self:_getPlanesAndBounds(renderDistance, voxelSize)

	local minX = minBound.X
	local minY = minBound.Y
	local minZ = minBound.Z
	local maxX = maxBound.X + 1
	local maxY = maxBound.Y + 1
	local maxZ = maxBound.Z + 1

	local thread = coroutine.create(function()
		local function callback(voxelKey: Vector3, voxel: { Instance }, updateLastVoxelVisiblity: boolean)
			self:_processVoxel(
				now,
				shouldSizeThrottle,
				updateLastVoxelVisiblity,
				voxelKey,
				voxel,
				cameraPos,
				bestRefreshRate,
				refreshRateRange
			)
		end

		-- Split into smaller boxes to start off since the frustum bounding volume
		-- obviously intersects the frustum planes

		-- However if the bounds are not divisible then don't split early
		if minX == maxX or minY == maxY or minZ == maxZ then
			self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, minY, minZ, maxX, maxY, maxZ, callback)
			return
		end

		local midBound = (minBound + maxBound) // 2
		local midX = midBound.X
		local midY = midBound.Y
		local midZ = midBound.Z

		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, minY, minZ, midX, midY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, minY, minZ, maxX, midY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, minY, midZ, midX, midY, maxZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, minY, midZ, maxX, midY, maxZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, midY, minZ, midX, maxY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, midY, minZ, maxX, maxY, midZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, minX, midY, midZ, midX, maxY, maxZ, callback)
		self:_getFrustumVoxelsInVolume(now, frustumPlanes, midX, midY, midZ, maxX, maxY, maxZ, callback)
	end)

	return function()
		if coroutine.status(thread) == "dead" then
			self:_addCallTime(now)
			return
		end

		local success, object, elapsed = coroutine.resume(thread)
		if not success then
			warn("CullThrottle._getObjects thread error: " .. tostring(object))
			return
		end

		if not object then
			self:_addCallTime(now)
			return
		end

		return object, elapsed
	end
end

function CullThrottle.setVoxelSize(self: CullThrottle, voxelSize: number)
	self._voxelSize = voxelSize
	self._halfVoxelSizeVec = Vector3.one * (voxelSize / 2)
	self._radiusThresholdForCorners = voxelSize * (1 / 8)

	-- We need to move all the objects around to their new voxels
	table.clear(self._voxels)

	for object, objectData in self._objects do
		self:_updateDesiredVoxelKeys(object, objectData)
	end

	self:_processObjectRefreshQueue(5)
end

function CullThrottle.setRenderDistance(self: CullThrottle, renderDistance: number)
	self._renderDistance = renderDistance
end

function CullThrottle.setRefreshRates(self: CullThrottle, best: number, worst: number)
	if best > 2 then
		best = 1 / best
	end
	if worst > 2 then
		worst = 1 / worst
	end

	self._bestRefreshRate = best
	self._worstRefreshRate = worst
	self._refreshRateRange = worst - best
end

function CullThrottle.addObject(self: CullThrottle, object: Instance)
	local cframe = self:_getObjectCFrame(object)
	if not cframe then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, cframe is unknown")
	end

	local boundingBox = self:_getObjectBoundingBox(object)
	if not boundingBox then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	local objectData: ObjectData = {
		cframe = cframe,
		halfBoundingBox = boundingBox / 2,
		radius = math.max(boundingBox.X, boundingBox.Y, boundingBox.Z) / 2,
		voxelKeys = {},
		desiredVoxelKeys = {},
		lastCheckClock = 0,
		lastUpdateClock = 0,
		jitterOffset = math.random(-1000, 1000) / 500000,
		changeConnections = {},
	}

	self:_subscribeToDimensionChanges(object, objectData)
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

function CullThrottle.addPhysicsObject(self: CullThrottle, object: BasePart)
	self:addObject(object)

	-- Also add it to the physics objects table for polling position changes
	-- (physics based movement doesn't trigger the normal connection)
	table.insert(self._physicsObjects, object)
end

function CullThrottle.removeObject(self: CullThrottle, object: Instance)
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

function CullThrottle.getObjectsInView(self: CullThrottle): () -> (Instance?, number?)
	return self:_getObjects(false)
end

function CullThrottle.getObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?)
	return self:_getObjects(true)
end

return CullThrottle
