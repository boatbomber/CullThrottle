--!strict
--!native
--[[
    ObjectDimensions contains utilities for working with objects, such as
    getting their position/size and connecting to change events.
]]

local types = require(script.Parent.Parent.types)
local CameraCache = require(script.Parent.CameraCache)

local ObjectDimensions = {}

function ObjectDimensions.getScreenSize(distance: number, radius: number): number
	-- Calculate the screen size using the precomputed tan(FoV/2)
	return (radius / distance) / CameraCache.HalfTanFOV
end

--[[
    Get the source and sourceType for the object's CFrame.
    This allows us to cache the way we get the object's CFrame
    and avoid having to check the object's type every time.
]]
function ObjectDimensions.getObjectCFrameSource(object: Instance): (Instance?, string?)
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
		return ObjectDimensions.getObjectCFrameSource(object.Parent)
	end
end

function ObjectDimensions.getObjectBoundingBoxSource(object: Instance): (Instance?, string?)
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
		return ObjectDimensions.getObjectBoundingBoxSource(object.Parent)
	end
end

function ObjectDimensions.getObjectCFrame(objectData: types.ObjectData): CFrame?
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

function ObjectDimensions.getObjectBoundingBox(objectData: types.ObjectData): Vector3?
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

function ObjectDimensions.connectCFrameChangeEvent(
	objectData: types.ObjectData,
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
				callback(ObjectDimensions.getObjectCFrame(objectData) or CFrame.identity)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("WorldCFrame"):Connect(function()
				callback(ObjectDimensions.getObjectCFrame(objectData) or CFrame.identity)
			end)
		)
	end

	return connections
end

function ObjectDimensions.connectBoundingBoxChangeEvent(
	objectData: types.ObjectData,
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
				callback(ObjectDimensions.getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("Width1"):Connect(function()
				callback(ObjectDimensions.getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("WorldPosition"):Connect(function()
				callback(ObjectDimensions.getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("WorldPosition"):Connect(function()
				callback(ObjectDimensions.getObjectBoundingBox(objectData) or Vector3.one)
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

function ObjectDimensions.subscribeToDimensionChanges(
	objectData: types.ObjectData,
	onCFrameChange: (cframe: CFrame) -> (),
	onBoundingBoxChange: (boundingBox: Vector3) -> ()
)
	local cframeChangeConnections = ObjectDimensions.connectCFrameChangeEvent(objectData, onCFrameChange)
	local boundingBoxChangeConnections = ObjectDimensions.connectBoundingBoxChangeEvent(objectData, onBoundingBoxChange)

	for _, connection in cframeChangeConnections do
		table.insert(objectData.changeConnections, connection)
	end
	for _, connection in boundingBoxChangeConnections do
		table.insert(objectData.changeConnections, connection)
	end
end

return ObjectDimensions
