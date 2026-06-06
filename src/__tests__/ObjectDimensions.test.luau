local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CullThrottle = Packages:WaitForChild("CullThrottle")
local ObjectDimensions = require(CullThrottle:WaitForChild("Utilities"):WaitForChild("ObjectDimensions"))

-- Builds the minimal objectData the dimension getters/connectors read, resolving
-- the cframe/bounding box sources the same way AddObject does.
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

local function makePart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(4, 4, 4)
	part.CFrame = CFrame.new(0, 0, 0)
	part.Parent = workspace
	return part
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
			bone.Parent = part
			local data = resolveData(bone)

			expect(data.cframeType).toBe("Bone")
			expect(typeof(ObjectDimensions.getObjectCFrame(data))).toBe("CFrame")

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

			-- width = max(Width0, Width1) = 4; length = attachment span = 10
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

			expect(received).toBeDefined()

			for _, connection in connections do
				connection:Disconnect()
			end
			model:Destroy()
		end)

		it("returns no connections when there is no cframe source", function()
			local data = { cframeSource = nil, cframeType = nil, changeConnections = {} }
			local connections = ObjectDimensions.connectCFrameChangeEvent(data :: any, function() end)
			expect(#connections).toBe(0)
		end)
	end)
end)
