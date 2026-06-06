local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local CullThrottle = require(CullThrottlePackage)
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))
local ObjectDimensions = require(Utilities:WaitForChild("ObjectDimensions"))

local function createMockPart(position: Vector3?, size: Vector3?, anchored: boolean?)
	local part = Instance.new("Part")
	part.Position = position or Vector3.new(0, 0, 0)
	part.Size = size or Vector3.new(4, 4, 4)
	part.Anchored = if anchored ~= nil then anchored else true
	part.Parent = workspace
	return part
end

local function createMockModel(position: Vector3?, size: Vector3?)
	local model = Instance.new("Model")
	local primaryPart = createMockPart(position, size)
	primaryPart.Parent = model
	model.PrimaryPart = primaryPart
	model.Parent = workspace
	return model
end

describe("CullThrottle", function()
	local cullThrottle

	beforeEach(function()
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil
	end)

	describe("new", function()
		it("should create a new CullThrottle instance", function()
			expect(cullThrottle).toBeDefined()
			expect(cullThrottle._config).toBeDefined()
			expect(cullThrottle._voxels).toEqual({})
			expect(cullThrottle._objects).toEqual({})
			expect(cullThrottle._physicsObjects).toEqual({})
		end)

		it("should initialize event signals", function()
			expect(cullThrottle.ObjectEnteredView).toBeDefined()
			expect(cullThrottle.ObjectExitedView).toBeDefined()
			expect(cullThrottle.ObjectAdded).toBeDefined()
			expect(cullThrottle.ObjectRemoved).toBeDefined()
		end)

		it("should create priority queues", function()
			expect(cullThrottle._updateObjectVoxelsQueue).toBeDefined()
			expect(cullThrottle._visibleObjectsQueue).toBeDefined()
		end)

		it("should setup render connection", function()
			expect(cullThrottle._renderConnection).toBeDefined()
			expect(cullThrottle._renderConnection.Connected).toBe(true)
		end)
	end)

	describe("Destroy", function()
		it("should disconnect the render connection", function()
			expect(cullThrottle._renderConnection.Connected).toBe(true)

			cullThrottle:Destroy()

			expect(cullThrottle._renderConnection.Connected).toBe(false)
		end)

		it("should disconnect tag connections", function()
			local tag = "DestroyTag"
			cullThrottle:CaptureTag(tag)

			local tagConnections = cullThrottle._tagConnections[tag]
			expect(tagConnections).toBeDefined()

			cullThrottle:Destroy()

			for _, connection in tagConnections do
				expect(connection.Connected).toBe(false)
			end
		end)

		it("should disconnect per-object change connections", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]
			expect(#objectData.changeConnections).toBeGreaterThan(0)

			cullThrottle:Destroy()

			for _, connection in objectData.changeConnections do
				expect(connection.Connected).toBe(false)
			end

			part:Destroy()
		end)

		it("should clear all tracked state", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			local physicsPart = createMockPart(nil, nil, false)
			cullThrottle:AddPhysicsObject(physicsPart)

			cullThrottle:Destroy()

			expect(cullThrottle._objects).toEqual({})
			expect(cullThrottle._voxels).toEqual({})
			expect(cullThrottle._physicsObjects).toEqual({})
			expect(next(cullThrottle._objectVisibilityTimestamps)).toBeNil()

			part:Destroy()
			physicsPart:Destroy()
		end)

		it("should drop all signal handlers", function()
			cullThrottle.ObjectAdded:Connect(function() end)
			cullThrottle.ObjectEnteredView:Connect(function() end)

			cullThrottle:Destroy()

			expect(cullThrottle.ObjectAdded._connectionCount).toBe(0)
			expect(cullThrottle.ObjectEnteredView._connectionCount).toBe(0)
			expect(cullThrottle.ObjectExitedView._connectionCount).toBe(0)
			expect(cullThrottle.ObjectRemoved._connectionCount).toBe(0)
		end)

		it("should be safe to call multiple times", function()
			expect(function()
				cullThrottle:Destroy()
				cullThrottle:Destroy()
			end).never.toThrow()
		end)
	end)

	describe("AddObject", function()
		it("should add a Part object", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]

			expect(objectData).toBeDefined()
			expect(objectData.cframe).toBeDefined()
			expect(objectData.halfBoundingBox).toBeDefined()
			expect(objectData.radius).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("should not return the internal objectData", function()
			local part = createMockPart()

			-- AddObject must not leak the private, mutable objectData struct
			expect(cullThrottle:AddObject(part)).toBeNil()

			part:Destroy()
		end)

		it("should add a Model object with PrimaryPart", function()
			local model = createMockModel()
			cullThrottle:AddObject(model)

			expect(cullThrottle._objects[model]).toBeDefined()

			model:Destroy()
		end)

		it("should not add duplicate objects", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData1 = cullThrottle._objects[part]
			cullThrottle:AddObject(part)
			local objectData2 = cullThrottle._objects[part]

			expect(objectData1).toBe(objectData2)

			part:Destroy()
		end)

		it("should fire ObjectAdded event", function()
			local part = createMockPart()
			local fired = false
			local connection = cullThrottle.ObjectAdded:Connect(function(obj)
				fired = obj == part
			end)

			cullThrottle:AddObject(part)
			expect(fired).toBe(true)

			connection:Disconnect()
			part:Destroy()
		end)

		it("should calculate object dimensions correctly", function()
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(10, 10, 10))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]

			expect(objectData.halfBoundingBox).toBe(Vector3.new(5, 5, 5))
			expect(objectData.radius).toBe(5)

			part:Destroy()
		end)

		it("should assign object to correct voxel", function()
			local part = createMockPart(Vector3.new(100, 100, 100))
			cullThrottle:AddObject(part)

			local voxelSize = cullThrottle._config.voxelSize
			local expectedVoxelKey = Vector3.new(100, 100, 100) // voxelSize

			local found = false
			for voxelKey, voxel in cullThrottle._voxels do
				if voxelKey == expectedVoxelKey then
					found = table.find(voxel, part) ~= nil
					break
				end
			end

			expect(found).toBe(true)

			part:Destroy()
		end)

		it("should register a large object in all occupied voxels", function()
			cullThrottle:SetVoxelSize(100)

			-- A 500-long part centered at the origin spans voxels -3..2 on X.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(500, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]

			-- Interior voxels along the length
			expect(objectData.voxelKeys[Vector3.new(-2, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(-1, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(1, 0, 0)]).toBe(true)

			-- And the object is actually inserted into one of those interior voxels
			local interiorVoxel = cullThrottle._voxels[Vector3.new(1, 0, 0)]
			expect(interiorVoxel).toBeDefined()
			expect(table.find(interiorVoxel, part)).toBeDefined()

			part:Destroy()
		end)

		it("should not register a rotated object in the empty corners of its bounding box", function()
			cullThrottle:SetVoxelSize(100)

			-- A long part laid diagonally across the XZ plane. Its world-space
			-- AABB is a big square, but the box only occupies the diagonal band,
			-- so the AABB corners that the box doesn't reach must stay empty.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(600, 20, 20))
			part.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]

			-- Voxels in the empty corners of the AABB are not registered...
			expect(objectData.voxelKeys[Vector3.new(2, 0, 2)]).toBeNil()
			expect(objectData.voxelKeys[Vector3.new(-2, 0, -2)]).toBeNil()

			-- ...but the occupied diagonal voxels still are.
			expect(objectData.voxelKeys[Vector3.new(2, 0, -2)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(-2, 0, 2)]).toBe(true)

			-- Sanity check: we register fewer voxels than the full AABB volume
			-- (x:-3..2, y:-1..0, z:-3..2 = 72), proving we don't just fill the box.
			local count = 0
			for _ in objectData.voxelKeys do
				count += 1
			end
			expect(count).toBeLessThan(72)
			expect(count).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("errors when the object has no resolvable cframe or bounding box", function()
			-- A Folder resolves to neither a cframe nor a bounding box source, so
			-- AddObject must reject it outright rather than silently tracking nothing.
			-- Erroring on unsupported types is documented contract behavior.
			local folder = Instance.new("Folder")
			folder.Parent = workspace

			expect(function()
				cullThrottle:AddObject(folder)
			end).toThrow()

			-- The failed add must leave no trace: not tracked, count unchanged.
			expect(cullThrottle._objects[folder]).toBeNil()
			expect(cullThrottle:IsTracking(folder)).toBe(false)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			folder:Destroy()
		end)
	end)

	describe("AddPhysicsObject", function()
		it("should add unanchored part to physics objects list", function()
			local part = createMockPart(nil, nil, false)
			cullThrottle:AddPhysicsObject(part)

			expect(cullThrottle._objects[part]).toBeDefined()
			expect(table.find(cullThrottle._physicsObjects, part)).toBeDefined()

			part:Destroy()
		end)

		it("should poll physics objects for position changes", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)

			part.Position = Vector3.new(50, 50, 50)

			cullThrottle:_pollPhysicsObjects(1, os.clock())

			local objectData = cullThrottle._objects[part]
			expect(objectData.cframe.Position).toBe(Vector3.new(50, 50, 50))

			part:Destroy()
		end)

		it("should not register duplicates when added twice", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)
			cullThrottle:AddPhysicsObject(part)

			-- The second call must not insert a second entry.
			local count = 0
			for _, candidate in cullThrottle._physicsObjects do
				if candidate == part then
					count += 1
				end
			end
			expect(count).toBe(1)

			part:Destroy()
		end)

		it("should upgrade an already-added static object to a physics object", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			-- AddObject first (static), then AddPhysicsObject (upgrade). The dedup
			-- guard keys off _physicsObjects, not _objects, so the upgrade still works.
			cullThrottle:AddObject(part)
			expect(table.find(cullThrottle._physicsObjects, part)).toBeNil()

			cullThrottle:AddPhysicsObject(part)
			expect(table.find(cullThrottle._physicsObjects, part)).toBeDefined()

			part:Destroy()
		end)

		it("should leave no dangling entry after removing a doubly-added object", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)
			cullThrottle:AddPhysicsObject(part)

			cullThrottle:RemoveObject(part)

			-- Before the fix a duplicate survived RemoveObject's single swap-remove,
			-- leaving an entry whose objectData is gone. _pollPhysicsObjects would then
			-- warn about it every cycle. There must be no trace of the object left.
			expect(table.find(cullThrottle._physicsObjects, part)).toBeNil()
			expect(#cullThrottle._physicsObjects).toBe(0)

			-- Polling the now-empty list must not warn or error.
			cullThrottle:_pollPhysicsObjects(1, os.clock())

			part:Destroy()
		end)
	end)

	describe("RemoveObject", function()
		it("should remove object from tracking", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			cullThrottle:RemoveObject(part)

			expect(cullThrottle._objects[part]).toBeNil()

			part:Destroy()
		end)

		it("should remove object from voxels", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			cullThrottle:RemoveObject(part)

			for _, voxel in cullThrottle._voxels do
				expect(table.find(voxel, part)).toBeNil()
			end

			part:Destroy()
		end)

		it("should fire ObjectRemoved event", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			local fired = false
			local connection = cullThrottle.ObjectRemoved:Connect(function(obj)
				fired = obj == part
			end)

			cullThrottle:RemoveObject(part)
			expect(fired).toBe(true)

			connection:Disconnect()
			part:Destroy()
		end)

		it("should remove physics object from physics list", function()
			local part = createMockPart(nil, nil, false)
			cullThrottle:AddPhysicsObject(part)
			cullThrottle:RemoveObject(part)

			expect(table.find(cullThrottle._physicsObjects, part)).toBeNil()

			part:Destroy()
		end)

		it("should handle removing non-existent object gracefully", function()
			local part = createMockPart()
			expect(function()
				cullThrottle:RemoveObject(part)
			end).never.toThrow()

			part:Destroy()
		end)

		it("should release the object when it is destroyed externally", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			expect(cullThrottle._objects[part]).toBeDefined()

			-- Idiomatic Roblox cleanup is object:Destroy(), without ever calling
			-- RemoveObject. CullThrottle should still let go of it.
			part:Destroy()
			task.wait()

			expect(cullThrottle._objects[part]).toBeNil()
		end)

		it("should remove the object from voxels when it is destroyed externally", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			part:Destroy()
			task.wait()

			for _, voxel in cullThrottle._voxels do
				expect(table.find(voxel, part)).toBeNil()
			end
		end)

		it("should fire ObjectRemoved when the object is destroyed externally", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			local fired = false
			local connection = cullThrottle.ObjectRemoved:Connect(function(obj)
				fired = obj == part
			end)

			part:Destroy()
			task.wait()

			expect(fired).toBe(true)

			connection:Disconnect()
		end)

		it("should release a physics object when it is destroyed externally", function()
			local part = createMockPart(nil, nil, false)
			cullThrottle:AddPhysicsObject(part)
			expect(table.find(cullThrottle._physicsObjects, part)).toBeDefined()

			part:Destroy()
			task.wait()

			expect(cullThrottle._objects[part]).toBeNil()
			expect(table.find(cullThrottle._physicsObjects, part)).toBeNil()
		end)

		it("should not fire ObjectExitedView for an object that was removed while visible", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)

			-- Mark the object as having been visible.
			local now = os.clock()
			cullThrottle._objectVisibilityTimestamps[part] = now

			cullThrottle:RemoveObject(part)

			-- The visibility timestamp must be cleared so the next pass doesn't see a
			-- stale "was visible last frame, gone this frame" entry and fire a stray
			-- ObjectExitedView for an object we've already removed.
			expect(cullThrottle._objectVisibilityTimestamps[part]).toBeNil()

			local exited = false
			local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
				if obj == part then
					exited = true
				end
			end)

			cullThrottle:_signalVisibilityChanges(now + 1)
			cullThrottle:_flushVisibilitySignals()
			expect(exited).toBe(false)

			connection:Disconnect()
			part:Destroy()
		end)
	end)

	describe("CaptureTag", function()
		it("should capture all objects with a tag", function()
			local tag = "TestTag"
			local part1 = createMockPart()
			local part2 = createMockPart()

			CollectionService:AddTag(part1, tag)
			CollectionService:AddTag(part2, tag)

			cullThrottle:CaptureTag(tag)

			expect(cullThrottle._objects[part1]).toBeDefined()
			expect(cullThrottle._objects[part2]).toBeDefined()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(part1, tag)
			CollectionService:RemoveTag(part2, tag)
			part1:Destroy()
			part2:Destroy()
		end)

		it("should track new objects added with tag", function()
			local tag = "TestTag"
			cullThrottle:CaptureTag(tag)

			local part = createMockPart()
			CollectionService:AddTag(part, tag)

			task.wait()
			expect(cullThrottle._objects[part]).toBeDefined()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(part, tag)
			part:Destroy()
		end)

		it("should stop tracking objects when tag is removed", function()
			local tag = "TestTag"
			local part = createMockPart()
			CollectionService:AddTag(part, tag)

			cullThrottle:CaptureTag(tag)
			expect(cullThrottle._objects[part]).toBeDefined()

			CollectionService:RemoveTag(part, tag)
			task.wait()
			expect(cullThrottle._objects[part]).toBeNil()

			cullThrottle:ReleaseTag(tag)
			part:Destroy()
		end)

		it("should skip an un-addable tagged instance without aborting the rest of the capture", function()
			local tag = "MixedCaptureTag"
			local part1 = createMockPart()
			-- A Folder has no resolvable CFrame/bounding box, so AddObject errors on it.
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			local part2 = createMockPart()

			CollectionService:AddTag(part1, tag)
			CollectionService:AddTag(folder, tag)
			CollectionService:AddTag(part2, tag)

			-- The un-addable folder must not throw out of CaptureTag. If it did, it
			-- would abort the GetTagged loop and leave whichever parts come after it
			-- (iteration order is unspecified) untracked.
			expect(function()
				cullThrottle:CaptureTag(tag)
			end).never.toThrow()

			-- Both valid parts are captured regardless of order; the folder is skipped.
			expect(cullThrottle._objects[part1]).toBeDefined()
			expect(cullThrottle._objects[part2]).toBeDefined()
			expect(cullThrottle._objects[folder]).toBeNil()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(part1, tag)
			CollectionService:RemoveTag(folder, tag)
			CollectionService:RemoveTag(part2, tag)
			part1:Destroy()
			folder:Destroy()
			part2:Destroy()
		end)

		it("should not throw when every tagged instance is un-addable", function()
			local tag = "UnaddableCaptureTag"
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			CollectionService:AddTag(folder, tag)

			expect(function()
				cullThrottle:CaptureTag(tag)
			end).never.toThrow()
			expect(cullThrottle._objects[folder]).toBeNil()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(folder, tag)
			folder:Destroy()
		end)

		it("should disconnect the previous connections when a tag is re-captured", function()
			local tag = "RecaptureTag"
			cullThrottle:CaptureTag(tag)

			-- Hold a reference to the first capture's connections before re-capturing.
			local firstConnections = cullThrottle._tagConnections[tag]
			expect(firstConnections).toBeDefined()

			cullThrottle:CaptureTag(tag)

			-- The first capture's connections must be disconnected, not left dangling.
			-- Leaked connections stay live and double-handle every tagged add/remove.
			for _, connection in firstConnections do
				expect(connection.Connected).toBe(false)
			end

			-- The live entry is a fresh, fully-connected set.
			expect(cullThrottle._tagConnections[tag]).never.toBe(firstConnections)
			for _, connection in cullThrottle._tagConnections[tag] do
				expect(connection.Connected).toBe(true)
			end

			cullThrottle:ReleaseTag(tag)
		end)
	end)

	describe("ReleaseTag", function()
		it("should disconnect tag connections", function()
			local tag = "TestTag"
			cullThrottle:CaptureTag(tag)

			expect(cullThrottle._tagConnections[tag]).toBeDefined()

			cullThrottle:ReleaseTag(tag)

			local part = createMockPart()
			CollectionService:AddTag(part, tag)
			task.wait()

			expect(cullThrottle._objects[part]).toBeNil()

			CollectionService:RemoveTag(part, tag)
			part:Destroy()
		end)

		it("should clear the tag connection entry", function()
			local tag = "ClearedTag"
			cullThrottle:CaptureTag(tag)
			expect(cullThrottle._tagConnections[tag]).toBeDefined()

			cullThrottle:ReleaseTag(tag)

			-- The entry (and its now-dead connection objects) must be dropped, not
			-- left as a stale truthy "captured" marker referencing disconnected
			-- connections.
			expect(cullThrottle._tagConnections[tag]).toBeNil()
		end)
	end)

	describe("RemoveObjectsWithTag", function()
		it("should remove all objects with specified tag", function()
			local tag = "TestTag"
			local part1 = createMockPart()
			local part2 = createMockPart()
			local part3 = createMockPart()

			CollectionService:AddTag(part1, tag)
			CollectionService:AddTag(part2, tag)

			cullThrottle:AddObject(part1)
			cullThrottle:AddObject(part2)
			cullThrottle:AddObject(part3)

			cullThrottle:RemoveObjectsWithTag(tag)

			expect(cullThrottle._objects[part1]).toBeNil()
			expect(cullThrottle._objects[part2]).toBeNil()
			expect(cullThrottle._objects[part3]).toBeDefined()

			CollectionService:RemoveTag(part1, tag)
			CollectionService:RemoveTag(part2, tag)
			part1:Destroy()
			part2:Destroy()
			part3:Destroy()
		end)

		it("should snapshot before removing so an ObjectRemoved handler may mutate _objects", function()
			-- RemoveObjectsWithTag must not iterate _objects live while removing,
			-- because RemoveObject fires ObjectRemoved and a handler may add or
			-- remove tracked objects. Snapshotting the matches first makes that
			-- mid-removal mutation safe.
			local tag = "ReentrancyTag"
			local tagged = {}
			for i = 1, 5 do
				local part = createMockPart(Vector3.new(i * 10, 0, 0))
				CollectionService:AddTag(part, tag)
				cullThrottle:AddObject(part)
				tagged[i] = part
			end

			-- An untagged object the handler adds partway through the removal.
			local extra = createMockPart(Vector3.new(0, 500, 0))

			local connection = cullThrottle.ObjectRemoved:Connect(function()
				if not cullThrottle._objects[extra] then
					cullThrottle:AddObject(extra)
				end
			end)

			expect(function()
				cullThrottle:RemoveObjectsWithTag(tag)
			end).never.toThrow()

			-- Every tagged object was removed despite the mid-loop insertion...
			for _, part in tagged do
				expect(cullThrottle._objects[part]).toBeNil()
			end
			-- ...and the object added by the handler survived (it isn't tagged, so
			-- the pre-removal snapshot never included it).
			expect(cullThrottle._objects[extra]).toBeDefined()

			connection:Disconnect()
			for _, part in tagged do
				CollectionService:RemoveTag(part, tag)
				part:Destroy()
			end
			extra:Destroy()
		end)
	end)

	describe("SetVoxelSize", function()
		it("should update voxel size configuration", function()
			local newVoxelSize = 100
			cullThrottle:SetVoxelSize(newVoxelSize)

			expect(cullThrottle._config.voxelSize).toBe(newVoxelSize)
		end)

		it("should reassign objects to new voxels", function()
			local part = createMockPart(Vector3.new(150, 150, 150))
			cullThrottle:AddObject(part)

			local oldVoxelSize = cullThrottle._config.voxelSize
			local newVoxelSize = oldVoxelSize * 2

			cullThrottle:SetVoxelSize(newVoxelSize)
			cullThrottle:_updateObjectVoxels(1, os.clock())

			local newVoxelKey = Vector3.new(150, 150, 150) // newVoxelSize
			local found = false
			for voxelKey, voxel in cullThrottle._voxels do
				if voxelKey == newVoxelKey then
					found = table.find(voxel, part) ~= nil
					break
				end
			end

			expect(found).toBe(true)

			part:Destroy()
		end)

		it("should reject a non-positive voxel size", function()
			expect(function()
				cullThrottle:SetVoxelSize(0)
			end).toThrow()
			expect(function()
				cullThrottle:SetVoxelSize(-50)
			end).toThrow()
		end)
	end)

	describe("SetRenderDistanceTarget", function()
		it("should update render distance configuration", function()
			local newDistance = 500
			cullThrottle:SetRenderDistanceTarget(newDistance)

			expect(cullThrottle._config.renderDistanceTarget).toBe(newDistance)
			expect(cullThrottle._config._renderDistance).toBe(newDistance)
			expect(cullThrottle._config._minRenderDistance).toBeCloseTo(newDistance / 3)
			expect(cullThrottle._config._maxRenderDistance).toBe(newDistance * 5)
		end)

		it("should reject a non-positive render distance", function()
			expect(function()
				cullThrottle:SetRenderDistanceTarget(0)
			end).toThrow()
			expect(function()
				cullThrottle:SetRenderDistanceTarget(-100)
			end).toThrow()
		end)
	end)

	describe("SetTimeBudgets", function()
		it("should update time budget configurations", function()
			local searchBudget = 0.002
			local ingestBudget = 0.003
			local updateBudget = 0.004

			cullThrottle:SetTimeBudgets(searchBudget, ingestBudget, updateBudget)

			expect(cullThrottle._config.searchTimeBudget).toBe(searchBudget)
			expect(cullThrottle._config.ingestTimeBudget).toBe(ingestBudget)
			expect(cullThrottle._config.updateTimeBudget).toBe(updateBudget)
		end)

		it("should reject a negative time budget", function()
			expect(function()
				cullThrottle:SetTimeBudgets(-0.001, 0.003, 0.004)
			end).toThrow()
			expect(function()
				cullThrottle:SetTimeBudgets(0.002, -0.003, 0.004)
			end).toThrow()
			expect(function()
				cullThrottle:SetTimeBudgets(0.002, 0.003, -0.004)
			end).toThrow()
		end)

		it("should allow zero time budgets", function()
			expect(function()
				cullThrottle:SetTimeBudgets(0, 0, 0)
			end).never.toThrow()

			expect(cullThrottle._config.searchTimeBudget).toBe(0)
			expect(cullThrottle._config.ingestTimeBudget).toBe(0)
			expect(cullThrottle._config.updateTimeBudget).toBe(0)
		end)
	end)

	describe("SetRefreshRates", function()
		it("should convert Hz rates to seconds-between-refreshes periods", function()
			local bestHz = 30
			local worstHz = 5

			cullThrottle:SetRefreshRates(bestHz, worstHz)

			expect(cullThrottle._config.bestRefreshRate).toBeCloseTo(1 / bestHz)
			expect(cullThrottle._config.worstRefreshRate).toBeCloseTo(1 / worstHz)
		end)

		it("should derive a positive range and midpoint from the periods", function()
			local bestHz = 60
			local worstHz = 15

			cullThrottle:SetRefreshRates(bestHz, worstHz)

			local bestPeriod = 1 / bestHz
			local worstPeriod = 1 / worstHz

			expect(cullThrottle._config._refreshRateRange).toBeCloseTo(worstPeriod - bestPeriod)
			expect(cullThrottle._config._refreshRateRange > 0).toBe(true)
			expect(cullThrottle._config._refreshRateMidpoint).toBeCloseTo((bestPeriod + worstPeriod) / 2)
		end)

		it("should accept equal best and worst rates", function()
			cullThrottle:SetRefreshRates(20, 20)

			expect(cullThrottle._config.bestRefreshRate).toBeCloseTo(1 / 20)
			expect(cullThrottle._config.worstRefreshRate).toBeCloseTo(1 / 20)
			expect(cullThrottle._config._refreshRateRange).toBeCloseTo(0)
		end)

		it("should reject a best rate slower than the worst rate", function()
			expect(function()
				cullThrottle:SetRefreshRates(5, 30)
			end).toThrow()
		end)

		it("should reject non-positive rates", function()
			expect(function()
				cullThrottle:SetRefreshRates(0, 15)
			end).toThrow()
			expect(function()
				cullThrottle:SetRefreshRates(60, -1)
			end).toThrow()
		end)
	end)

	describe("SetComputeVisibilityOnlyOnDemand", function()
		it("should update computeVisibilityOnlyOnDemand setting", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)
			expect(cullThrottle._config.computeVisibilityOnlyOnDemand).toBe(true)

			cullThrottle:SetComputeVisibilityOnlyOnDemand(false)
			expect(cullThrottle._config.computeVisibilityOnlyOnDemand).toBe(false)
		end)

		it("still resolves visibility when queried directly in on-demand mode", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			-- Generous budgets so the on-demand query runs the full precise pass.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1

			-- In on-demand mode the render loop never computes visibility, but an
			-- explicit query must still process it on the spot.
			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(table.find(visibleObjects, part)).never.toBeNil()

			part:Destroy()
		end)
	end)

	describe("SetStrictlyEnforceWorstRefreshRate", function()
		it("should update strictlyEnforceWorstRefreshRate setting", function()
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			expect(cullThrottle._config.strictlyEnforceWorstRefreshRate).toBe(true)

			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)
			expect(cullThrottle._config.strictlyEnforceWorstRefreshRate).toBe(false)
		end)
	end)

	describe("SetDynamicRenderDistance", function()
		it("should update dynamicRenderDistance setting", function()
			cullThrottle:SetDynamicRenderDistance(true)
			expect(cullThrottle._config.dynamicRenderDistance).toBe(true)

			cullThrottle:SetDynamicRenderDistance(false)
			expect(cullThrottle._config.dynamicRenderDistance).toBe(false)
		end)
	end)

	describe("getScreenSize", function()
		it("should return a finite screen size for an object at the camera", function()
			-- distance == 0 would divide by zero and produce an infinite screen
			-- size, which feeds -inf into the priority math downstream
			local screenSize = ObjectDimensions.getScreenSize(0, 4)

			expect(screenSize == math.huge).toBe(false)
			expect(screenSize ~= screenSize).toBe(false)
			expect(screenSize > 0).toBe(true)
		end)

		it("should grow as the object gets closer", function()
			local near = ObjectDimensions.getScreenSize(10, 4)
			local far = ObjectDimensions.getScreenSize(100, 4)

			expect(near > far).toBe(true)
		end)
	end)

	describe("Configuration getters", function()
		it("should read back the voxel size", function()
			cullThrottle:SetVoxelSize(50)
			expect(cullThrottle:GetVoxelSize()).toBe(50)
		end)

		it("should read back the render distance target", function()
			cullThrottle:SetRenderDistanceTarget(500)
			expect(cullThrottle:GetRenderDistanceTarget()).toBe(500)
		end)

		it("should read back the time budgets in seconds", function()
			cullThrottle:SetTimeBudgets(0.002, 0.003, 0.004)

			local search, ingest, update = cullThrottle:GetTimeBudgets()
			expect(search).toBe(0.002)
			expect(ingest).toBe(0.003)
			expect(update).toBe(0.004)
		end)

		it("should read back the refresh rates in Hz, symmetric with the setter", function()
			cullThrottle:SetRefreshRates(60, 15)

			local bestHz, worstHz = cullThrottle:GetRefreshRates()
			expect(bestHz).toBeCloseTo(60)
			expect(worstHz).toBeCloseTo(15)
		end)

		it("should read back the boolean flags", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:SetDynamicRenderDistance(false)

			expect(cullThrottle:GetComputeVisibilityOnlyOnDemand()).toBe(true)
			expect(cullThrottle:GetStrictlyEnforceWorstRefreshRate()).toBe(true)
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(false)
		end)

		it("should expose the live render distance, distinct from the target", function()
			cullThrottle:SetRenderDistanceTarget(600)
			expect(cullThrottle:GetRenderDistance()).toBe(600)

			-- Simulate the dynamic controller having adjusted the effective distance
			-- down from the target; the getter reports the live value, not the target.
			cullThrottle._config._renderDistance = 450
			expect(cullThrottle:GetRenderDistance()).toBe(450)
			expect(cullThrottle:GetRenderDistanceTarget()).toBe(600)
		end)
	end)

	describe("IsTracking", function()
		it("should report whether an object is tracked", function()
			local part = createMockPart()

			expect(cullThrottle:IsTracking(part)).toBe(false)

			cullThrottle:AddObject(part)
			expect(cullThrottle:IsTracking(part)).toBe(true)

			cullThrottle:RemoveObject(part)
			expect(cullThrottle:IsTracking(part)).toBe(false)

			part:Destroy()
		end)
	end)

	describe("GetTrackedObjects", function()
		it("should return every tracked object", function()
			local a = createMockPart(Vector3.new(0, 0, 0))
			local b = createMockPart(Vector3.new(500, 0, 0))
			cullThrottle:AddObject(a)
			cullThrottle:AddObject(b)

			local tracked = cullThrottle:GetTrackedObjects()
			expect(#tracked).toBe(2)
			expect(table.find(tracked, a)).never.toBeNil()
			expect(table.find(tracked, b)).never.toBeNil()

			a:Destroy()
			b:Destroy()
		end)

		it("should return a snapshot that cannot mutate internal state", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			local tracked = cullThrottle:GetTrackedObjects()
			table.clear(tracked)

			expect(cullThrottle:IsTracking(part)).toBe(true)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			part:Destroy()
		end)
	end)

	describe("GetTrackedObjectCount", function()
		it("should track the count across add and remove", function()
			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			local a = createMockPart(Vector3.new(0, 0, 0))
			local b = createMockPart(Vector3.new(500, 0, 0))

			cullThrottle:AddObject(a)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			cullThrottle:AddObject(b)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(2)

			cullThrottle:RemoveObject(a)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			a:Destroy()
			b:Destroy()
		end)

		it("should not double-count an idempotent re-add", function()
			local part = createMockPart()

			cullThrottle:AddObject(part)
			cullThrottle:AddObject(part)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			part:Destroy()
		end)

		it("should not underflow when removing an untracked object", function()
			local part = createMockPart()

			cullThrottle:RemoveObject(part)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			part:Destroy()
		end)

		it("should stay correct through RemoveObjectsWithTag", function()
			local tag = "TrackedCountTag"
			local tagged = {}
			for i = 1, 4 do
				local part = createMockPart(Vector3.new(i * 10, 0, 0))
				CollectionService:AddTag(part, tag)
				cullThrottle:AddObject(part)
				tagged[i] = part
			end

			local untagged = createMockPart(Vector3.new(0, 500, 0))
			cullThrottle:AddObject(untagged)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(5)

			cullThrottle:RemoveObjectsWithTag(tag)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			for _, part in tagged do
				CollectionService:RemoveTag(part, tag)
				part:Destroy()
			end
			untagged:Destroy()
		end)
	end)

	describe("GetPerformanceMetrics", function()
		it("should return a snapshot with the documented metric fields", function()
			local metrics = cullThrottle:GetPerformanceMetrics()

			expect(type(metrics.searchDuration)).toBe("number")
			expect(type(metrics.ingestDuration)).toBe("number")
			expect(type(metrics.skippedSearch)).toBe("number")
			expect(type(metrics.skippedIngest)).toBe("number")
			expect(type(metrics.averageObjectDeltaTime)).toBe("number")
		end)

		it("should reflect the latest internal metrics", function()
			cullThrottle._perfMetrics._searchDuration = 0.00123
			cullThrottle._perfMetrics._ingestDuration = 0.00456
			cullThrottle._perfMetrics._skippedSearch[1] = 7
			cullThrottle._perfMetrics._skippedIngest[1] = 9
			cullThrottle._perfMetrics._averageObjectDeltaTime = 0.025

			local metrics = cullThrottle:GetPerformanceMetrics()
			expect(metrics.searchDuration).toBe(0.00123)
			expect(metrics.ingestDuration).toBe(0.00456)
			expect(metrics.skippedSearch).toBe(7)
			expect(metrics.skippedIngest).toBe(9)
			expect(metrics.averageObjectDeltaTime).toBe(0.025)
		end)

		it("should return a fresh snapshot that cannot corrupt internal metrics", function()
			local metrics = cullThrottle:GetPerformanceMetrics()
			metrics.searchDuration = 999
			metrics.skippedSearch = 999

			expect(cullThrottle._perfMetrics._searchDuration).never.toBe(999)
			expect(cullThrottle._perfMetrics._skippedSearch[1]).never.toBe(999)
		end)
	end)

	describe("GetVisibleObjects", function()
		it("should return empty array when no objects are visible", function()
			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(#visibleObjects).toBe(0)
		end)

		it("should return visible objects after processing", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)

			cullThrottle:_processObjectVisibility(os.clock())

			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(type(visibleObjects)).toBe("table")

			part:Destroy()
		end)

		it("should not duplicate a multi-voxel object under fast-approximation fallback", function()
			cullThrottle:SetVoxelSize(100)

			-- A long part occupies several voxel buckets, so the fast-approximation
			-- path would emit it once per voxel if it didn't deduplicate.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(500, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]

			local visibleVoxelKeys = {}
			for voxelKey in objectData.voxelKeys do
				table.insert(visibleVoxelKeys, voxelKey)
			end
			cullThrottle._visibleVoxelKeys = visibleVoxelKeys
			cullThrottle._visibleVoxelCount = #visibleVoxelKeys

			-- Drive the fast-approximation path directly over every occupied voxel.
			cullThrottle:_fastApproxIngestRemainingVoxels(os.clock(), 1)

			local items = cullThrottle._visibleObjectsQueue._incomingBatch.items
			local occurrences = 0
			for _, object in items do
				if object == part then
					occurrences += 1
				end
			end

			expect(#visibleVoxelKeys).toBeGreaterThan(1)
			expect(occurrences).toBe(1)

			part:Destroy()
		end)

		it("should not re-add an object the precise ingest pass already handled", function()
			cullThrottle:SetVoxelSize(100)

			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(500, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]

			local now = os.clock()
			-- Simulate the precise ingest pass having already handled this object
			-- this frame (it spans both a precisely-ingested and a fast-path voxel).
			objectData.lastCheckClock = now
			cullThrottle._visibleObjectsQueue:addToIncomingBatch(part, 0)

			local visibleVoxelKeys = {}
			for voxelKey in objectData.voxelKeys do
				table.insert(visibleVoxelKeys, voxelKey)
			end
			cullThrottle._visibleVoxelKeys = visibleVoxelKeys
			cullThrottle._visibleVoxelCount = #visibleVoxelKeys

			cullThrottle:_fastApproxIngestRemainingVoxels(now, 1)

			local items = cullThrottle._visibleObjectsQueue._incomingBatch.items
			local occurrences = 0
			for _, object in items do
				if object == part then
					occurrences += 1
				end
			end

			expect(occurrences).toBe(1)

			part:Destroy()
		end)

		it("returns objects in the frustum and excludes ones behind or beyond render distance", function()
			-- Place objects relative to the live camera so the real frustum pass,
			-- not a hand-built plane set, decides what is visible.
			local camera = workspace.CurrentCamera
			local camCFrame = camera.CFrame

			local frontPart = createMockPart((camCFrame * CFrame.new(0, 0, -80)).Position)
			local behindPart = createMockPart((camCFrame * CFrame.new(0, 0, 120)).Position)
			local farPart = createMockPart((camCFrame * CFrame.new(0, 0, -5000)).Position)

			cullThrottle:AddObject(frontPart)
			cullThrottle:AddObject(behindPart)
			cullThrottle:AddObject(farPart)

			-- Generous budgets so the search and precise ingest run to completion.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1

			local visibleObjects = cullThrottle:GetVisibleObjects()

			-- The object in front and within range is visible; the one behind the
			-- camera and the one well past render distance are not.
			expect(table.find(visibleObjects, frontPart)).never.toBeNil()
			expect(table.find(visibleObjects, behindPart)).toBeNil()
			expect(table.find(visibleObjects, farPart)).toBeNil()

			frontPart:Destroy()
			behindPart:Destroy()
			farPart:Destroy()
		end)
	end)

	describe("IterateObjectsToUpdate", function()
		it("should iterate through visible objects", function()
			local part1 = createMockPart(Vector3.new(0, 0, 0))
			local part2 = createMockPart(Vector3.new(10, 10, 10))

			cullThrottle:AddObject(part1)
			cullThrottle:AddObject(part2)

			cullThrottle:_processObjectVisibility(os.clock())
			cullThrottle:_fillVisibleObjectsQueue()

			local iterator = cullThrottle:IterateObjectsToUpdate()
			local count = 0

			for object, deltaTime, distance, cframe in iterator do
				if object then
					count = count + 1
					expect(deltaTime).toBeDefined()
					expect(distance).toBeDefined()
					expect(cframe).toBeDefined()
				end
			end

			expect(count).toBeGreaterThanOrEqual(0)

			part1:Destroy()
			part2:Destroy()
		end)

		it("should return object data in iterator", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)

			cullThrottle:_processObjectVisibility(os.clock())
			cullThrottle:_fillVisibleObjectsQueue()

			local iterator = cullThrottle:IterateObjectsToUpdate()
			local object, deltaTime, distance, cframe = iterator()

			if object then
				expect(object).toBe(part)
				expect(type(deltaTime)).toBe("number")
				expect(type(distance)).toBe("number")
				expect(typeof(cframe)).toBe("CFrame")
			end

			part:Destroy()
		end)

		it("yields a visible object with its real distance and cframe", function()
			local camera = workspace.CurrentCamera
			local frontPart = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(frontPart)

			-- Generous budgets so the search runs to completion and the update loop
			-- doesn't bail before reaching the object.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._config.updateTimeBudget = 1
			cullThrottle:_processObjectVisibility(os.clock())

			local seen
			for object, deltaTime, distance, cframe in cullThrottle:IterateObjectsToUpdate() do
				if object == frontPart then
					seen = { deltaTime = deltaTime, distance = distance, cframe = cframe }
				end
			end

			expect(seen).toBeDefined()
			expect(type(seen.deltaTime)).toBe("number")
			-- The object sits 80 studs down the camera's look vector.
			expect(seen.distance).toBeCloseTo(80)
			expect(typeof(seen.cframe)).toBe("CFrame")

			frontPart:Destroy()
		end)

		it("stops iterating and clears the queue when the update budget is exhausted", function()
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 5 do
				local part = createMockPart((camera.CFrame * CFrame.new(i * 6, 0, -80)).Position)
				cullThrottle:AddObject(part)
				parts[i] = part
			end

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			-- A zero update budget (and no strict enforcement) means even the first
			-- dequeue is already over budget, so nothing should be iterated.
			cullThrottle._config.updateTimeBudget = 0
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)
			cullThrottle:_processObjectVisibility(os.clock())

			local count = 0
			for object in cullThrottle:IterateObjectsToUpdate() do
				if object then
					count += 1
				end
			end

			expect(count).toBe(0)
			-- Leftovers are cleared so they can't spill into a second iteration.
			expect(cullThrottle._visibleObjectsQueue:isEmpty()).toBe(true)

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("keeps updating overdue p0 objects past the normal budget under strict enforcement", function()
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			-- Make the object overdue before ingest so it is enqueued in the p0
			-- priority band (the band is decided at ingest time, not at iteration).
			cullThrottle._objects[part].lastUpdateClock = os.clock() - 100

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			-- The normal budget is exhausted immediately, but strict enforcement
			-- raises the p0 budget so worst-rate objects still update.
			cullThrottle._config.updateTimeBudget = 0
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:_processObjectVisibility(os.clock())

			local seen = false
			for object in cullThrottle:IterateObjectsToUpdate() do
				if object == part then
					seen = true
				end
			end

			expect(seen).toBe(true)

			part:Destroy()
		end)
	end)

	describe("Voxel operations", function()
		it("should insert object to voxel correctly", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()

			cullThrottle:_insertToVoxel(voxelKey, part)

			expect(cullThrottle._voxels[voxelKey]).toBeDefined()
			expect(table.find(cullThrottle._voxels[voxelKey], part)).toBeDefined()

			part:Destroy()
		end)

		it("should remove object from voxel correctly", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()

			cullThrottle:_insertToVoxel(voxelKey, part)
			cullThrottle:_removeFromVoxel(voxelKey, part)

			if cullThrottle._voxels[voxelKey] then
				expect(table.find(cullThrottle._voxels[voxelKey], part)).toBeNil()
			else
				expect(cullThrottle._voxels[voxelKey]).toBeNil()
			end

			part:Destroy()
		end)

		it("should clean up empty voxels", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()

			cullThrottle:_insertToVoxel(voxelKey, part)
			cullThrottle:_removeFromVoxel(voxelKey, part)

			expect(cullThrottle._voxels[voxelKey]).toBeNil()

			part:Destroy()
		end)

		it("should clear cached voxel visibility when a voxel empties", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()

			cullThrottle:_insertToVoxel(voxelKey, part)
			-- Simulate the search loop having marked this voxel visible this frame.
			cullThrottle._lastVoxelVisibility[voxelKey] = os.clock()

			cullThrottle:_removeFromVoxel(voxelKey, part)

			-- The voxel is gone, so its cached timestamp must not linger. The search
			-- loops only clear timestamps for voxels they find out of frustum, so an
			-- emptied voxel's entry would otherwise leak forever.
			expect(cullThrottle._lastVoxelVisibility[voxelKey]).toBeNil()

			part:Destroy()
		end)

		it("should keep cached voxel visibility while the voxel still holds objects", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part1 = createMockPart()
			local part2 = createMockPart()

			cullThrottle:_insertToVoxel(voxelKey, part1)
			cullThrottle:_insertToVoxel(voxelKey, part2)
			local now = os.clock()
			cullThrottle._lastVoxelVisibility[voxelKey] = now

			-- Removing one of two objects leaves the voxel occupied, so its cached
			-- visibility is still valid and must be preserved.
			cullThrottle:_removeFromVoxel(voxelKey, part1)

			expect(cullThrottle._voxels[voxelKey]).toBeDefined()
			expect(cullThrottle._lastVoxelVisibility[voxelKey]).toBe(now)

			part1:Destroy()
			part2:Destroy()
		end)

		it("should reuse the desiredVoxelKeys table in place across updates", function()
			cullThrottle:SetVoxelSize(100)

			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]
			local voxelSize = cullThrottle._config.voxelSize

			-- Capture the table that already backs the object, then recompute for a
			-- moved object. The table must be reused (same identity), not realloc'd.
			local sharedTable = objectData.desiredVoxelKeys
			objectData.cframe = CFrame.new(5000, 0, 0)
			cullThrottle:_updateDesiredVoxelKeys(part, objectData)

			expect(objectData.desiredVoxelKeys).toBe(sharedTable)

			-- The diff was rebuilt from scratch: add the new voxel, drop the old one,
			-- with no stale entries from before the clear.
			local newKey = objectData.cframe.Position // voxelSize
			expect(objectData.desiredVoxelKeys[newKey]).toBe(true)
			expect(objectData.desiredVoxelKeys[Vector3.new(0, 0, 0)]).toBe(false)

			part:Destroy()
		end)
	end)

	describe("Ingest priority", function()
		-- Reads back the priority _ingestVoxel staged for an object, matching it to
		-- its entry in the incoming batch (items[i] pairs with priorities[i]).
		local function incomingPriority(object: Instance): number?
			local batch = cullThrottle._visibleObjectsQueue._incomingBatch
			for i = 1, batch.size do
				if batch.items[i] == object then
					return batch.priorities[i]
				end
			end
			return nil
		end

		-- Positions an object a fixed distance straight out from the camera and
		-- prepares the object data fields the priority branches read.
		local function stageObject(distance: number, radius: number, elapsed: number): Instance
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]
			objectData.jitterOffset = 0
			objectData.radius = radius
			objectData.lastCheckClock = 0
			objectData.cframe = CFrame.new(CameraCache.Position + Vector3.new(0, 0, distance))
			-- elapsed is measured from "now" (os.clock) at ingest time.
			objectData.lastUpdateClock = os.clock() - elapsed
			return part
		end

		it("excludes objects beyond the render distance", function()
			local part = stageObject(500, 2, 0.04)
			cullThrottle._config._renderDistance = 100

			cullThrottle._visibleObjectsQueue:clearIncomingBatch()
			cullThrottle:_ingestVoxel(os.clock(), { part })

			-- Past render distance: never staged, and never marked visible.
			expect(incomingPriority(part)).toBeNil()
			expect(cullThrottle._objectVisibilityTimestamps[part]).toBeNil()

			part:Destroy()
		end)

		it("pushes over-refreshed objects far down the queue", function()
			-- elapsed 0 is well under bestRefreshRate, so this is the over-refresh
			-- branch, scaled by OVER_REFRESH_PRIORITY_SCALE (1e6). A small, distant
			-- object keeps screen size < 1 so the scaled value stays large.
			local part = stageObject(300, 0.5, 0)

			cullThrottle._visibleObjectsQueue:clearIncomingBatch()
			cullThrottle:_ingestVoxel(os.clock(), { part })

			local priority = incomingPriority(part)
			expect(priority).toBeDefined()
			expect((priority :: number) > 1e5).toBe(true)

			part:Destroy()
		end)

		it("gives overdue objects p0 priority sorted by screen size", function()
			-- elapsed far past worstRefreshRate puts both in the p0 band.
			local smallPart = stageObject(100, 0.5, 100)
			local bigPart = stageObject(100, 5, 100)

			cullThrottle._visibleObjectsQueue:clearIncomingBatch()
			cullThrottle:_ingestVoxel(os.clock(), { smallPart, bigPart })

			local pSmall = incomingPriority(smallPart) :: number
			local pBig = incomingPriority(bigPart) :: number

			-- Both sit below the p0 threshold (0.90)...
			expect(pSmall < 0.9).toBe(true)
			expect(pBig < 0.9).toBe(true)
			-- ...and the larger (more on-screen) object sorts ahead with a lower value.
			expect(pBig < pSmall).toBe(true)

			smallPart:Destroy()
			bigPart:Destroy()
		end)

		it("gives nearby objects a distance-proportional priority", function()
			-- Within NEARBY_DISTANCE_THRESHOLD (30) and refreshing at a fair rate.
			local part = stageObject(15, 2, 0.04)

			cullThrottle._visibleObjectsQueue:clearIncomingBatch()
			cullThrottle:_ingestVoxel(os.clock(), { part })

			-- priority = distance / NEARBY_DISTANCE_THRESHOLD = 15 / 30.
			expect(incomingPriority(part)).toBeCloseTo(15 / 30)

			part:Destroy()
		end)

		it("ranks a farther object below a nearer one in the fair band", function()
			-- Both past the nearby threshold and refreshing at a fair rate, so they
			-- take the weighted-blend branch where distance and screen size matter.
			local nearPart = stageObject(100, 2, 0.04)
			local farPart = stageObject(200, 2, 0.04)

			cullThrottle._visibleObjectsQueue:clearIncomingBatch()
			cullThrottle:_ingestVoxel(os.clock(), { nearPart, farPart })

			local pNear = incomingPriority(nearPart) :: number
			local pFar = incomingPriority(farPart) :: number

			-- A higher priority value means later in the queue, so the farther,
			-- smaller-on-screen object should sort after the nearer one.
			expect(pFar > pNear).toBe(true)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("ranks a larger object ahead of a smaller one in the fair band", function()
			local bigPart = stageObject(100, 5, 0.04)
			local smallPart = stageObject(100, 1, 0.04)

			cullThrottle._visibleObjectsQueue:clearIncomingBatch()
			cullThrottle:_ingestVoxel(os.clock(), { bigPart, smallPart })

			local pBig = incomingPriority(bigPart) :: number
			local pSmall = incomingPriority(smallPart) :: number

			-- The bigger object fills more of the screen, so it sorts first (lower value).
			expect(pBig < pSmall).toBe(true)

			bigPart:Destroy()
			smallPart:Destroy()
		end)
	end)

	describe("Visibility events", function()
		it("should fire ObjectEnteredView when object becomes visible", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			local fired = false
			local firedObject = nil

			local connection = cullThrottle.ObjectEnteredView:Connect(function(obj)
				fired = true
				firedObject = obj
			end)

			cullThrottle:AddObject(part)
			cullThrottle._objectVisibilityTimestamps[part] = nil
			cullThrottle:_ingestVoxel(os.clock(), { part })

			-- The signal is buffered during ingest and fired only on flush, so a
			-- handler can't mutate the tracked set mid-iteration.
			expect(fired).toBe(false)

			cullThrottle:_flushVisibilitySignals()

			expect(fired).toBe(true)
			expect(firedObject).toBe(part)

			connection:Disconnect()
			part:Destroy()
		end)

		it("should fire ObjectExitedView when object becomes invisible", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)

			local now = os.clock()
			cullThrottle._objectVisibilityTimestamps[part] = now - 1

			local fired = false
			local firedObject = nil

			local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
				fired = true
				firedObject = obj
			end)

			cullThrottle:_signalVisibilityChanges(now)

			-- Buffered during the visibility pass, fired only on flush.
			expect(fired).toBe(false)

			cullThrottle:_flushVisibilitySignals()

			expect(fired).toBe(true)
			expect(firedObject).toBe(part)

			connection:Disconnect()
			part:Destroy()
		end)

		it("should let an entered-view handler remove another object without skipping it", function()
			-- Two objects sharing a voxel. The handler removes the other object
			-- the moment one enters view. Because the entered-view signals are
			-- buffered and fired only after _ingestVoxel finishes iterating the
			-- voxel, both still get their event; firing synchronously mid-ingest
			-- would have mutated the voxel array and skipped the second object.
			local part1 = createMockPart(Vector3.new(0, 0, 0))
			local part2 = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part1)
			cullThrottle:AddObject(part2)

			local voxelKey = next(cullThrottle._objects[part1].voxelKeys)
			local voxel = cullThrottle._voxels[voxelKey]
			expect(#voxel).toBe(2)

			local entered = {}
			local connection = cullThrottle.ObjectEnteredView:Connect(function(obj)
				entered[obj] = true
				if obj == part1 then
					cullThrottle:RemoveObject(part2)
				elseif obj == part2 then
					cullThrottle:RemoveObject(part1)
				end
			end)

			cullThrottle._objectVisibilityTimestamps[part1] = nil
			cullThrottle._objectVisibilityTimestamps[part2] = nil

			expect(function()
				cullThrottle:_ingestVoxel(os.clock(), voxel)
				cullThrottle:_flushVisibilitySignals()
			end).never.toThrow()

			expect(entered[part1]).toBe(true)
			expect(entered[part2]).toBe(true)

			connection:Disconnect()
			part1:Destroy()
			part2:Destroy()
		end)

		it("should let an exited-view handler remove another object without corrupting iteration", function()
			-- Both objects were visible last frame and neither is this frame, so
			-- both exit. The handler removes the other object mid-dispatch, which
			-- mutates _objectVisibilityTimestamps. Deferring the fire to after
			-- _signalVisibilityChanges finishes iterating that table makes it safe.
			local part1 = createMockPart(Vector3.new(0, 0, 0))
			local part2 = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part1)
			cullThrottle:AddObject(part2)

			local now = os.clock()
			cullThrottle._objectVisibilityTimestamps[part1] = now - 1
			cullThrottle._objectVisibilityTimestamps[part2] = now - 1

			local exited = {}
			local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
				exited[obj] = true
				if obj == part1 then
					cullThrottle:RemoveObject(part2)
				elseif obj == part2 then
					cullThrottle:RemoveObject(part1)
				end
			end)

			expect(function()
				cullThrottle:_signalVisibilityChanges(now)
				cullThrottle:_flushVisibilitySignals()
			end).never.toThrow()

			expect(exited[part1]).toBe(true)
			expect(exited[part2]).toBe(true)

			connection:Disconnect()
			part1:Destroy()
			part2:Destroy()
		end)
	end)

	describe("Performance metrics", function()
		it("should track average object delta time", function()
			expect(cullThrottle._perfMetrics._averageObjectDeltaTime).toBeDefined()
			expect(type(cullThrottle._perfMetrics._averageObjectDeltaTime)).toBe("number")
		end)

		it("should calculate average correctly", function()
			local values = { 1, 2, 3, 4 }
			local average = cullThrottle._perfMetrics._getAverage(values)
			expect(average).toBe(2.5)
		end)

		it("should track search and ingest durations", function()
			cullThrottle:_findVisibleObjects(os.clock())

			expect(cullThrottle._perfMetrics._searchDuration).toBeDefined()
			expect(type(cullThrottle._perfMetrics._searchDuration)).toBe("number")
			expect(cullThrottle._perfMetrics._ingestDuration).toBeDefined()
			expect(type(cullThrottle._perfMetrics._ingestDuration)).toBe("number")
		end)
	end)

	describe("Frustum culling", function()
		it("should detect box completely inside frustum", function()
			-- Camera 70 FoV, at 0,0,0 and facing 0, 100, 0 w/ renderDistance 100
			local frustumPlanes: { Vector3 } = {
				Vector3.new(0, 0, 0),
				Vector3.new(-0, -0.779599547, 0.626278222),
				Vector3.new(0, 0, 0),
				Vector3.new(0, -0.779599547, -0.626278222),
				Vector3.new(0, 0, 0),
				Vector3.new(0.819152057, -0.573576391, 0),
				Vector3.new(0, 0, 0),
				Vector3.new(-0.819152057, -0.573576391, -0),
				Vector3.new(0, 100, 0),
				Vector3.new(0, 1, 0),
			}

			local inside, completelyInside = cullThrottle:_isBoxInFrustum(true, frustumPlanes, 0, 0, 0, 1, 1, 1)

			expect(inside).toBe(true)
			expect(completelyInside).toBe(false)
		end)

		it("should detect box outside frustum", function()
			-- Camera 70 FoV, at 0,0,0 and facing 0, 100, 0 w/ renderDistance 100
			local frustumPlanes: { Vector3 } = {
				Vector3.new(0, 0, 0),
				Vector3.new(-0, -0.779599547, 0.626278222),
				Vector3.new(0, 0, 0),
				Vector3.new(0, -0.779599547, -0.626278222),
				Vector3.new(0, 0, 0),
				Vector3.new(0.819152057, -0.573576391, 0),
				Vector3.new(0, 0, 0),
				Vector3.new(-0.819152057, -0.573576391, -0),
				Vector3.new(0, 100, 0),
				Vector3.new(0, 1, 0),
			}

			local inside, completelyInside = cullThrottle:_isBoxInFrustum(true, frustumPlanes, 8, 8, 8, 10, 10, 10)

			expect(inside).toBe(false)
			expect(completelyInside).toBe(false)
		end)
	end)

	describe("Volume search", function()
		it("should fully drain the volume search stack after a search", function()
			-- Spread objects across several voxels so the search subdivides and
			-- pushes/pops volumes on the flat stack.
			local parts = {}
			for i = -2, 2 do
				local part = createMockPart(Vector3.new(i * 50, 0, 0))
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- Generous budget so the search runs to completion rather than bailing
			-- into the cached-visibility fallback (which leaves volumes on the stack).
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle:_findVisibleObjects(os.clock())

			-- A correct pop loop empties the stack down to exactly zero.
			expect(cullThrottle._volumesToCheckSize).toBe(0)

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("should reuse cached visibility for volumes left when the search budget is exhausted", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._objects[part]
			local voxelKey = next(objectData.voxelKeys)

			-- The voxel was visible a moment ago, so the fallback should re-mark it.
			cullThrottle._lastVoxelVisibility[voxelKey] = os.clock()
			cullThrottle._visibleVoxelCount = 0

			-- Leave a single-voxel volume on the stack, as if the search ran out of
			-- time before reaching it, then run the cached-visibility fallback. The
			-- fallback accumulates into the unsorted pending buffer (the search sorts
			-- it afterward), so check there.
			cullThrottle._volumesToCheckSize = 0
			cullThrottle:_pushVolume(voxelKey.X, voxelKey.Y, voxelKey.Z, voxelKey.X + 1, voxelKey.Y + 1, voxelKey.Z + 1)
			cullThrottle:_reuseCachedVisibilityForRemainingVolumes()

			local found = false
			for i = 1, cullThrottle._visibleVoxelCount do
				if cullThrottle._pendingVoxelKeys[i] == voxelKey then
					found = true
					break
				end
			end
			expect(found).toBe(true)
			expect(cullThrottle._perfMetrics._skippedSearch[1]).toBe(1)

			part:Destroy()
		end)

		it("rotates the first-searched octant so each of the eight gets a turn", function()
			-- The frustum bounding box is split into eight octants every frame, and
			-- _volumeRotationCounter chooses which one is moved to the top of the
			-- LIFO stack so it is searched first. A small voxel size keeps the eight
			-- octants distinct, and a zero search budget bails right after the first
			-- octant is searched, so the first _searchVolume call each frame is the
			-- chosen octant.
			cullThrottle._config.voxelSize = 50
			cullThrottle._config.searchTimeBudget = 0

			local realSearchVolume = cullThrottle._searchVolume
			local firstOrigin = nil
			cullThrottle._searchVolume = function(self, now, frustumPlanes, x0, y0, z0, x1, y1, z1)
				if firstOrigin == nil then
					firstOrigin = Vector3.new(x0, y0, z0)
				end
				return realSearchVolume(self, now, frustumPlanes, x0, y0, z0, x1, y1, z1)
			end

			-- Eight frames is one full rotation through the eight octants.
			local distinctOrigins = {}
			local distinctCount = 0
			for _ = 1, 8 do
				firstOrigin = nil
				cullThrottle:_findVisibleObjects(os.clock())
				expect(firstOrigin).never.toBeNil()
				if not distinctOrigins[firstOrigin] then
					distinctOrigins[firstOrigin] = true
					distinctCount += 1
				end
			end

			-- Every octant, including octant 1, was searched first exactly once.
			expect(distinctCount).toBe(8)
		end)
	end)

	describe("Visible voxel ordering", function()
		it("accumulates added voxels into the pending buffer in call order", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			cullThrottle:_addVoxelKeyToVisible(cameraVoxel + Vector3.new(3, 0, 0))
			cullThrottle:_addVoxelKeyToVisible(cameraVoxel + Vector3.new(1, 0, 0))

			-- Appends are O(1) and unsorted; the count tracks the live length.
			expect(cullThrottle._visibleVoxelCount).toBe(2)
			expect(cullThrottle._pendingVoxelKeys[1]).toBe(cameraVoxel + Vector3.new(3, 0, 0))
			expect(cullThrottle._pendingVoxelKeys[2]).toBe(cameraVoxel + Vector3.new(1, 0, 0))
		end)

		it("sorts visible voxels closest-first by manhattan distance to the camera", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- Offsets deliberately added out of distance order.
			local offsets = {
				Vector3.new(5, 0, 0), -- distance 5
				Vector3.new(0, 0, 0), -- distance 0 (the camera's own voxel)
				Vector3.new(-2, 1, 0), -- distance 3
				Vector3.new(1, 0, 0), -- distance 1
				Vector3.new(2, 2, 2), -- distance 6
				Vector3.new(0, -3, 1), -- distance 4
			}
			for _, offset in offsets do
				cullThrottle:_addVoxelKeyToVisible(cameraVoxel + offset)
			end

			cullThrottle:_sortVisibleVoxelKeys()

			expect(cullThrottle._visibleVoxelCount).toBe(#offsets)

			-- Output distances are non-decreasing, and the nearest voxel is first.
			local previousDistance = -1
			for i = 1, cullThrottle._visibleVoxelCount do
				local difference = cullThrottle._visibleVoxelKeys[i] - cameraVoxel
				local distance = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)
				expect(distance).toBeGreaterThanOrEqual(previousDistance)
				previousDistance = distance
			end
			expect(cullThrottle._visibleVoxelKeys[1]).toBe(cameraVoxel)
		end)

		it("preserves every voxel exactly once through the sort, including ties", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- A spread of distinct voxels, several of which tie on distance.
			local added = {}
			for x = -3, 3 do
				for y = -1, 1 do
					local key = cameraVoxel + Vector3.new(x, y, 0)
					cullThrottle:_addVoxelKeyToVisible(key)
					added[key] = true
				end
			end

			cullThrottle:_sortVisibleVoxelKeys()

			local seen = {}
			for i = 1, cullThrottle._visibleVoxelCount do
				local key = cullThrottle._visibleVoxelKeys[i]
				seen[key] = (seen[key] or 0) + 1
			end

			-- Same set out as went in: each added key present exactly once, nothing extra.
			local addedCount = 0
			for key in added do
				expect(seen[key]).toBe(1)
				addedCount += 1
			end
			expect(cullThrottle._visibleVoxelCount).toBe(addedCount)
		end)

		it("handles the empty and single-voxel cases", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			-- Empty: nothing to sort, no error.
			expect(function()
				cullThrottle:_sortVisibleVoxelKeys()
			end).never.toThrow()
			expect(cullThrottle._visibleVoxelCount).toBe(0)

			-- Single voxel: carried straight across to the output.
			local onlyKey = cameraVoxel + Vector3.new(7, -2, 4)
			cullThrottle:_addVoxelKeyToVisible(onlyKey)
			cullThrottle:_sortVisibleVoxelKeys()
			expect(cullThrottle._visibleVoxelCount).toBe(1)
			expect(cullThrottle._visibleVoxelKeys[1]).toBe(onlyKey)
		end)

		it("keeps visible voxels ordered closest-first end to end", function()
			-- Spread objects across several voxels so the search produces a batch to order.
			local parts = {}
			for i = -3, 3 do
				local part = createMockPart(Vector3.new(i * 120, 0, 0))
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- Generous budgets so the search and ingest both run to completion.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle:_findVisibleObjects(os.clock())

			-- However many voxels ended up visible, they must come out non-decreasing
			-- in manhattan distance to the camera (the ingest passes depend on it).
			local cameraVoxel = CameraCache.Position // cullThrottle._config.voxelSize
			local previousDistance = -1
			for i = 1, cullThrottle._visibleVoxelCount do
				local difference = cullThrottle._visibleVoxelKeys[i] - cameraVoxel
				local distance = math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z)
				expect(distance).toBeGreaterThanOrEqual(previousDistance)
				previousDistance = distance
			end

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("preserves the visible voxel keys when the backing tables are resized", function()
			cullThrottle:SetVoxelSize(100)
			local cameraVoxel = CameraCache.Position // 100

			cullThrottle:_addVoxelKeyToVisible(cameraVoxel + Vector3.new(1, 0, 0))
			cullThrottle:_addVoxelKeyToVisible(cameraVoxel + Vector3.new(2, 0, 0))
			cullThrottle:_addVoxelKeyToVisible(cameraVoxel + Vector3.new(3, 0, 0))
			cullThrottle:_sortVisibleVoxelKeys()

			local expectedCount = cullThrottle._visibleVoxelCount
			local before = {}
			for i = 1, expectedCount do
				before[i] = cullThrottle._visibleVoxelKeys[i]
			end

			cullThrottle:_resizeTables()

			-- The resize trims the unused tail without dropping any live key.
			expect(cullThrottle._visibleVoxelCount).toBe(expectedCount)
			for i = 1, expectedCount do
				expect(cullThrottle._visibleVoxelKeys[i]).toBe(before[i])
			end
		end)
	end)

	describe("Dynamic render distance", function()
		it("should adjust render distance when performance is poor", function()
			cullThrottle:SetDynamicRenderDistance(true)
			cullThrottle:SetRenderDistanceTarget(500)

			cullThrottle._perfMetrics._averageObjectDeltaTime = 1
			cullThrottle._perfMetrics._searchDuration = 0.01
			cullThrottle._perfMetrics._ingestDuration = 0.01

			local originalDistance = cullThrottle._config._renderDistance
			cullThrottle:_adjustDynamicRenderDistance()

			expect(cullThrottle._config._renderDistance).toBeLessThan(originalDistance)
		end)

		it("should increase render distance when performance is good", function()
			cullThrottle:SetDynamicRenderDistance(true)
			cullThrottle:SetRenderDistanceTarget(500)

			cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
			cullThrottle._perfMetrics._searchDuration = 0.0001
			cullThrottle._perfMetrics._ingestDuration = 0.0001
			cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }
			cullThrottle._perfMetrics._skippedIngest = { 0, 0, 0, 0 }

			local originalDistance = cullThrottle._config._renderDistance
			cullThrottle:_adjustDynamicRenderDistance()

			expect(cullThrottle._config._renderDistance).toBeGreaterThan(originalDistance)
		end)

		it("should respect min and max render distance limits", function()
			cullThrottle:SetDynamicRenderDistance(true)
			cullThrottle:SetRenderDistanceTarget(500)

			cullThrottle._config._renderDistance = cullThrottle._config._minRenderDistance
			cullThrottle._perfMetrics._averageObjectDeltaTime = 1
			cullThrottle:_adjustDynamicRenderDistance()

			expect(cullThrottle._config._renderDistance).toBeGreaterThanOrEqual(cullThrottle._config._minRenderDistance)

			cullThrottle._config._renderDistance = cullThrottle._config._maxRenderDistance
			cullThrottle._perfMetrics._averageObjectDeltaTime = 0.001
			cullThrottle:_adjustDynamicRenderDistance()

			expect(cullThrottle._config._renderDistance).toBeLessThanOrEqual(cullThrottle._config._maxRenderDistance)
		end)
	end)

	describe("Edge cases", function()
		it("should handle objects with tiny size", function()
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(0, 0, 0))

			expect(function()
				cullThrottle:AddObject(part)
			end).never.toThrow()

			local objectData = cullThrottle._objects[part]
			expect(objectData).toBeDefined()
			expect(objectData.radius).toBeLessThanOrEqual(0.001)

			part:Destroy()
		end)

		it("should handle objects at extreme distances", function()
			local farPart = createMockPart(Vector3.new(1000000, 1000000, 1000000))
			local nearPart = createMockPart(Vector3.new(0.1, 0.1, 0.1))

			expect(function()
				cullThrottle:AddObject(farPart)
				cullThrottle:AddObject(nearPart)
			end).never.toThrow()

			farPart:Destroy()
			nearPart:Destroy()
		end)

		it("should handle rapid add/remove cycles", function()
			local part = createMockPart()

			expect(function()
				for _ = 1, 10 do
					cullThrottle:AddObject(part)
					cullThrottle:RemoveObject(part)
				end
			end).never.toThrow()

			expect(cullThrottle._objects[part]).toBeNil()

			part:Destroy()
		end)

		it("should handle empty voxel operations", function()
			expect(function()
				cullThrottle:_removeFromVoxel(Vector3.new(999, 999, 999), Instance.new("Part"))
			end).never.toThrow()
		end)

		it("should handle processing with no objects", function()
			expect(function()
				cullThrottle:_processObjectVisibility(os.clock())
				cullThrottle:GetVisibleObjects()
				for _ in cullThrottle:IterateObjectsToUpdate() do
					local _
				end
			end).never.toThrow()
		end)
	end)
end)
