--!strict
--!optimize 2

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

if RunService:IsServer() and not RunService:IsEdit() then
	error("CullThrottle is a client side effect and cannot be used on the server")
end

local PriorityQueue = require(script.PriorityQueue)
local CameraCache = require(script.CameraCache)
local Gizmo = require(script.Gizmo)

local EPSILON = 1e-4
local LAST_VISIBILITY_GRACE_PERIOD = 0.15
local NEARBY_DISTANCE_THRESHOLD = 30

-- This weight gives more update priority to larger objects,
-- focusing on the objects that contribute the most visually
local SCREEN_SIZE_PRIORITY_WEIGHT = 80
-- This weight tries to make everything the same refresh rate,
-- sacrificing some updates to big objects for the little ones
-- for a smoother overall vibe
local REFRESH_RATE_PRIORITY_WEIGHT = 18
-- This weight gives more priority to nearby objects regardless of size
-- which can help prioritize objects that are likely the real focus
-- in cases where there are many objects of similar screen size
local DISTANCE_PRIORITY_WEIGHT = 2

local CullThrottle = {}
CullThrottle.__index = CullThrottle

type ObjectData = {
	cframe: CFrame,
	distance: number,
	halfBoundingBox: Vector3,
	radius: number,
	voxelKeys: { [Vector3]: true },
	desiredVoxelKeys: { [Vector3]: boolean },
	lastCheckClock: number,
	lastUpdateClock: number,
	jitterOffset: number,
	changeConnections: { RBXScriptConnection },
	cframeSource: Instance,
	cframeType: string,
	boundingBoxSource: Instance,
	boundingBoxType: string,
}

type CullThrottleProto = {
	DEBUG_MODE: boolean,
	ObjectEnteredView: RBXScriptSignal,
	ObjectExitedView: RBXScriptSignal,
	_enteredViewEvent: BindableEvent,
	_exitedViewEvent: BindableEvent,
	_bestRefreshRate: number,
	_worstRefreshRate: number,
	_refreshRateRange: number,
	_renderDistance: number,
	_searchTimeBudget: number,
	_updateTimeBudget: number,
	_performanceFalloffFactor: number,
	_voxelSize: number,
	_halfVoxelSizeVec: Vector3,
	_radiusThresholdForCorners: number,
	_voxels: { [Vector3]: { Instance } },
	_objects: { [Instance]: ObjectData },
	_physicsObjects: { Instance },
	_objectRefreshQueue: PriorityQueue.PriorityQueue,
	_visibleObjectsQueue: PriorityQueue.PriorityQueue,
	_visibleObjects: { Instance },
	_visibleObjectPriorities: { number },
	_visibleObjectIndex: number,
	_objectVisibilityTimestamps: { [Instance]: number },
	_physicsObjectIterIndex: number,
	_lastVoxelVisibility: { [Vector3]: number },
	_lastCallTimes: { number },
	_lastCallTimeIndex: number,
	_renderConnectionId: string,
}

export type CullThrottle = typeof(setmetatable({} :: CullThrottleProto, CullThrottle))

function CullThrottle.new(): CullThrottle
	local self = setmetatable({}, CullThrottle)

	self.DEBUG_MODE = false

	self._enteredViewEvent = Instance.new("BindableEvent")
	self._exitedViewEvent = Instance.new("BindableEvent")

	self.ObjectEnteredView = self._enteredViewEvent.Event
	self.ObjectExitedView = self._exitedViewEvent.Event

	self._voxelSize = 75
	self._halfVoxelSizeVec = Vector3.one * (self._voxelSize / 2)
	self._radiusThresholdForCorners = self._voxelSize * (1 / 8)
	self._renderDistance = 400
	self._searchTimeBudget = 1.25 / 1000
	self._updateTimeBudget = 0.35 / 1000
	self._bestRefreshRate = 1 / 60
	self._worstRefreshRate = 1 / 15
	self._refreshRateRange = self._worstRefreshRate - self._bestRefreshRate
	self._performanceFalloffFactor = 1
	self._voxels = {}
	self._objects = {}
	self._physicsObjects = {}
	self._physicsObjectIterIndex = 1
	self._objectRefreshQueue = PriorityQueue.new()
	self._visibleObjectsQueue = PriorityQueue.new()
	self._visibleObjects = {}
	self._visibleObjectPriorities = {}
	self._visibleObjectIndex = 1
	self._objectVisibilityTimestamps = {}
	self._lastVoxelVisibility = {}
	self._lastCallTimes = table.create(5, 0)
	self._lastCallTimeIndex = 1
	self._renderConnectionId = "CullThrottle_" .. HttpService:GenerateGUID(false)

	RunService:BindToRenderStep(self._renderConnectionId, Enum.RenderPriority.First.Value, function()
		self:_processObjectVisibility()
	end)

	return self
