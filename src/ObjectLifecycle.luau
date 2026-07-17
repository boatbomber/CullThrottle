--!strict
--!optimize 2
--!native

--[[
	This module handles the tracked-object lifecycle. It adds and removes
	objects (directly or through CollectionService tags), wires their dimension
	change connections, and polls physics-driven objects whose movement fires
	no property change events.
]]

local CollectionService = game:GetService("CollectionService")

local types = require(script.Parent.types)
local VoxelGrid = require(script.Parent.VoxelGrid)
local VisibilitySignals = require(script.Parent.VisibilitySignals)
local GoodSignal = require(script.Parent.Utilities.GoodSignal)
local ObjectDimensions = require(script.Parent.ObjectDimensions)

local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local tableClear = table.clear

-- Each object's ingest refresh timing is nudged by a random offset in this
-- range (in seconds, either direction) so objects added together don't all
-- cross the refresh-period thresholds in the same frame.
local OBJECT_REFRESH_JITTER = 0.002

local ObjectLifecycle = {}
ObjectLifecycle.__index = ObjectLifecycle

type ObjectLifecycleProto = {
	_grid: VoxelGrid.VoxelGrid,
	_signals: VisibilitySignals.VisibilitySignals,
	-- These are the facade's public signals, injected so this module fires them
	-- without owning them.
	_objectAddedSignal: GoodSignal.Signal<Instance>,
	_objectRemovedSignal: GoodSignal.Signal<Instance>,

	-- This is the tracked-object map. The voxel grid holds an alias of this
	-- table, so it must only ever be mutated in place, never reassigned.
	_objects: { [Instance]: types.ObjectData },
	_objectCount: number,
	_physicsObjects: { Instance },
	_physicsObjectIterIndex: number,
	_tagConnections: { [string]: { RBXScriptConnection } },
}

export type ObjectLifecycle = typeof(setmetatable({} :: ObjectLifecycleProto, ObjectLifecycle))

--[[
	Builds the lifecycle tracker over the given objects map (shared with the
	voxel grid as an alias, so the facade creates it and passes it to both).
]]
function ObjectLifecycle.new(
	objects: { [Instance]: types.ObjectData },
	grid: VoxelGrid.VoxelGrid,
	signals: VisibilitySignals.VisibilitySignals,
	objectAddedSignal: GoodSignal.Signal<Instance>,
	objectRemovedSignal: GoodSignal.Signal<Instance>
): ObjectLifecycle
	local self = setmetatable({
		_grid = grid,
		_signals = signals,
		_objectAddedSignal = objectAddedSignal,
		_objectRemovedSignal = objectRemovedSignal,
		_objects = objects,
		_objectCount = 0,
		_physicsObjects = {},
		_physicsObjectIterIndex = 1,
		_tagConnections = {},
	}, ObjectLifecycle)

	return self
end

--[[
	Round-robin polls the physics-driven objects within the time budget,
	resuming each frame where the last one stopped. Each pass refreshes the
	object's cframe and position, and reslots its voxels when it actually
	moved. Camera distance is not touched here since the ingest pass scores
	it fresh whenever it considers the object.
]]
function ObjectLifecycle.pollPhysicsObjects(self: ObjectLifecycle, timeBudget: number, now: number)
	debug.profilebegin("pollPhysicsObjects")
	local numPhysicsObjects = #self._physicsObjects
	if numPhysicsObjects == 0 then
		debug.profileend()
		return
	end

	-- Removals can leave the saved iteration index pointing past the end of the
	-- list, where reads come back nil and the wrap-around check can trip before
	-- anything is polled, so an out-of-range cursor restarts from the front.
	if self._physicsObjectIterIndex > numPhysicsObjects then
		self._physicsObjectIterIndex = 1
	end
	local startIndex = self._physicsObjectIterIndex

	while os.clock() - now < timeBudget do
		local object = self._physicsObjects[self._physicsObjectIterIndex]
		-- Nothing in this loop mutates the list, so the length hoisted above
		-- stays true for the whole poll.
		self._physicsObjectIterIndex = self._physicsObjectIterIndex % numPhysicsObjects + 1

		if object then
			local objectData = self._objects[object]
			if objectData then
				local cframe = ObjectDimensions.getObjectCFrame(objectData)
				if cframe then
					-- The oriented-box voxel fill is the expensive part of a poll,
					-- so only redo it when the object actually moved.
					local moved = cframe ~= objectData.cframe
					local position = cframe.Position
					objectData.cframe = cframe
					objectData.position = position
					if moved then
						self._grid:updateDesiredVoxelKeys(object, objectData)
					end
				end
			end
		end

		if startIndex == self._physicsObjectIterIndex then
			-- We've looped through the entire list, so there's no need to continue.
			break
		end
	end
	debug.profileend()
end

