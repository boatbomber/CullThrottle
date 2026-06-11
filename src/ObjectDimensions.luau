--!strict
--!optimize 2
--!native

--[[
	This module owns object geometry. It resolves where each tracked object's
	cframe and bounding box come from (walking up the ancestors when the object
	itself has neither), reads them on demand, and wires the change and
	lifecycle connections that keep an object's geometry current as it moves,
	resizes, or reparents.
]]

local types = require(script.Parent.types)

local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number

local ObjectDimensions = {}

-- These are the callbacks the owner (CullThrottle) provides so ObjectDimensions
-- can keep an object's geometry and source wiring current without depending on
-- the tracker.
export type ObjectWatchCallbacks = {
	-- The object's cframe/bounding box (or its resolved source) changed, so the
	-- owner should refresh any derived state, e.g. which voxels the object
	-- occupies.
	onGeometryChanged: () -> (),
	-- The object can no longer be tracked (its source was destroyed, or it was
	-- reparented out of a trackable hierarchy) and should be removed.
	onUntrackable: () -> (),
	-- This reports whether the owner still tracks the object. A late ancestry
	-- signal on an already-removed object is ignored.
	isTracked: () -> boolean,
}

-- A Beam derives both its position and bounding box from its two attachments, so
-- the same warning is emitted from the getter and the change-event wiring for each.
-- Share the strings so the two pairs can't drift apart.
local BEAM_NO_ATTACHMENTS_POSITION_WARNING =
	"[CullThrottle] Cannot determine position of Beam since it does not have attachments"
local BEAM_NO_ATTACHMENTS_BOUNDING_BOX_WARNING =
	"[CullThrottle] Cannot determine bounding box of Beam since it does not have attachments"

--[[
	Gets the source and sourceType for the object's CFrame, walking up the
	ancestors when the object itself has no position. This allows us to cache
	the way we get the object's CFrame and avoid having to check the object's
	type every time.
]]
function ObjectDimensions.getObjectCFrameSource(object: Instance): (Instance?, types.CFrameSourceType?)
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here.
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

--[[
	Gets the source and sourceType for the object's bounding box, walking up
	the ancestors when the object itself has no size. It's the counterpart of
	getObjectCFrameSource.
]]
function ObjectDimensions.getObjectBoundingBoxSource(object: Instance): (Instance?, types.BoundingBoxSourceType?)
	if object == workspace then
		-- Workspace technically inherits Model,
		-- but the origin vector isn't useful here.
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

--[[
	Reads the object's current CFrame from its resolved source, or nil when
	the source can't currently produce one (e.g. a Beam without attachments).
]]
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

--[[
	Reads the object's current bounding box size from its resolved source, or
	nil when the source can't currently produce one. Lights and sounds size to
	their range/rolloff so their whole area of effect counts.
]]
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

--[[
	Connects the property change events appropriate to the object's CFrame
	source type, invoking the callback with the fresh CFrame.
]]
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
		-- TransformedWorldCFrame is derived, so its property signal never fires.
		-- We listen to the stored CFrame instead and read back the world-space
		-- result. The Transform property fires no changed signal at all (it is
		-- an animation-rate property), so animated bone movement is not
		-- observable through events.
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(typedObject.TransformedWorldCFrame)
			end)
		)
	elseif sourceType == "Attachment" then
		local typedObject: Attachment = object :: Attachment
		-- WorldCFrame is derived, so its property signal never fires. Every
		-- positional setter (Position, WorldCFrame, and friends) writes through
		-- to the stored CFrame, so we listen to that and read back the
		-- world-space frame.
		table.insert(
			connections,
			typedObject:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(typedObject.WorldCFrame)
			end)
		)
	elseif sourceType == "Beam" then
		local typedObject: Beam = object :: Beam
		-- Beams are roughly located between their attachments. The attachments'
		-- WorldCFrames are derived and never signal, so we listen to their
		-- stored CFrames and recompute the world-space midpoint.
		local attachment0, attachment1 = typedObject.Attachment0, typedObject.Attachment1
		if not attachment0 or not attachment1 then
			warn(BEAM_NO_ATTACHMENTS_POSITION_WARNING)
			return connections
		end
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(ObjectDimensions.getObjectCFrame(objectData) or CFrame.identity)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(ObjectDimensions.getObjectCFrame(objectData) or CFrame.identity)
			end)
		)
	end

	return connections
