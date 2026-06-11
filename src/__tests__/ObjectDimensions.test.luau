local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CullThrottle = Packages:WaitForChild("CullThrottle")
local ObjectDimensions = require(CullThrottle:WaitForChild("ObjectDimensions"))

--[[
	Builds the minimal objectData the dimension getters/connectors read, resolving
	the cframe/bounding box sources the same way AddObject does.
]]
local function resolveData(object: Instance): any
	local cframeSource, cframeType = ObjectDimensions.getObjectCFrameSource(object)
	local boundingBoxSource, boundingBoxType = ObjectDimensions.getObjectBoundingBoxSource(object)
	return {
		cframeSource = cframeSource,
		cframeType = cframeType,
		boundingBoxSource = boundingBoxSource,
		boundingBoxType = boundingBoxType,
		changeConnections = {},
	}
end

--[[
	Creates an anchored 4x4x4 part at the origin, parented to workspace.
]]
local function makePart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(4, 4, 4)
	part.CFrame = CFrame.new(0, 0, 0)
	part.Parent = workspace
	return part
end

--[[
	Builds the wireObjectConnections callbacks plus a state table the tests assert
	against, tracking how many times each callback fired and the tracked flag
	isTracked reports.
]]
local function makeWatch(): (any, any)
	local state = { geometryChanges = 0, untrackableCalls = 0, tracked = true }
	local callbacks = {
		onGeometryChanged = function()
			state.geometryChanges += 1
		end,
		onUntrackable = function()
			state.untrackableCalls += 1
		end,
		isTracked = function()
			return state.tracked
		end,
	}
	return callbacks, state
end

--[[
	Disconnects every change connection an objectData holds.
]]
local function disconnectAll(data: any)
	for _, connection in data.changeConnections do
		connection:Disconnect()
	end
end