--[[
	Begins tracking an object. It figures out where the cframe and bounding box
	come from (erroring when either can't be determined), wires the change
	connections that keep them current, slots it into its voxels, and fires
	ObjectAdded. Adding an already-tracked object is a no-op.
]]
function ObjectLifecycle.addObject(self: ObjectLifecycle, object: Instance)
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
		object = object,
		cframe = CFrame.new(),
		position = Vector3.zero,
		distance = 1,
		halfBoundingBox = Vector3.one,
		radius = 0.5,
		voxelKeys = {},
		desiredVoxelKeys = {},
		lastCheckClock = 0,
		lastUpdateClock = 0,
		lastVisibleClock = 0,
		exitSweepBucketIndex = 0,
		exitSweepSlot = 0,
		physicsObjectIndex = 0,
		jitterOffset = (math.random() * 2 - 1) * OBJECT_REFRESH_JITTER,
		changeConnections = {},
		cframeSource = cframeSource,
		cframeType = cframeType :: types.CFrameSourceType,
		boundingBoxSource = boundingBoxSource,
		boundingBoxType = boundingBoxType :: types.BoundingBoxSourceType,
	}

	local cframe = ObjectDimensions.getObjectCFrame(objectData)
	if not cframe then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, cframe is unknown")
	end

	objectData.cframe = cframe
	objectData.position = cframe.Position

	local boundingBox = ObjectDimensions.getObjectBoundingBox(objectData)
	if not boundingBox then
		error("Cannot add " .. object:GetFullName() .. " to CullThrottle, bounding box is unknown")
	end

	objectData.halfBoundingBox = boundingBox / 2
	objectData.radius = vectorMagnitude(objectData.halfBoundingBox)

	ObjectDimensions.wireObjectConnections(object, objectData, {
		onGeometryChanged = function()
			self._grid:updateDesiredVoxelKeys(object, objectData)
		end,
		onUntrackable = function()
			self:removeObject(object)
		end,
		isTracked = function()
			return self._objects[object] ~= nil
		end,
	})

	-- The diff is applied directly below so a query made this same frame already
	-- sees the object in its cells. Passing skipQueue keeps it out of the
	-- deferred maintenance queue, which would otherwise just dequeue an empty
	-- diff and discard it.
	self._grid:updateDesiredVoxelKeys(object, objectData, true)

	self._objects[object] = objectData
	-- The early-return at the top makes addObject idempotent, so a repeat add
	-- can't double-count.
	self._objectCount += 1

	for voxelKey, desired in objectData.desiredVoxelKeys do
		if desired then
			self._grid:insertToVoxel(voxelKey, objectData)
			objectData.voxelKeys[voxelKey] = true
			objectData.desiredVoxelKeys[voxelKey] = nil
		end
	end

	self._objectAddedSignal:Fire(object)
end

--[[
	Begins tracking a part whose movement comes from physics, which fires no
	property change events. This is addObject plus registration in the polled
	_physicsObjects list.

	The stored slot guards against duplicate registration, since a registered
	object always has a nonzero one. addObject above is idempotent, but without
	the check a second addPhysicsObject call would insert the same object into
	_physicsObjects again. Keying the guard off the slot (rather than an
	early-return on self._objects[object]) still lets an already-added static
	object be upgraded to a physics object.
]]
function ObjectLifecycle.addPhysicsObject(self: ObjectLifecycle, object: BasePart)
	self:addObject(object)

	local objectData = self._objects[object]
	if objectData.physicsObjectIndex == 0 then
		local index = #self._physicsObjects + 1
		self._physicsObjects[index] = object
		objectData.physicsObjectIndex = index
	end
end

--[[
	Stops tracking an object. It pulls the object out of the in-view set, the
	pending voxel-update queue, the physics poll list, and its voxels,
	disconnects its change connections, and fires ObjectRemoved. Removing an
	untracked object is a no-op.
]]
function ObjectLifecycle.removeObject(self: ObjectLifecycle, object: Instance)
	local objectData = self._objects[object]
	if not objectData then
		return
	end

	self._objects[object] = nil
	self._objectCount -= 1

	-- Evict the object from the in-view set so the next signalVisibilityChanges
	-- pass doesn't fire a spurious ObjectExitedView for an object we've already
	-- removed (and already fired ObjectRemoved for). Removal is signalled by
	-- ObjectRemoved, not ObjectExitedView.
	self._signals:forget(objectData)

	self._grid:cancelQueuedUpdate(object)

	local physicsObjectIndex = objectData.physicsObjectIndex
	if physicsObjectIndex ~= 0 then
		-- This is a fast unordered remove. The object swapped into this slot
		-- carries its stored index along with it.
		objectData.physicsObjectIndex = 0
		local physicsObjects = self._physicsObjects
		local lastIndex = #physicsObjects
		if physicsObjectIndex ~= lastIndex then
			local swappedObject = physicsObjects[lastIndex]
			physicsObjects[physicsObjectIndex] = swappedObject
			self._objects[swappedObject].physicsObjectIndex = physicsObjectIndex
		end
		physicsObjects[lastIndex] = nil
	end

	for _, connection in objectData.changeConnections do
		connection:Disconnect()
	end
	for voxelKey in objectData.voxelKeys do
		self._grid:removeFromVoxel(voxelKey, objectData)
	end

	self._objectRemovedSignal:Fire(object)
