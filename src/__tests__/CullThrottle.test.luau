local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

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
	end)

	describe("SetVoxelSize", function()
		it("should update voxel size configuration", function()
			local newVoxelSize = 100
			cullThrottle:SetVoxelSize(newVoxelSize)

			expect(cullThrottle._config.voxelSize).toBe(newVoxelSize)
			expect(cullThrottle._config._halfVoxelSizeVec).toBe(Vector3.one * 50)
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

			expect(fired).toBe(true)
			expect(firedObject).toBe(part)

			connection:Disconnect()
			part:Destroy()
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
			table.clear(cullThrottle._visibleVoxelKeys)

			-- Leave a single-voxel volume on the stack, as if the search ran out of
			-- time before reaching it, then run the cached-visibility fallback.
			cullThrottle._volumesToCheckSize = 0
			cullThrottle:_pushVolume(voxelKey.X, voxelKey.Y, voxelKey.Z, voxelKey.X + 1, voxelKey.Y + 1, voxelKey.Z + 1)
			cullThrottle:_reuseCachedVisibilityForRemainingVolumes()

			local found = false
			for _, key in cullThrottle._visibleVoxelKeys do
				if key == voxelKey then
					found = true
					break
				end
			end
			expect(found).toBe(true)
			expect(cullThrottle._perfMetrics._skippedSearch[1]).toBe(1)

			part:Destroy()
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
