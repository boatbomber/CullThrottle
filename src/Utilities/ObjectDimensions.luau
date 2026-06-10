--!strict
--!native
--[[
    ObjectDimensions contains utilities for working with objects, such as
    getting their position/size and connecting to change events.
]]

local types = require(script.Parent.Parent.types)
local CameraCache = require(script.Parent.CameraCache)

local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number

local ObjectDimensions = {}

-- Callbacks the owner (CullThrottle) provides so ObjectDimensions can keep an
-- object's geometry and source wiring current without depending on the tracker.
export type ObjectWatchCallbacks = {
	-- The object's cframe/bounding box (or its resolved source) changed; the owner
	-- should refresh any derived state, e.g. which voxels the object occupies.
	onGeometryChanged: () -> (),
	-- The object can no longer be tracked (its source was destroyed, or it was
	-- reparented out of a trackable hierarchy) and should be removed.
	onUntrackable: () -> (),
	-- Whether the owner still tracks the object. A late ancestry signal on an
	-- already-removed object is ignored.
	isTracked: () -> boolean,
}

-- An object centered exactly on the camera has distance == 0, which would make
-- screen size infinite and feed -inf into the priority math. Clamp distance to a
-- tiny positive minimum; objects this close fill the view and sort first anyway.
local MIN_SCREEN_SIZE_DISTANCE = 1e-4

-- A Beam derives both its position and bounding box from its two attachments, so
-- the same warning is emitted from the getter and the change-event wiring for each.
-- Share the strings so the two pairs can't drift apart.
local BEAM_NO_ATTACHMENTS_POSITION_WARNING =
	"[CullThrottle] Cannot determine position of Beam since it does not have attachments"
local BEAM_NO_ATTACHMENTS_BOUNDING_BOX_WARNING =
	"[CullThrottle] Cannot determine bounding box of Beam since it does not have attachments"

function ObjectDimensions.getScreenSize(distance: number, radius: number): number
	-- Calculate the screen size using the precomputed tan(FoV/2)
	return (radius / math.max(distance, MIN_SCREEN_SIZE_DISTANCE)) / CameraCache.TanHalfVertFOV
end

--[[
    Get the source and sourceType for the object's CFrame.
    This allows us to cache the way we get the object's CFrame
    and avoid having to check the object's type every time.
]]
function ObjectDimensions.getObjectCFrameSource(object: Instance): (Instance?, types.CFrameSourceType?)
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

function ObjectDimensions.getObjectBoundingBoxSource(object: Instance): (Instance?, types.BoundingBoxSourceType?)
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
			warn(BEAM_NO_ATTACHMENTS_POSITION_WARNING)
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
			warn(BEAM_NO_ATTACHMENTS_BOUNDING_BOX_WARNING)
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
			warn(BEAM_NO_ATTACHMENTS_POSITION_WARNING)
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
			warn(BEAM_NO_ATTACHMENTS_BOUNDING_BOX_WARNING)
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