end

--[[
	Adds one tagged instance, choosing physics tracking for unanchored
	BaseParts. captureTag pcalls this per instance, so it lives here as a
	plain module function instead of a fresh closure per add. The variadic
	return annotation is for the pcall wrapping, whose error slot needs the
	callee to admit more than zero results.
]]
local function addTaggedObject(self: ObjectLifecycle, object: Instance): ...any
	if object:IsA("BasePart") and object.Anchored == false then
		self:addPhysicsObject(object)
	else
		self:addObject(object)
	end
end

--[[
	Tracks every instance carrying the tag, now and as the tag set changes.
	Capturing a tag is a bulk, declarative operation where the caller tags a set
	of instances and expects CullThrottle to track whatever it can. But a tagged
	instance may be something we can't size or position (a Folder, a
	Configuration, a Beam without attachments, ...), and addObject/addPhysicsObject
	error() on those. We pcall each add so one un-addable instance can't abort
	capture of the rest, nor throw out of a CollectionService signal handler.
	Direct addObject calls still error() for fail-fast misuse detection. Only
	this tag-driven path is made tolerant.

	A BasePart's Anchored state is read once here to pick between static and
	physics tracking, and deliberately never watched afterwards. Objects don't
	migrate between the two modes, so a part unanchored after capture won't be
	polled (its tracked position freezes until something else updates it). A
	caller who changes a part's anchored state should remove and re-add it, or
	re-toggle its tag, to put it in the right mode.
]]
function ObjectLifecycle.captureTag(self: ObjectLifecycle, tag: string)
	-- Release the prior capture so we don't leak connections.
	self:releaseTag(tag)

	local function tryAddTaggedObject(object: Instance)
		-- The pcall takes the add function and its arguments directly, so a
		-- bulk capture doesn't allocate a wrapper closure per instance.
		local ok, err = pcall(addTaggedObject, self, object)
		if not ok then
			warn(`[CullThrottle] Skipping tagged instance {object:GetFullName()}: {err}`)
		end
	end

	self._tagConnections[tag] = {
		CollectionService:GetInstanceAddedSignal(tag):Connect(tryAddTaggedObject),
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(object: Instance)
			-- An object can carry several captured tags, so it only untracks once
			-- it has lost all of them. The removed tag is already off the object
			-- when this fires, so it can't match itself here. Tracking doesn't
			-- record how an object arrived, so losing the last captured tag
			-- untracks the object even when it was also added directly through
			-- addObject. A caller who wants an object to outlive its tags should
			-- re-add it after the tag toggle.
			for capturedTag in self._tagConnections do
				if object:HasTag(capturedTag) then
					return
				end
			end
			self:removeObject(object)
		end),
	}

	for _, object in CollectionService:GetTagged(tag) do
		tryAddTaggedObject(object)
	end
end

--[[
	Stops watching a captured tag. Objects already tracked through it stay
	tracked, since this only disconnects the tag's add/remove listeners.
]]
function ObjectLifecycle.releaseTag(self: ObjectLifecycle, tag: string)
	local tagConnections = self._tagConnections[tag]
	if not tagConnections then
		return
	end

	for _, connection in tagConnections do
		connection:Disconnect()
	end

	self._tagConnections[tag] = nil
end

--[[
	Removes every tracked object carrying the tag. The matching objects are
	snapshotted before any is removed. removeObject mutates _objects (and
	fires ObjectRemoved, whose handler may mutate it further), so iterating
	_objects directly while removing would be undefined.
]]
function ObjectLifecycle.removeObjectsWithTag(self: ObjectLifecycle, tag: string)
	local toRemove = {}
	local count = 0
	for object in self._objects do
		if object:HasTag(tag) then
			count += 1
			toRemove[count] = object
		end
	end

	for i = 1, count do
		self:removeObject(toRemove[i])
	end
end

--[[
	Disconnects every tag and per-object change connection, then clears the
	tracked set so everything it referenced can be garbage collected.
]]
function ObjectLifecycle.destroy(self: ObjectLifecycle)
	for _, tagConnections in self._tagConnections do
		for _, connection in tagConnections do
			connection:Disconnect()
		end
	end
	tableClear(self._tagConnections)

	for _, objectData in self._objects do
		for _, connection in objectData.changeConnections do
			connection:Disconnect()
		end
	end

	tableClear(self._objects)
	self._objectCount = 0
	tableClear(self._physicsObjects)
end

return ObjectLifecycle