end

--[[
	Connects the property change events appropriate to the object's bounding
	box source type, invoking the callback with the fresh size.
]]
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
		-- without connecting to all descendants size changes.
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
		-- Beams are sized between their attachments with their defined width.
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
		-- The attachments' WorldPositions are derived and never signal, so we
		-- listen to their stored CFrames and recompute the world-space span.
		table.insert(
			connections,
			attachment0:GetPropertyChangedSignal("CFrame"):Connect(function()
				callback(ObjectDimensions.getObjectBoundingBox(objectData) or Vector3.one)
			end)
		)
		table.insert(
			connections,
			attachment1:GetPropertyChangedSignal("CFrame"):Connect(function()
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

--[[
	Wires both dimension listeners (CFrame and bounding box) and records their
	connections in objectData.changeConnections for later teardown.
]]
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

-- wireObjectConnections, refreshGeometryAndRewire, and reresolveObjectSources
-- are mutually recursive (a reparent or reference change refreshes the object's
-- geometry, which rewires its listeners), so we forward declare them.
local wireObjectConnections: (Instance, types.ObjectData, ObjectWatchCallbacks) -> ()
local refreshGeometryAndRewire: (Instance, types.ObjectData, ObjectWatchCallbacks) -> ()
local reresolveObjectSources: (Instance, types.ObjectData, ObjectWatchCallbacks) -> ()

--[[
	Wires all of an object's change/lifecycle connections. That covers dimension
	changes that keep objectData's geometry current, destruction of the object or
	a resolved source that auto-removes it, ancestry changes that re-resolve its
	source, and reference changes (a Model's PrimaryPart, a Beam's attachments)
	that rewire onto the new geometry providers. Existing connections are torn
	down first so this can be called again to rewire.
]]
function wireObjectConnections(object: Instance, objectData: types.ObjectData, callbacks: ObjectWatchCallbacks)
	-- Tear down any existing connections first so a rewire (after an ancestor-based
	-- source changes) replaces them instead of leaking the old listeners.
	for _, connection in objectData.changeConnections do
		connection:Disconnect()
	end
	table.clear(objectData.changeConnections)

	ObjectDimensions.subscribeToDimensionChanges(objectData, function(newCFrame: CFrame)
		local newPosition = newCFrame.Position
		objectData.cframe = newCFrame
		objectData.position = newPosition
		callbacks.onGeometryChanged()
	end, function(newBoundingBox: Vector3)
		objectData.halfBoundingBox = newBoundingBox / 2
		objectData.radius = vectorMagnitude(objectData.halfBoundingBox)
		callbacks.onGeometryChanged()
	end)

	-- Auto-remove when the tracked instance itself is destroyed.
	table.insert(objectData.changeConnections, object.Destroying:Connect(callbacks.onUntrackable))

	-- Some types resolve their cframe/bounding box from an ancestor. A light or
	-- sound reads its parent part's position, and an attachment or bone reads an
	-- ancestor part for its bounding box. That ancestor can be destroyed (or the
	-- object reparented off it) while the tracked instance lives on, after which we
	-- would keep reading the source's frozen last value. We watch each resolved
	-- source that isn't the object itself so we still auto-remove in that case.
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
	-- we re-resolve (and rewire onto the new sources) whenever its ancestry
	-- changes. Only ancestor-sourced types can change this way. An object that is
	-- its own source always resolves back to itself, so it needs no ancestry
	-- listener.
	if cframeSourceIsAncestor or boundingBoxSourceIsAncestor then
		table.insert(
			objectData.changeConnections,
			object.AncestryChanged:Connect(function()
				reresolveObjectSources(object, objectData, callbacks)
			end)
		)
	end

	-- A Model reads its pivot through its PrimaryPart, and a Beam reads its
	-- geometry through its two attachments. Those are reference properties, so
	-- the dimension listeners above are wired to whichever instances they
	-- pointed at just now. When a reference changes (replaced, cleared, or its
	-- target destroyed, which clears it), the old listeners go stale, so we
	-- refresh and rewire onto the current targets. Re-resolving can't cover
	-- this, since the resolved source (the model or beam itself) is unchanged.
	if objectData.cframeType == "Model" then
		local model = objectData.cframeSource :: Model
		table.insert(
			objectData.changeConnections,
			model:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
				refreshGeometryAndRewire(object, objectData, callbacks)
			end)
		)
	end

	local beamSource: Instance? = if objectData.cframeType == "Beam"
		then objectData.cframeSource
		elseif objectData.boundingBoxType == "Beam" then objectData.boundingBoxSource
		else nil
	if beamSource then
		local beam = beamSource :: Beam
		table.insert(
			objectData.changeConnections,
			beam:GetPropertyChangedSignal("Attachment0"):Connect(function()
				refreshGeometryAndRewire(object, objectData, callbacks)
			end)
		)
		table.insert(
			objectData.changeConnections,
			beam:GetPropertyChangedSignal("Attachment1"):Connect(function()
				refreshGeometryAndRewire(object, objectData, callbacks)
			end)
		)

		-- Destroying an attachment doesn't clear the beam's reference to it or
		-- fire the property signal above (only PrimaryPart gets cleared that
		-- way, being ancestry-constrained), so the dead attachment would keep
		-- feeding the listeners its frozen last cframe. The beam can't produce
		-- real geometry without it, so it goes through the untrackable path.
		local attachment0, attachment1 = beam.Attachment0, beam.Attachment1
		if attachment0 then
			table.insert(objectData.changeConnections, attachment0.Destroying:Connect(callbacks.onUntrackable))
		end
		if attachment1 then
			table.insert(objectData.changeConnections, attachment1.Destroying:Connect(callbacks.onUntrackable))
		end
	end
end

--[[
	Refreshes the object's geometry off its current sources and rewires its
	listeners onto whatever instances now provide it, dropping the object when
	the sources can't produce geometry anymore. Both the re-resolve below and
	the reference watches in wireObjectConnections funnel here.
]]
function refreshGeometryAndRewire(object: Instance, objectData: types.ObjectData, callbacks: ObjectWatchCallbacks)
	if not callbacks.isTracked() then
		return
	end

	local cframe = ObjectDimensions.getObjectCFrame(objectData)
	local boundingBox = ObjectDimensions.getObjectBoundingBox(objectData)
	if not cframe or not boundingBox then
		-- The sources can't currently produce a cframe or bounding box (e.g. a
		-- Beam that lost an attachment). Drop the object rather than track
		-- stale data.
		callbacks.onUntrackable()
		return
	end

	objectData.cframe = cframe
	objectData.position = cframe.Position
	objectData.halfBoundingBox = boundingBox / 2
	objectData.radius = vectorMagnitude(objectData.halfBoundingBox)

	-- Rewire the listeners onto the current providers, then refresh the
	-- object's voxels so its position follows them instead of the stale ones.
	wireObjectConnections(object, objectData, callbacks)
	callbacks.onGeometryChanged()
end

--[[
	Re-resolves an object's cframe/bounding box sources after its ancestry changed.
	If a source can no longer be resolved (or produce a value) the object is no
	longer trackable and is removed. Otherwise its geometry is refreshed off the
	new sources and its listeners are rewired to match.
]]
function reresolveObjectSources(object: Instance, objectData: types.ObjectData, callbacks: ObjectWatchCallbacks)
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
		return
	end

	objectData.cframeSource = cframeSource
	objectData.cframeType = cframeType :: types.CFrameSourceType
	objectData.boundingBoxSource = boundingBoxSource
	objectData.boundingBoxType = boundingBoxType :: types.BoundingBoxSourceType

	refreshGeometryAndRewire(object, objectData, callbacks)
end

ObjectDimensions.wireObjectConnections = wireObjectConnections

return ObjectDimensions