describe("ObjectDimensions", function()
	describe("getObjectCFrameSource / getObjectBoundingBoxSource", function()
		it("resolves a BasePart as its own source", function()
			local part = makePart()

			local cs, ct = ObjectDimensions.getObjectCFrameSource(part)
			expect(cs).toBe(part)
			expect(ct).toBe("BasePart")

			local bs, bt = ObjectDimensions.getObjectBoundingBoxSource(part)
			expect(bs).toBe(part)
			expect(bt).toBe("BasePart")

			part:Destroy()
		end)

		it("returns nil for workspace", function()
			local cs, ct = ObjectDimensions.getObjectCFrameSource(workspace)
			expect(cs).toBeNil()
			expect(ct).toBeNil()

			local bs, bt = ObjectDimensions.getObjectBoundingBoxSource(workspace)
			expect(bs).toBeNil()
			expect(bt).toBeNil()
		end)

		it("returns nil for an orphaned non-spatial instance", function()
			local folder = Instance.new("Folder")

			local cs = ObjectDimensions.getObjectCFrameSource(folder)
			expect(cs).toBeNil()

			local bs = ObjectDimensions.getObjectBoundingBoxSource(folder)
			expect(bs).toBeNil()

			folder:Destroy()
		end)

		it("walks up to an ancestor part for a light's cframe", function()
			local part = makePart()
			local light = Instance.new("PointLight")
			light.Parent = part

			-- A light has no cframe of its own, so the resolver climbs to the part.
			local cs, ct = ObjectDimensions.getObjectCFrameSource(light)
			expect(cs).toBe(part)
			expect(ct).toBe("BasePart")

			-- Its bounding box, however, comes from the light itself.
			local bs, bt = ObjectDimensions.getObjectBoundingBoxSource(light)
			expect(bs).toBe(light)
			expect(bt).toBe("Light")

			part:Destroy()
		end)

		it("classifies a Sound's bounding box source", function()
			local part = makePart()
			local sound = Instance.new("Sound")
			sound.Parent = part

			local bs, bt = ObjectDimensions.getObjectBoundingBoxSource(sound)
			expect(bs).toBe(sound)
			expect(bt).toBe("Sound")

			part:Destroy()
		end)

		it("walks multiple non-spatial levels to find an ancestor part", function()
			local part = makePart()
			local folder = Instance.new("Folder")
			folder.Parent = part
			local sound = Instance.new("Sound")
			sound.Parent = folder

			-- Neither the sound nor the folder above it can be positioned, so the
			-- walk has to recurse through both before landing on the part.
			local cs, ct = ObjectDimensions.getObjectCFrameSource(sound)
			expect(cs).toBe(part)
			expect(ct).toBe("BasePart")

			part:Destroy()
		end)

		it("splits an attachment's sources between itself and its ancestor part", function()
			local part = makePart()
			local attachment = Instance.new("Attachment")
			attachment.Parent = part

			-- An attachment carries its own world cframe but has no size, so its
			-- two sources resolve to different instances.
			local cs, ct = ObjectDimensions.getObjectCFrameSource(attachment)
			expect(cs).toBe(attachment)
			expect(ct).toBe("Attachment")

			local bs, bt = ObjectDimensions.getObjectBoundingBoxSource(attachment)
			expect(bs).toBe(part)
			expect(bt).toBe("BasePart")

			part:Destroy()
		end)

		it("splits a bone's sources between itself and its ancestor part", function()
			local part = makePart()
			local bone = Instance.new("Bone")
			bone.Parent = part

			-- A bone carries its own deformed world cframe but has no size, so
			-- its bounding box walks up to the part.
			local cs, ct = ObjectDimensions.getObjectCFrameSource(bone)
			expect(cs).toBe(bone)
			expect(ct).toBe("Bone")

			local bs, bt = ObjectDimensions.getObjectBoundingBoxSource(bone)
			expect(bs).toBe(part)
			expect(bt).toBe("BasePart")

			part:Destroy()
		end)

		it("resolves a sound's cframe to the attachment it sits in", function()
			local part = makePart()
			part.CFrame = CFrame.new(10, 0, 0)
			local attachment = Instance.new("Attachment")
			attachment.Position = Vector3.new(0, 5, 0)
			attachment.Parent = part
			local sound = Instance.new("Sound")
			sound.RollOffMaxDistance = 20
			sound.Parent = attachment

			-- The ancestor walk stops at the first class it understands, which
			-- here is the attachment rather than the part above it, so the sound
			-- follows the attachment's world cframe.
			local cs, ct = ObjectDimensions.getObjectCFrameSource(sound)
			expect(cs).toBe(attachment)
			expect(ct).toBe("Attachment")

			local cframe = ObjectDimensions.getObjectCFrame(resolveData(sound)) :: CFrame
			expect(cframe.Position).toBe(Vector3.new(10, 5, 0))

			part:Destroy()
		end)
	end)

	describe("getObjectCFrame", function()
		it("reads a BasePart's CFrame directly", function()
			local part = makePart()
			part.CFrame = CFrame.new(5, 6, 7)

			local cframe = ObjectDimensions.getObjectCFrame(resolveData(part)) :: CFrame
			expect(cframe.Position).toBe(Vector3.new(5, 6, 7))

			part:Destroy()
		end)

		it("reads a Model's pivot", function()
			local model = Instance.new("Model")
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(4, 4, 4)
			part.CFrame = CFrame.new(1, 2, 3)
			part.Parent = model
			model.PrimaryPart = part
			model.Parent = workspace

			local cframe = ObjectDimensions.getObjectCFrame(resolveData(model)) :: CFrame
			expect(cframe.Position).toBe(Vector3.new(1, 2, 3))

			model:Destroy()
		end)

		it("reads an Attachment's world cframe", function()
			local part = makePart()
			part.CFrame = CFrame.new(10, 0, 0)
			local attachment = Instance.new("Attachment")
			attachment.Position = Vector3.new(0, 0, 0)
			attachment.Parent = part

			local cframe = ObjectDimensions.getObjectCFrame(resolveData(attachment)) :: CFrame
			expect(cframe.Position).toBe(Vector3.new(10, 0, 0))

			part:Destroy()
		end)

		it("reads a Bone's transformed world cframe", function()
			local part = makePart()
			local bone = Instance.new("Bone")
			bone.CFrame = CFrame.new(0, 5, 0)
			bone.Parent = part
			local data = resolveData(bone)

			expect(data.cframeType).toBe("Bone")

			-- With the part at the origin and no animation transform, the bone's
			-- world cframe is exactly its stored offset, so anything else means the
			-- getter read the wrong property.
			local cframe = ObjectDimensions.getObjectCFrame(data) :: CFrame
			expect(cframe.Position).toBe(Vector3.new(0, 5, 0))

			part:Destroy()
		end)

		it("computes a Beam's cframe as the midpoint between its attachments", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Parent = part

			local cframe = ObjectDimensions.getObjectCFrame(resolveData(beam)) :: CFrame
			expect(cframe.Position).toBe(Vector3.new(5, 0, 0))

			part:Destroy()
		end)

		it("returns nil for a Beam without attachments", function()
			local beam = Instance.new("Beam")
			beam.Parent = workspace

			expect(ObjectDimensions.getObjectCFrame(resolveData(beam))).toBeNil()

			beam:Destroy()
		end)
	end)

	describe("getObjectBoundingBox", function()
		it("reads a BasePart's size", function()
			local part = makePart()
			part.Size = Vector3.new(8, 4, 2)

			expect(ObjectDimensions.getObjectBoundingBox(resolveData(part))).toBe(Vector3.new(8, 4, 2))

			part:Destroy()
		end)

		it("reads a Model's bounding box size", function()
			local model = Instance.new("Model")
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(4, 4, 4)
			part.CFrame = CFrame.new(0, 0, 0)
			part.Parent = model
			model.PrimaryPart = part
			model.Parent = workspace

			expect(ObjectDimensions.getObjectBoundingBox(resolveData(model))).toBe(Vector3.new(4, 4, 4))

			model:Destroy()
		end)

		it("derives a Beam's bounding box from its width and attachment span", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Width0 = 2
			beam.Width1 = 4
			beam.Parent = part

			-- The width is max(Width0, Width1) = 4 and the length is the attachment span of 10.
			expect(ObjectDimensions.getObjectBoundingBox(resolveData(beam))).toBe(Vector3.new(4, 4, 10))

			part:Destroy()
		end)

		it("derives a Light's bounding box from its range", function()
			local part = makePart()
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = part

			expect(ObjectDimensions.getObjectBoundingBox(resolveData(light))).toBe(Vector3.one * 16)

			part:Destroy()
		end)

		it("derives a Sound's bounding box from its rolloff max distance", function()
			local part = makePart()
			local sound = Instance.new("Sound")
			sound.RollOffMaxDistance = 25
			sound.Parent = part

			expect(ObjectDimensions.getObjectBoundingBox(resolveData(sound))).toBe(Vector3.one * 25)

			part:Destroy()
		end)

		it("reads a bone's bounding box from its nearest ancestor part", function()
			local part = makePart()
			part.Size = Vector3.new(6, 2, 8)
			local bone = Instance.new("Bone")
			bone.Parent = part

			-- A bone has no size of its own, so its bounding box is the ancestor
			-- part's.
			expect(ObjectDimensions.getObjectBoundingBox(resolveData(bone))).toBe(Vector3.new(6, 2, 8))

			part:Destroy()
		end)
	end)

	describe("change events", function()
		it("fires the cframe callback when a part moves", function()
			local part = makePart()
			local received
			local connections = ObjectDimensions.connectCFrameChangeEvent(resolveData(part), function(cframe)
				received = cframe
			end)

			part.CFrame = CFrame.new(5, 6, 7)
			task.wait()

			expect((received :: CFrame).Position).toBe(Vector3.new(5, 6, 7))

			for _, connection in connections do
				connection:Disconnect()
			end
			part:Destroy()
		end)

		it("fires the bounding box callback when a part is resized", function()
			local part = makePart()
			local received
			local connections = ObjectDimensions.connectBoundingBoxChangeEvent(resolveData(part), function(boundingBox)
				received = boundingBox
			end)

			part.Size = Vector3.new(8, 8, 8)
			task.wait()

			expect(received).toBe(Vector3.new(8, 8, 8))

			for _, connection in connections do
				connection:Disconnect()
			end
			part:Destroy()
		end)

		it("fires the bounding box callback when a light's range changes", function()
			local part = makePart()
			local light = Instance.new("PointLight")
			light.Range = 10
			light.Parent = part

			local received
			local connections = ObjectDimensions.connectBoundingBoxChangeEvent(resolveData(light), function(boundingBox)
				received = boundingBox
			end)

			light.Range = 20
			task.wait()

			expect(received).toBe(Vector3.one * 20)

			for _, connection in connections do
				connection:Disconnect()
			end
			part:Destroy()
		end)

		it("fires the cframe callback when an attachment moves", function()
			local part = makePart()
			local attachment = Instance.new("Attachment")
			attachment.Position = Vector3.new(0, 0, 0)
			attachment.Parent = part

			local received
			local connections = ObjectDimensions.connectCFrameChangeEvent(resolveData(attachment), function(cframe)
				received = cframe
			end)

			-- WorldCFrame is derived and never fires a property signal, so the
			-- wiring must catch the stored properties that assignments actually
			-- write, while still reporting the world-space frame.
			attachment.Position = Vector3.new(3, 0, 0)
			task.wait()

			expect((received :: CFrame).Position).toBe(Vector3.new(3, 0, 0))

			for _, connection in connections do
				connection:Disconnect()
			end
			part:Destroy()
		end)

		it("fires the cframe callback when a bone's stored cframe changes", function()
			local part = makePart()
			local bone = Instance.new("Bone")
			bone.Parent = part

			local received
			local connections = ObjectDimensions.connectCFrameChangeEvent(resolveData(bone), function(cframe)
				received = cframe
			end)

			-- TransformedWorldCFrame is derived the same way WorldCFrame is, so
			-- the wiring must catch the stored CFrame while reporting the
			-- world-space result. The Transform property fires no changed signal
			-- at all, so the stored CFrame is the only observable move.
			bone.CFrame = CFrame.new(0, 5, 0)
			task.wait()

			expect((received :: CFrame).Position).toBe(Vector3.new(0, 5, 0))

			for _, connection in connections do
				connection:Disconnect()
			end
			part:Destroy()
		end)

		it("connects a primaryless model's cframe change to its WorldPivot", function()
			local model = Instance.new("Model")
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(4, 4, 4)
			part.Parent = model
			model.Parent = workspace
			-- Deliberately leave PrimaryPart unset to exercise the WorldPivot branch.

			local received
			local connections = ObjectDimensions.connectCFrameChangeEvent(resolveData(model), function(cframe)
				received = cframe
			end)

			model.WorldPivot = CFrame.new(3, 0, 0)
			task.wait()

			expect((received :: CFrame).Position).toBe(Vector3.new(3, 0, 0))

			for _, connection in connections do
				connection:Disconnect()
			end
			model:Destroy()
		end)

		it("fires the bounding box callback when a model gains or loses a descendant", function()
			local model = Instance.new("Model")
			local primary = Instance.new("Part")
			primary.Anchored = true
			primary.Size = Vector3.new(4, 4, 4)
			primary.CFrame = CFrame.new(0, 0, 0)
			primary.Parent = model
			model.PrimaryPart = primary
			model.Parent = workspace

			local received
			local connections = ObjectDimensions.connectBoundingBoxChangeEvent(resolveData(model), function(boundingBox)
				received = boundingBox
			end)

			-- Parenting a far-offset part into the model must report the grown box,
			-- spanning from the primary part's -2 to the wing's 22 on X.
			local wing = Instance.new("Part")
			wing.Anchored = true
			wing.Size = Vector3.new(4, 4, 4)
			wing.CFrame = CFrame.new(20, 0, 0)
			wing.Parent = model
			task.wait()

			expect(received).toBeDefined()
			expect((received :: Vector3).X).toBeCloseTo(24)

			-- Removal must refresh the box too. DescendantRemoving fires before the
			-- part actually leaves, so the reported size isn't pinned here, only
			-- that the wiring delivered a real box.
			received = nil
			wing.Parent = workspace
			task.wait()

			expect(typeof(received)).toBe("Vector3")

			for _, connection in connections do
				connection:Disconnect()
			end
			wing:Destroy()
			model:Destroy()
		end)

		it("returns no connections when there is no cframe source", function()
			local data = { cframeSource = nil, cframeType = nil, changeConnections = {} }
			local connections = ObjectDimensions.connectCFrameChangeEvent(data :: any, function() end)
			expect(#connections).toBe(0)
		end)
	end)

	describe("wireObjectConnections", function()
		it("populates changeConnections", function()
			local part = makePart()
			local data = resolveData(part)
			local callbacks = makeWatch()

			ObjectDimensions.wireObjectConnections(part, data, callbacks)
			expect(#data.changeConnections).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
		end)

		it("calls onGeometryChanged and refreshes geometry when the object moves", function()
			local part = makePart()
			local data = resolveData(part)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(part, data, callbacks)

			part.CFrame = CFrame.new(12, 0, 0)
			task.wait()

			expect(state.geometryChanges).toBeGreaterThan(0)
			expect(data.cframe.Position).toBe(Vector3.new(12, 0, 0))

			disconnectAll(data)
			part:Destroy()
		end)

		it("calls onUntrackable when the object is destroyed", function()
			local part = makePart()
			local data = resolveData(part)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(part, data, callbacks)

			part:Destroy()
			task.wait()

			expect(state.untrackableCalls).toBeGreaterThan(0)
		end)

		it("re-resolves the source and refreshes geometry when an ancestor-sourced object is reparented", function()
			local partA = makePart()
			local partB = makePart()
			partB.CFrame = CFrame.new(40, 0, 0)
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = partA

			local data = resolveData(light)
			expect(data.cframeSource).toBe(partA)

			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(light, data, callbacks)

			-- A light reads its position from its parent part, so moving it onto a
			-- different part must re-resolve the source and follow the new position.
			light.Parent = partB
			task.wait()

			expect(data.cframeSource).toBe(partB)
			expect(data.cframe.Position).toBe(Vector3.new(40, 0, 0))
			expect(state.geometryChanges).toBeGreaterThan(0)

			disconnectAll(data)
			partA:Destroy()
			partB:Destroy()
		end)

		it("calls onUntrackable when the object is reparented out of a trackable hierarchy", function()
			local part = makePart()
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = part

			local data = resolveData(light)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(light, data, callbacks)

			-- A Folder has no positional ancestor, so the light can no longer be
			-- placed and must be reported untrackable rather than tracked stale.
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			light.Parent = folder
			task.wait()

			expect(state.untrackableCalls).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
			folder:Destroy()
		end)

		it("ignores an ancestry change once the object is no longer tracked", function()
			local partA = makePart()
			local partB = makePart()
			partB.CFrame = CFrame.new(40, 0, 0)
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = partA

			local data = resolveData(light)
			local callbacks, state = makeWatch()
			state.tracked = false
			ObjectDimensions.wireObjectConnections(light, data, callbacks)

			-- isTracked() reports false, so a late ancestry signal must be ignored.
			-- The source is left untouched and no geometry refresh fires.
			light.Parent = partB
			task.wait()

			expect(data.cframeSource).toBe(partA)
			expect(state.geometryChanges).toBe(0)

			disconnectAll(data)
			partA:Destroy()
			partB:Destroy()
		end)

		it("leaves the wiring intact when an ancestry change resolves to the same sources", function()
			local holder = makePart()
			local part = makePart()
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = part

			local data = resolveData(light)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(light, data, callbacks)
			local connections = table.clone(data.changeConnections)

			-- Reparenting the part fires AncestryChanged on the light, but the
			-- walk still resolves the same part and the light itself, so the
			-- re-resolve must return early without rewiring or dropping anything.
			part.Parent = holder
			task.wait()

			expect(state.untrackableCalls).toBe(0)
			expect(data.cframeSource).toBe(part)
			expect(data.boundingBoxSource).toBe(light)
			expect(#data.changeConnections).toBe(#connections)
			for i, connection in connections do
				expect(data.changeConnections[i]).toBe(connection)
				expect(connection.Connected).toBe(true)
			end

			disconnectAll(data)
			part:Destroy()
			holder:Destroy()
		end)

		it("does not disrupt a self-sourced object when it is reparented", function()
			local part = makePart()
			local holder = makePart()

			local data = resolveData(part)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(part, data, callbacks)

			-- A BasePart is its own source, so it gets no ancestry listener and
			-- reparenting it must neither re-resolve the source nor remove it.
			part.Parent = holder
			task.wait()

			expect(state.untrackableCalls).toBe(0)
			expect(data.cframeSource).toBe(part)

			disconnectAll(data)
			part:Destroy()
			holder:Destroy()
		end)

		it("follows the new primary part after a model's primary part is replaced", function()
			local model = Instance.new("Model")
			local partA = Instance.new("Part")
			partA.Anchored = true
			partA.Size = Vector3.new(4, 4, 4)
			partA.CFrame = CFrame.new(0, 0, 0)
			partA.Parent = model
			local partB = Instance.new("Part")
			partB.Anchored = true
			partB.Size = Vector3.new(4, 4, 4)
			partB.CFrame = CFrame.new(0, 0, 0)
			partB.Parent = model
			model.PrimaryPart = partA
			model.Parent = workspace

			local data = resolveData(model)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(model, data, callbacks)

			-- The pivot listener was wired to partA, so swapping the primary part
			-- must rewire it onto partB for the model's geometry to stay live.
			model.PrimaryPart = partB
			task.wait()

			partB.CFrame = CFrame.new(25, 0, 0)
			task.wait()

			expect(state.geometryChanges).toBeGreaterThan(0)
			expect(data.cframe.Position).toBe(Vector3.new(25, 0, 0))
			expect(state.untrackableCalls).toBe(0)

			disconnectAll(data)
			model:Destroy()
		end)

		it("disconnects the old listeners when a rewire replaces them", function()
			local model = Instance.new("Model")
			local partA = Instance.new("Part")
			partA.Anchored = true
			partA.Size = Vector3.new(4, 4, 4)
			partA.CFrame = CFrame.new(0, 0, 0)
			partA.Parent = model
			local partB = Instance.new("Part")
			partB.Anchored = true
			partB.Size = Vector3.new(4, 4, 4)
			partB.CFrame = CFrame.new(0, 0, 0)
			partB.Parent = model
			model.PrimaryPart = partA
			model.Parent = workspace

			local data = resolveData(model)
			local callbacks = makeWatch()
			ObjectDimensions.wireObjectConnections(model, data, callbacks)

			local oldConnections = table.clone(data.changeConnections)
			local oldCount = #data.changeConnections

			model.PrimaryPart = partB
			task.wait()

			-- A rewire follows the new providers correctly even with the old
			-- listeners leaked, since stale listeners recompute from current
			-- sources. The teardown is only observable here, where every
			-- pre-rewire connection must come back dead.
			for _, connection in oldConnections do
				expect(connection.Connected).toBe(false)
			end

			-- And the rewire replaces the set rather than growing it per rewire.
			expect(#data.changeConnections).toBe(oldCount)

			disconnectAll(data)
			model:Destroy()
		end)

		it("ignores a primary part change once the object is no longer tracked", function()
			local model = Instance.new("Model")
			local partA = Instance.new("Part")
			partA.Anchored = true
			partA.Size = Vector3.new(4, 4, 4)
			partA.CFrame = CFrame.new(0, 0, 0)
			partA.Parent = model
			local partB = Instance.new("Part")
			partB.Anchored = true
			partB.Size = Vector3.new(4, 4, 4)
			partB.CFrame = CFrame.new(30, 0, 0)
			partB.Parent = model
			model.PrimaryPart = partA
			model.Parent = workspace

			local data = resolveData(model)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(model, data, callbacks)
			local connections = table.clone(data.changeConnections)
			state.tracked = false

			-- A late PrimaryPart change for an object the owner already removed
			-- must be swallowed by the tracked check rather than refreshing
			-- geometry or rewiring listeners for it.
			model.PrimaryPart = partB
			task.wait()

			expect(state.geometryChanges).toBe(0)
			expect(state.untrackableCalls).toBe(0)
			expect(#data.changeConnections).toBe(#connections)
			for i, connection in connections do
				expect(data.changeConnections[i]).toBe(connection)
			end

			disconnectAll(data)
			model:Destroy()
		end)

		it("rewires onto a primary part assigned to a previously primaryless model", function()
			local model = Instance.new("Model")
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(4, 4, 4)
			part.CFrame = CFrame.new(0, 0, 0)
			part.Parent = model
			-- PrimaryPart deliberately starts unset, so the model is tracked
			-- through its WorldPivot.
			model.Parent = workspace

			local data = resolveData(model)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(model, data, callbacks)

			-- The PrimaryPart watch is wired unconditionally, so assigning one
			-- later must rewire the model onto it and follow its movement.
			model.PrimaryPart = part
			task.wait()

			part.CFrame = CFrame.new(9, 0, 0)
			task.wait()

			expect(data.cframe.Position).toBe(Vector3.new(9, 0, 0))
			expect(state.untrackableCalls).toBe(0)

			disconnectAll(data)
			model:Destroy()
		end)

		it("falls back to the world pivot when a model's primary part is destroyed", function()
			local model = Instance.new("Model")
			local partA = Instance.new("Part")
			partA.Anchored = true
			partA.Size = Vector3.new(4, 4, 4)
			partA.CFrame = CFrame.new(0, 0, 0)
			partA.Parent = model
			local partB = Instance.new("Part")
			partB.Anchored = true
			partB.Size = Vector3.new(4, 4, 4)
			partB.CFrame = CFrame.new(0, 0, 0)
			partB.Parent = model
			model.PrimaryPart = partA
			model.Parent = workspace

			local data = resolveData(model)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(model, data, callbacks)

			-- Destroying the primary part clears the PrimaryPart property. The
			-- model itself lives on, so it must stay tracked and follow its
			-- WorldPivot instead of freezing at the dead part's last cframe.
			partA:Destroy()
			task.wait()

			expect(state.untrackableCalls).toBe(0)

			model.WorldPivot = CFrame.new(7, 0, 0)
			task.wait()

			expect(data.cframe.Position).toBe(Vector3.new(7, 0, 0))

			disconnectAll(data)
			model:Destroy()
		end)

		it("follows a beam's replacement attachment", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Parent = part

			local data = resolveData(beam)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(beam, data, callbacks)

			-- The geometry listeners were wired to a0 and a1, so swapping in a2
			-- must refresh the midpoint and rewire onto it.
			local a2 = Instance.new("Attachment")
			a2.Position = Vector3.new(20, 0, 0)
			a2.Parent = part
			beam.Attachment0 = a2
			task.wait()

			expect(data.cframe.Position).toBe(Vector3.new(15, 0, 0))

			-- A second swap exercises the attachment watch that the first rewire
			-- itself wired, proving the rewiring is self-sustaining. The midpoint
			-- of a0 at the origin and a1 at 10 is 5.
			beam.Attachment0 = a0
			task.wait()

			expect(data.cframe.Position).toBe(Vector3.new(5, 0, 0))
			expect(state.untrackableCalls).toBe(0)

			disconnectAll(data)
			part:Destroy()
		end)

		it("follows a beam's attachments as they move", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Parent = part

			local data = resolveData(beam)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(beam, data, callbacks)

			-- Moving an attachment must refresh both the beam's midpoint cframe
			-- and its bounding box span. The world-space setter writes through to
			-- the stored CFrame, which is the property the wiring listens to.
			a1.WorldCFrame = CFrame.new(30, 0, 0)
			task.wait()

			expect(data.cframe.Position).toBe(Vector3.new(15, 0, 0))
			-- The box is the beam's widest width square in cross section by the
			-- attachment span of 30 in length. The width is read off the live
			-- beam so a platform default change can't break this pin.
			local width = math.max(beam.Width0, beam.Width1)
			expect(data.halfBoundingBox).toBe(Vector3.new(width, width, 30) / 2)
			expect(state.geometryChanges).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
		end)

		it("refreshes a beam's stored bounding box when its widths change", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Width0 = 2
			beam.Width1 = 2
			beam.Parent = part

			local data = resolveData(beam)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(beam, data, callbacks)

			-- Growing Width0 makes it the widest width, so the stored cross
			-- section must follow it while the length stays at the attachment
			-- span of 10.
			beam.Width0 = 6
			task.wait()

			expect(data.halfBoundingBox).toBe(Vector3.new(3, 3, 5))
			expect(data.radius).toBeCloseTo(math.sqrt(3 ^ 2 + 3 ^ 2 + 5 ^ 2))

			-- Width1 carries its own subscription, so growing it past Width0 must
			-- refresh the box again.
			beam.Width1 = 8
			task.wait()

			expect(data.halfBoundingBox).toBe(Vector3.new(4, 4, 5))
			expect(state.geometryChanges).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
		end)

		it("refreshes a sound's stored bounding box when its rolloff max distance changes", function()
			local part = makePart()
			local sound = Instance.new("Sound")
			sound.RollOffMaxDistance = 10
			sound.Parent = part

			local data = resolveData(sound)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(sound, data, callbacks)

			sound.RollOffMaxDistance = 24
			task.wait()

			expect(data.halfBoundingBox).toBe(Vector3.one * 12)
			expect(data.radius).toBeCloseTo(math.sqrt(12 ^ 2 * 3))
			expect(state.geometryChanges).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
		end)

		it("drops a beam when one of its attachments is destroyed", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Parent = part

			local data = resolveData(beam)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(beam, data, callbacks)

			-- Destroying an attachment neither clears the beam's reference to it
			-- nor fires the attachment property signal, which is exactly why the
			-- wiring keeps a dedicated Destroying watch on each attachment. The
			-- beam can't produce real geometry with a dead attachment, so it must
			-- be reported untrackable rather than left frozen at its last midpoint.
			a0:Destroy()
			task.wait()

			expect(state.untrackableCalls).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
		end)

		it("drops a beam when its attachment reference is cleared to nil", function()
			local part = makePart()
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0, 0)
			a0.Parent = part
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(10, 0, 0)
			a1.Parent = part
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Parent = part

			local data = resolveData(beam)
			local callbacks, state = makeWatch()
			ObjectDimensions.wireObjectConnections(beam, data, callbacks)

			-- Clearing the reference drives the property-signal route, a different
			-- path than the Destroying watch the previous test exercises, since
			-- destruction never fires the property signal. The beam can't produce
			-- geometry with a nil attachment, so it must be reported untrackable.
			beam.Attachment0 = nil
			task.wait()

			expect(state.untrackableCalls).toBeGreaterThan(0)

			disconnectAll(data)
			part:Destroy()
		end)
	end)
end)