end

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
	if not self.DEBUG_MODE then
		return
	end

	local voxelSize = self._voxelSize
	local x0World, y0World, z0World = x0 * voxelSize, y0 * voxelSize, z0 * voxelSize
	local x1World, y1World, z1World = x1 * voxelSize, y1 * voxelSize, z1 * voxelSize

	local cf = CFrame.new((x0World + x1World) / 2, (y0World + y1World) / 2, (z0World + z1World) / 2)
	local size = Vector3.new(math.abs(x0World - x1World), math.abs(y0World - y1World), math.abs(z0World - z1World))
		- (Vector3.one * 2)

	task.defer(function()
		Gizmo.setColor3(color)
		Gizmo.setTransparency(transparency)
		Gizmo.drawWireBox(cf, size)
	end)
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
	local targetCallTime = self._searchTimeBudget
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

function CullThrottle._getObjectCFrameSource(self: CullThrottle, object: Instance): (Instance?, string?)
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return nil, nil
	end

	if object:IsA("BasePart") then
		return object, "BasePart"
	elseif object:IsA("Model") then
		return object, "Model"
	elseif object:IsA("Bone") then
		return object, "Bone"
	elseif object:IsA("Attachment") then
		return object, "Attachment"
	elseif object:IsA("Beam") then
		return object, "Beam"
	elseif not object.Parent then
		return nil, nil
	else
		return self:_getObjectCFrameSource(object.Parent)
	end
end

function CullThrottle._getObjectBoundingBoxSource(self: CullThrottle, object: Instance): (Instance?, string?)
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here
		return nil, nil
	end

	if object:IsA("BasePart") then
		return object, "BasePart"
	elseif object:IsA("Model") then
		return object, "Model"
	elseif object:IsA("Beam") then
		return object, "Beam"
	elseif object:IsA("PointLight") or object:IsA("SpotLight") then
		return object, "Light"
	elseif object:IsA("Sound") then
		return object, "Sound"
	elseif not object.Parent then
		return nil, nil
	else
		return self:_getObjectBoundingBoxSource(object.Parent)
	end
end

function CullThrottle._getObjectCFrame(_self: CullThrottle, objectData: ObjectData): CFrame?
	local object = objectData.cframeSource
	local sourceType = objectData.cframeType

	if sourceType == "BasePart" then
		return (object :: BasePart).CFrame
	elseif sourceType == "Model" then
		return (object :: Model):GetPivot()
	elseif sourceType == "Bone" then
		return (object :: Bone).TransformedWorldCFrame
	elseif sourceType == "Attachment" then
		return (object :: Attachment).WorldCFrame
	elseif sourceType == "Beam" then
		local attachment0, attachment1 = (object :: Beam).Attachment0, (object :: Beam).Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return nil
		end
		return attachment0.WorldCFrame:Lerp(attachment1.WorldCFrame, 0.5)
	end

	return nil
end

function CullThrottle._connectCFrameChangeEvent(
	self: CullThrottle,
	objectData: ObjectData,
	callback: (CFrame) -> ()
): { RBXScriptConnection }
	local connections = {}

	local object = objectData.cframeSource
	if not object then
		return connections
	end

	local sourceType = objectData.cframeType

	if sourceType == "BasePart" then
		local typedObject: BasePart = object :: BasePart
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(typedObject.CFrame)
			end)
		)
	elseif sourceType == "Model" then
		local typedObject: Model = object :: Model
		if typedObject.PrimaryPart then
			table.insert(
				connections,
				typedObject.PrimaryPart:GetPropertyChangedSignal("CFrame"):Connect(function()
					callback(typedObject:GetPivot())
				end)
			)
		else
			table.insert(
				connections,
				typedObject:GetPropertyChangedSignal("WorldPivot"):Connect(function()
					callback(typedObject:GetPivot())
				end)
			)
		end
	elseif sourceType == "Bone" then
		local typedObject: Bone = object :: Bone
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("TransformedWorldCFrame"):Connect(function()
				callback(typedObject.TransformedWorldCFrame)
			end)
		)
	elseif sourceType == "Attachment" then
		local typedObject: Attachment = object :: Attachment
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(typedObject.WorldCFrame)
			end)
		)
	elseif sourceType == "Beam" then
		local typedObject: Beam = object :: Beam
		-- Beams are roughly located between their attachments
		local attachment0, attachment1 = typedObject.Attachment0, typedObject.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return connections
		end
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(self:_getObjectCFrame(objectData) or CFrame.identity)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(self:_getObjectCFrame(objectData) or CFrame.identity)
			end)
		)
	end

	return connections