-- wireObjectConnections and reresolveObjectSources are mutually recursive
-- (a reparent re-resolves the object's sources, which rewires its listeners),
-- so forward declare them.
local wireObjectConnections: (Instance, types.ObjectData, ObjectWatchCallbacks) -> ()
local reresolveObjectSources: (Instance, types.ObjectData, ObjectWatchCallbacks) -> ()

--[[
	Wire all of an object's change/lifecycle connections: dimension changes that
	keep objectData's geometry current, destruction of the object or a resolved
	source that auto-removes it, and ancestry changes that re-resolve its source.
	Existing connections are torn down first so this can be called again to rewire.
]]
function wireObjectConnections(object: Instance, objectData: types.ObjectData, callbacks: ObjectWatchCallbacks)
	-- Tear down any existing connections first so a rewire (after an ancestor-based
	-- source changes) replaces them instead of leaking the old listeners.
	for _, connection in objectData.changeConnections do
		connection:Disconnect()
	end
	table.clear(objectData.changeConnections)

	ObjectDimensions.subscribeToDimensionChanges(objectData, function(newCFrame: CFrame)
		objectData.cframe = newCFrame
		objectData.distance = vectorMagnitude(newCFrame.Position - CameraCache.Position)
		callbacks.onGeometryChanged()
	end, function(newBoundingBox: Vector3)
		objectData.halfBoundingBox = newBoundingBox / 2
		objectData.radius = vectorMagnitude(objectData.halfBoundingBox)
		callbacks.onGeometryChanged()
	end)

	-- Auto-remove when the tracked instance itself is destroyed.
	table.insert(objectData.changeConnections, object.Destroying:Connect(callbacks.onUntrackable))

	-- Some types resolve their cframe/bounding box from an ancestor: a light or
	-- sound reads its parent part's position, an attachment or bone reads an
	-- ancestor part for its bounding box. That ancestor can be destroyed (or the
	-- object reparented off it) while the tracked instance lives on, after which we
	-- would keep reading the source's frozen last value. Watch each resolved source
	-- that isn't the object itself so we still auto-remove in that case.
	local cframeSourceIsAncestor = objectData.cframeSource ~= object
	local boundingBoxSourceIsAncestor = objectData.boundingBoxSource ~= object
	if cframeSourceIsAncestor then
		table.insert(objectData.changeConnections, objectData.cframeSource.Destroying:Connect(callbacks.onUntrackable))
	end
	if boundingBoxSourceIsAncestor and objectData.boundingBoxSource ~= objectData.cframeSource then
		table.insert(
			objectData.changeConnections,
			objectData.boundingBoxSource.Destroying:Connect(callbacks.onUntrackable)
		)
	end

	-- Reparenting the object can change which ancestor its source resolves to, so
	-- re-resolve (and rewire onto the new sources) whenever its ancestry changes.
	-- Only ancestor-sourced types can change this way; an object that is its own
	-- source always resolves back to itself, so it needs no ancestry listener.
	if cframeSourceIsAncestor or boundingBoxSourceIsAncestor then
		table.insert(
			objectData.changeConnections,
			object.AncestryChanged:Connect(function()
				reresolveObjectSources(object, objectData, callbacks)
			end)
		)
	end
end

--[[
	Re-resolve an object's cframe/bounding box sources after its ancestry changed.
	If a source can no longer be resolved (or produce a value) the object is no
	longer trackable and is removed; otherwise its geometry is refreshed off the
	new sources and its listeners are rewired to match.
]]
function reresolveObjectSources(object: Instance, objectData: types.ObjectData, callbacks: ObjectWatchCallbacks)
	-- Nothing to do for an object the owner has already stopped tracking.
	if not callbacks.isTracked() then
		return
	end

	local cframeSource, cframeType = ObjectDimensions.getObjectCFrameSource(object)
	local boundingBoxSource, boundingBoxType = ObjectDimensions.getObjectBoundingBoxSource(object)

	if not cframeSource or not cframeType or not boundingBoxSource or not boundingBoxType then
		-- The object was reparented somewhere it can no longer be positioned or
		-- sized (e.g. out of the world). It is no longer trackable, so drop it.
		callbacks.onUntrackable()
		return
	end

	if cframeSource == objectData.cframeSource and boundingBoxSource == objectData.boundingBoxSource then
		-- Resolved sources are unchanged, so there's nothing to rewire.
		return
	end

	objectData.cframeSource = cframeSource
	objectData.cframeType = cframeType :: types.CFrameSourceType
	objectData.boundingBoxSource = boundingBoxSource
	objectData.boundingBoxType = boundingBoxType :: types.BoundingBoxSourceType

	local cframe = ObjectDimensions.getObjectCFrame(objectData)
	local boundingBox = ObjectDimensions.getObjectBoundingBox(objectData)
	if not cframe or not boundingBox then
		-- The new source can't currently produce a cframe or bounding box (e.g. a
		-- Beam that lost its attachments). Drop it rather than track stale data.
		callbacks.onUntrackable()
		return
	end

	objectData.cframe = cframe
	objectData.distance = vectorMagnitude(cframe.Position - CameraCache.Position)
	objectData.halfBoundingBox = boundingBox / 2
	objectData.radius = vectorMagnitude(objectData.halfBoundingBox)

	-- Rewire the listeners onto the new sources, then refresh the object's voxels
	-- so its position follows the new source instead of the stale one.
	wireObjectConnections(object, objectData, callbacks)
	callbacks.onGeometryChanged()
end

ObjectDimensions.wireObjectConnections = wireObjectConnections

return ObjectDimensions