end

function CullThrottle._getObjectBoundingBox(_self: CullThrottle, objectData: ObjectData): Vector3?
	local object = objectData.boundingBoxSource
	local sourceType = objectData.boundingBoxType

	if sourceType == "BasePart" then
		return (object :: BasePart).Size
	elseif sourceType == "Model" then
		local _, size = (object :: Model):GetBoundingBox()
		return size
	elseif sourceType == "Beam" then
		local attachment0, attachment1 = (object :: Beam).Attachment0, (object :: Beam).Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine position of Beam since it does not have attachments")
			return nil
		end

		local width = math.max((object :: Beam).Width0, (object :: Beam).Width1)
		local length = (attachment0.WorldPosition - attachment1.WorldPosition).Magnitude
		return Vector3.new(width, width, length)
	elseif sourceType == "Light" then
		return Vector3.one * (object :: SpotLight | PointLight).Range
	elseif sourceType == "Sound" then
		return Vector3.one * (object :: Sound).RollOffMaxDistance
	end

	return nil
end

function CullThrottle._connectBoundingBoxChangeEvent(
	self: CullThrottle,
	objectData: ObjectData,
	callback: (Vector3) -> ()
): { RBXScriptConnection }
	local connections = {}

	local object = objectData.boundingBoxSource
	if not object then
		return connections
	end

	local sourceType = objectData.boundingBoxType

	if sourceType == "BasePart" then
		local typedObject: BasePart = object :: BasePart
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("Size"):Connect(function()
				callback(typedObject.Size)
			end)
		)
	elseif sourceType == "Model" then
		local typedObject: Model = object :: Model
		-- TODO: Figure out a decent way to tell when a model bounds change
		-- without connecting to all descendants size changes
		table.insert(
			connections,
			typedObject.DescendantAdded:Connect(function()
				local _, size = typedObject:GetBoundingBox()
				callback(size)
			end)
		)
		table.insert(
			connections,
			typedObject.DescendantRemoving:Connect(function()
				local _, size = typedObject:GetBoundingBox()
				callback(size)
			end)
		)
	elseif sourceType == "Beam" then
		local typedObject: Beam = object :: Beam
		-- Beams sized between their attachments with their defined width
		local attachment0, attachment1 = typedObject.Attachment0, typedObject.Attachment1
		if not attachment0 or not attachment1 then
			warn("Cannot determine bounding box of Beam since it does not have attachments")
			return connections
		end

		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("Width0"):Connect(function()
				callback(self:_getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("Width1"):Connect(function()
				callback(self:_getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("WorldPosition"):Connect(function()
				callback(self:_getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("WorldPosition"):Connect(function()
				callback(self:_getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
	elseif sourceType == "Light" then
		local typedObject: SpotLight | PointLight = object :: SpotLight | PointLight
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("Range"):Connect(function()
				callback(Vector3.one * typedObject.Range)
			end)
		)
	elseif sourceType == "Sound" then
		local typedObject: Sound = object :: Sound
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("RollOffMaxDistance"):Connect(function()
				callback(Vector3.one * typedObject.RollOffMaxDistance)
			end)
		)
	end

	return connections
end

function CullThrottle._subscribeToDimensionChanges(self: CullThrottle, object: Instance, objectData: ObjectData)
	local cframeChangeConnections = self:_connectCFrameChangeEvent(objectData, function(cframe: CFrame)
		-- Update CFrame
		objectData.cframe = cframe
		self:_updateDesiredVoxelKeys(object, objectData)
	end)
	local boundingBoxChangeConnections = self:_connectBoundingBoxChangeEvent(objectData, function(boundingBox: Vector3)
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

function CullThrottle._processObjectRefreshQueue(self: CullThrottle, timeBudget: number, now: number)
	debug.profilebegin("processObjectRefreshQueue")
	while (not self._objectRefreshQueue:isEmpty()) and (os.clock() - now < timeBudget) do
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

function CullThrottle._pollPhysicsObjects(self: CullThrottle, timeBudget: number, now: number)
	debug.profilebegin("pollPhysicsObjects")
	local startIndex = self._physicsObjectIterIndex

	if #self._physicsObjects == 0 then
		debug.profileend()
		return
	end

	while os.clock() - now < timeBudget do
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
		local cframe = self:_getObjectCFrame(objectData)
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
	local voxelSize = self._voxelSize
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

	local completelyInside = true

	-- Check each frustum plane
	for i = 1, #frustumPlanes, 2 do
		local planePos, planeNormal = frustumPlanes[i], frustumPlanes[i + 1]

		-- Compute the distance from box center to the plane
		local dist = (center - planePos):Dot(planeNormal)

		-- Compute the projection interval radius of box onto the plane normal
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

	-- If we've made it here, the box is either inside or intersecting the frustum
	debug.profileend()
	return true, completelyInside
end

function CullThrottle._getScreenSize(_self: CullThrottle, distance: number, radius: number): number
	-- Calculate the screen size using the precomputed tan(FoV/2)
	return (radius / distance) / CameraCache.HalfTanFOV
end

function CullThrottle._addVoxelToVisibleObjects(
	self: CullThrottle,
	now: number,
	updateLastVoxelVisiblity: boolean,
	voxelKey: Vector3,
	voxel: { Instance },
	cameraPos: Vector3,
	bestRefreshRate: number,
	worstRefreshRate: number,
	refreshRateRange: number,
	renderDistance: number
)
	debug.profilebegin("addVoxelVisible")

	if updateLastVoxelVisiblity then
		self._lastVoxelVisibility[voxelKey] = now
	end

	local objectVisibilityTimestamps = self._objectVisibilityTimestamps
	local visibleObjects = self._visibleObjects
	local visibleObjectPriorities = self._visibleObjectPriorities
	local visibleObjectIndex = self._visibleObjectIndex

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
		if distance > renderDistance then
			-- Object is outside what we consider visible
			continue
		end

		local screenSize = self:_getScreenSize(distance, objectData.radius) ^ self._performanceFalloffFactor
		local elapsed = now - objectData.lastUpdateClock
		local jitteredElapsed = elapsed + objectData.jitterOffset

		objectData.distance = distance

		local objectPriority = 0

		if jitteredElapsed < bestRefreshRate then
			-- No need to refresh faster than our best rate
			-- so make this super low priority
			objectPriority = (1 - screenSize) * 1e6
		elseif jitteredElapsed >= worstRefreshRate then
			-- Try to at least maintain the worst refresh rate
			objectPriority = 1 - (jitteredElapsed - bestRefreshRate) / refreshRateRange
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

			-- print(
			-- 	string.format(
			-- 		"priority: %.4f\n  screenSize: %.4f%%, priority: %.3f\n  elapsed: %.1fms, priority: %.3f\n  distance: %.1f, priority: %.3f",
			-- 		objectPriority,
			-- 		screenSize * 100,
			-- 		screenSizePriority,
			-- 		jitteredElapsed * 1000,
			-- 		refreshPriority,
			-- 		distance,
			-- 		distancePriority
			-- 	)
			-- )
		end

		visibleObjects[visibleObjectIndex] = object
		visibleObjectPriorities[visibleObjectIndex] = objectPriority
		visibleObjectIndex += 1

		if objectVisibilityTimestamps[object] == nil then
			-- This object wasn't visible last frame but it is now
			self._enteredViewEvent:Fire(object)
		end
		objectVisibilityTimestamps[object] = now
	end

	self._visibleObjectIndex = visibleObjectIndex

	debug.profileend()
end

function CullThrottle._getFrustumVoxelsInVolume(
	self: CullThrottle,
	now: number,
	timeBudget: number,
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

	if os.clock() - now >= timeBudget then
		-- We don't have time to be accurate anymore, just assume they're in view
		debug.profilebegin("budgetReached_useCachedOnly")
		for x = x0, x1 - 1 do
			for y = y0, y1 - 1 do
				for z = z0, z1 - 1 do
					local voxelKey = Vector3.new(x, y, z)
					local voxel = voxels[voxelKey]
					if not voxel then
						continue
					end
					if lastVoxelVisibility[voxelKey] then
						callback(voxelKey, voxel, false)
					end
				end
			end
		end

		self:_drawBox(Color3.new(0, 0, 1), 0, x0, y0, z0, x1, y1, z1)
		debug.profileend()
		return
	end

	local JITTERED_LAST_VISIBILITY_GRACE_PERIOD = LAST_VISIBILITY_GRACE_PERIOD * (1 + (math.random() * 0.1 - 0.05))

	-- Special case for volumes of a single voxel
	if isSingleVoxel then
		local voxelKey = Vector3.new(x0, y0, z0)
		local voxel = voxels[voxelKey]

		-- No need to check an empty voxel
		if not voxel then
			self:_drawBox(Color3.new(1, 1, 1), 0.5, x0, y0, z0, x1, y1, z1)
			return
		end

		-- If this voxel was visible a moment ago, assume it still is
		if now - (lastVoxelVisibility[voxelKey] or 0) < JITTERED_LAST_VISIBILITY_GRACE_PERIOD then
			callback(voxelKey, voxel, false)
			self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
			return
		end

		-- Alright, we actually do need to check if this voxel is visible
		local isInside = self:_isBoxInFrustum(false, frustumPlanes, x0, y0, z0, x1, y1, z1)
		self:_drawBox(if isInside then Color3.new(0, 1, 0) else Color3.new(1, 0, 0), 0, x0, y0, z0, x1, y1, z1)
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
				if not voxels[voxelKey] then
					continue
				end
				containsVoxels = true
				if now - (lastVoxelVisibility[voxelKey] or 0) >= JITTERED_LAST_VISIBILITY_GRACE_PERIOD then
					allVoxelsVisible = false
					break
				end
			end
		end
	end
	debug.profileend()

	-- Don't bother checking further if this box doesn't contain any voxels
	if not containsVoxels then
		self:_drawBox(Color3.new(1, 1, 1), 0.5, x0, y0, z0, x1, y1, z1)
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
		self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		return
	end

	-- Alright, we actually do need to check if this box is visible
	local isInside, isCompletelyInside = self:_isBoxInFrustum(true, frustumPlanes, x0, y0, z0, x1, y1, z1)

	-- If the box is outside the frustum, stop checking now
	if not isInside then
		-- All voxels within this box are not visible and should clear their cache
		debug.profilebegin("clearBoxVisibilityCache")
		for x = x0, x1 - 1 do
			for y = y0, y1 - 1 do
				for z = z0, z1 - 1 do
					local voxelKey = Vector3.new(x, y, z)
					if lastVoxelVisibility[voxelKey] then
						lastVoxelVisibility[voxelKey] = nil
					end
				end
			end
		end
		debug.profileend()
		self:_drawBox(Color3.new(1, 0, 0), 0, x0, y0, z0, x1, y1, z1)
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
		self:_drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		return
	end

	-- We are partially inside, so we need to split this box up further
	-- to figure out which voxels within it are the ones inside

	-- Calculate the lengths of each axis
	local lengthX = x1 - x0
	local lengthY = y1 - y0
	local lengthZ = z1 - z0

	-- Split along the axis with the greatest length
	local randomizeSearchOrder = math.random(0, 1) == 0 -- Search them in random order to avoid bias towards one half
	if lengthX >= lengthY and lengthX >= lengthZ then
		local splitCoord = (x0 + x1) // 2
		if randomizeSearchOrder then
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, z0, splitCoord, y1, z1, callback)
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, splitCoord, y0, z0, x1, y1, z1, callback)
		else
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, splitCoord, y0, z0, x1, y1, z1, callback)
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, z0, splitCoord, y1, z1, callback)
		end
	elseif lengthY >= lengthX and lengthY >= lengthZ then
		local splitCoord = (y0 + y1) // 2
		if randomizeSearchOrder then
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, z0, x1, splitCoord, z1, callback)
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, splitCoord, z0, x1, y1, z1, callback)
		else
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, splitCoord, z0, x1, y1, z1, callback)
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, z0, x1, splitCoord, z1, callback)
		end
	else
		local splitCoord = (z0 + z1) // 2
		if randomizeSearchOrder then
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, z0, x1, y1, splitCoord, callback)
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, splitCoord, x1, y1, z1, callback)
		else
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, splitCoord, x1, y1, z1, callback)
			self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, x0, y0, z0, x1, y1, splitCoord, callback)
		end
	end
end

function CullThrottle._getPlanesAndBounds(
	self: CullThrottle,
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

	if self.DEBUG_MODE then
		task.defer(function()
			Gizmo.setColor3(Color3.fromRGB(168, 87, 219))
			Gizmo.setTransparency(0)
			Gizmo.drawLine(cameraPos, farPlaneTopLeft)
			Gizmo.drawLine(cameraPos, farPlaneTopRight)
			Gizmo.drawLine(cameraPos, farPlaneBottomLeft)
			Gizmo.drawLine(cameraPos, farPlaneBottomRight)
			Gizmo.drawLine(farPlaneTopLeft, farPlaneTopRight)
			Gizmo.drawLine(farPlaneTopRight, farPlaneBottomRight)
			Gizmo.drawLine(farPlaneBottomLeft, farPlaneBottomRight)
			Gizmo.drawLine(farPlaneTopLeft, farPlaneBottomLeft)
			Gizmo.setTransparency(0.9)
			Gizmo.drawBox(farPlaneCFrame, Vector3.new(farPlaneWidth2 * 2, farPlaneHeight2 * 2, 1))
			Gizmo.drawTriangle(cameraPos, farPlaneTopLeft, farPlaneBottomLeft)
			Gizmo.drawTriangle(cameraPos, farPlaneTopRight, farPlaneBottomRight)
			Gizmo.drawTriangle(cameraPos, farPlaneTopLeft, farPlaneTopRight)
			Gizmo.drawTriangle(cameraPos, farPlaneBottomLeft, farPlaneBottomRight)
			Gizmo.setTransparency(0.5)
			Gizmo.drawWireBox(
				CFrame.new((minBound + (maxBound + Vector3.one)) / 2 * voxelSize),
				((maxBound + Vector3.one) - minBound) * voxelSize
			)
		end)
	end

	return frustumPlanes, minBound, maxBound
end

function CullThrottle._clearVisibleObjects(self: CullThrottle)
	self._visibleObjectIndex = 1
	table.clear(self._visibleObjects)
	table.clear(self._visibleObjectPriorities)
	self._visibleObjectsQueue:clear()
end

function CullThrottle._fillVisibleObjectsQueue(self: CullThrottle)
	debug.profilebegin("fillVisibleObjectsQueue")
	self._visibleObjectsQueue:batchEnqueue(self._visibleObjects, self._visibleObjectPriorities)
	debug.profileend()
end

function CullThrottle._signalVisibilityChanges(self: CullThrottle, now: number)
	debug.profilebegin("signalVisibilityChanges")
	local objectVisibilityTimestamps = self._objectVisibilityTimestamps

	for object, lastSeen in objectVisibilityTimestamps do
		if lastSeen ~= now then
			-- Object was visible last frame but not this frame
			objectVisibilityTimestamps[object] = nil
			self._exitedViewEvent:Fire(object)
		end
	end

	debug.profileend()
end

function CullThrottle._findVisibleObjects(self: CullThrottle, now: number)
	debug.profilebegin("findVisibleObjects")

	if self.DEBUG_MODE then
		Gizmo.enableGizmos()
	else
		Gizmo.disableGizmos()
	end

	-- Clear any objects left over from last frame
	self:_clearVisibleObjects()

	local timeBudget = self._searchTimeBudget
	local voxelSize = self._voxelSize
	local bestRefreshRate = self._bestRefreshRate
	local worstRefreshRate = self._worstRefreshRate
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

	local function callback(voxelKey: Vector3, voxel: { Instance }, updateLastVoxelVisiblity: boolean)
		self:_addVoxelToVisibleObjects(
			now,
			updateLastVoxelVisiblity,
			voxelKey,
			voxel,
			cameraPos,
			bestRefreshRate,
			worstRefreshRate,
			refreshRateRange,
			renderDistance
		)
	end

	-- Split into smaller boxes to start off since the frustum bounding volume
	-- obviously intersects the frustum planes

	-- However if the bounds are not divisible then don't split early
	if minX == maxX or minY == maxY or minZ == maxZ then
		self:_getFrustumVoxelsInVolume(now, timeBudget, frustumPlanes, minX, minY, minZ, maxX, maxY, maxZ, callback)
		debug.profileend()
		return
	end

	local midBound = (minBound + maxBound) // 2
	local midX = midBound.X
	local midY = midBound.Y
	local midZ = midBound.Z

	local quadrants = {
		{ minX, minY, minZ, midX, midY, midZ },
		{ midX, minY, minZ, maxX, midY, midZ },
		{ minX, minY, midZ, midX, midY, maxZ },
		{ midX, minY, midZ, maxX, midY, maxZ },
		{ minX, midY, minZ, midX, maxY, midZ },
		{ midX, midY, minZ, maxX, maxY, midZ },
		{ minX, midY, midZ, midX, maxY, maxZ },
		{ midX, midY, midZ, maxX, maxY, maxZ },
	}

	-- Shuffle the order in which we search the quadrants to avoid
	-- bias in object priority
	for i = #quadrants, 2, -1 do
		local j = math.random(i)
		quadrants[i], quadrants[j] = quadrants[j], quadrants[i]
	end

	for _, quadrant in quadrants do
		self:_getFrustumVoxelsInVolume(
			now,
			timeBudget,
			frustumPlanes,
			quadrant[1],
			quadrant[2],
			quadrant[3],
			quadrant[4],
			quadrant[5],
			quadrant[6],
			callback
		)
	end

	debug.profileend()
end

function CullThrottle._processObjectVisibility(self: CullThrottle)
	debug.profilebegin("CullThrottle")
	local start = os.clock()

	-- Make sure our voxels are up to date for up to 0.1 ms
	self:_pollPhysicsObjects(5e-5, start)
	self:_processObjectRefreshQueue(5e-5, start)

	-- Update the performance falloff factor to
	-- dynamically adjust the priorities based on
	-- current capabilities
	self:_updatePerformanceFalloffFactor()

	-- Find the objects that are visible this frame
	self:_findVisibleObjects(start)

	-- Signal the visibility changes to the event handler
	self:_signalVisibilityChanges(start)

	-- Record the time taken
	self:_addCallTime(start)
	debug.profileend()
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

	self:_processObjectRefreshQueue(5, os.clock())
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
	local cframeSource, cframeType = self:_getObjectCFrameSource(object)
	local boundingBoxSource, boundingBoxType = self:_getObjectBoundingBoxSource(object)

	if not cframeSource or not cframeType then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, cframe is unknown")
	end

	if not boundingBoxSource or not boundingBoxType then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	local objectData: ObjectData = {
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

	local cframe = self:_getObjectCFrame(objectData)
	if not cframe then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, cframe is unknown")
	end

	objectData.cframe = cframe
	objectData.distance = (CameraCache.Position - cframe.Position).Magnitude

	local boundingBox = self:_getObjectBoundingBox(objectData)
	if not boundingBox then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	objectData.halfBoundingBox = boundingBox / 2
	objectData.radius = math.max(boundingBox.X, boundingBox.Y, boundingBox.Z) / 2

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

function CullThrottle.getObjectsInView(self: CullThrottle): { Instance }
	return self._visibleObjects
end

function CullThrottle.iterObjectsToUpdate(self: CullThrottle): () -> (Instance?, number?, number?)
	debug.profilebegin("CullThrottle.iterObjects")

	-- We need to put the visibleObjects into our priority queue,
	-- which we then empty as we iterate through the objects
	self:_fillVisibleObjectsQueue()

	local updateStartClock = os.clock()
	local queue = self._visibleObjectsQueue
	local updateTimeBudget = self._updateTimeBudget
	local p0UpdateTimeBudget = updateTimeBudget * 2 -- p0s can go over budget

	return function()
		if queue:isEmpty() then
			debug.profileend()
			return
		end

		local budget = if queue:peekPriority() < 1 then p0UpdateTimeBudget else updateTimeBudget
		if os.clock() - updateStartClock > budget then
			-- Out of time, can't update the rest this frame.
			-- That's okay, they'll be higher priority next time.

			-- Just in case the user iterates multiple times in a single frame,
			-- lets clear out the leftovers so they don't spill into the second iter
			self._objectRefreshQueue:clear()

			debug.profileend()
			return
		end

		local object = queue:dequeue()
		if not object then
			debug.profileend()
			return
		end

		local objectData = self._objects[object]
		if not objectData then
			debug.profileend()
			return
		end

		local objectDeltaTime = updateStartClock - objectData.lastUpdateClock
		objectData.lastUpdateClock = updateStartClock

		return object, objectDeltaTime, objectData.distance
	end
end

return CullThrottle
