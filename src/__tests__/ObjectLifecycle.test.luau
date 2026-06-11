local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local CullThrottle = require(CullThrottlePackage)

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local createMockModel = TestHelpers.createMockModel
local markInView = TestHelpers.markInView

describe("ObjectLifecycle", function()
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
			expect(cullThrottle._grid._voxels).toEqual({})
			expect(cullThrottle._lifecycle._objects).toEqual({})
			expect(cullThrottle._lifecycle._physicsObjects).toEqual({})
		end)

		it("should initialize event signals", function()
			expect(cullThrottle.ObjectEnteredView).toBeDefined()
			expect(cullThrottle.ObjectExitedView).toBeDefined()
			expect(cullThrottle.ObjectAdded).toBeDefined()
			expect(cullThrottle.ObjectRemoved).toBeDefined()
		end)

		it("should create priority queues", function()
			expect(cullThrottle._grid._updateObjectVoxelsQueue).toBeDefined()
			expect(cullThrottle._ingest._visibleObjectsQueue).toBeDefined()
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

			local tagConnections = cullThrottle._lifecycle._tagConnections[tag]
			expect(tagConnections).toBeDefined()

			cullThrottle:Destroy()

			for _, connection in tagConnections do
				expect(connection.Connected).toBe(false)
			end
		end)

		it("should disconnect per-object change connections", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
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

			expect(cullThrottle._lifecycle._objects).toEqual({})
			expect(cullThrottle._grid._voxels).toEqual({})
			expect(cullThrottle._lifecycle._physicsObjects).toEqual({})
			expect(next(cullThrottle._signals._objectsInView)).toBeNil()
			expect(cullThrottle._signals._objectsInViewSize).toBe(0)

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
			local objectData = cullThrottle._lifecycle._objects[part]

			expect(objectData).toBeDefined()
			expect(objectData.cframe).toBeDefined()
			expect(objectData.halfBoundingBox).toBeDefined()
			expect(objectData.radius).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("should not return the internal objectData", function()
			local part = createMockPart()

			expect(cullThrottle:AddObject(part)).toBeNil()

			part:Destroy()
		end)

		it("should add a Model object with PrimaryPart", function()
			local model = createMockModel()
			cullThrottle:AddObject(model)

			expect(cullThrottle._lifecycle._objects[model]).toBeDefined()

			model:Destroy()
		end)

		it("should not add duplicate objects", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			local objectData1 = cullThrottle._lifecycle._objects[part]
			cullThrottle:AddObject(part)
			local objectData2 = cullThrottle._lifecycle._objects[part]

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
			local objectData = cullThrottle._lifecycle._objects[part]

			expect(objectData.halfBoundingBox).toBe(Vector3.new(5, 5, 5))
			expect(objectData.radius).toBeCloseTo(math.sqrt(5 ^ 2 + 5 ^ 2 + 5 ^ 2))

			part:Destroy()
		end)

		it("should assign object to correct voxel", function()
			local part = createMockPart(Vector3.new(100, 100, 100))
			cullThrottle:AddObject(part)

			local voxelSize = cullThrottle._config.voxelSize
			local expectedVoxelKey = Vector3.new(100, 100, 100) // voxelSize

			local found = false
			for voxelKey, voxel in cullThrottle._grid._voxels do
				if voxelKey == expectedVoxelKey then
					found = table.find(voxel, cullThrottle._lifecycle._objects[part]) ~= nil
					break
				end
			end

			expect(found).toBe(true)

			part:Destroy()
		end)

		it("should register a large object in all occupied voxels", function()
			cullThrottle:SetVoxelSize(100)

			-- A 500-long part centered at the origin spans voxels -3 through 2 on X.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(500, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- These are the interior voxels along the length.
			expect(objectData.voxelKeys[Vector3.new(-2, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(-1, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(1, 0, 0)]).toBe(true)

			-- And the object is actually inserted into one of those interior voxels.
			local interiorVoxel = cullThrottle._grid._voxels[Vector3.new(1, 0, 0)]
			expect(interiorVoxel).toBeDefined()
			expect(table.find(interiorVoxel, objectData)).toBeDefined()

			part:Destroy()
		end)

		it("should not register a rotated object in the empty corners of its bounding box", function()
			cullThrottle:SetVoxelSize(100)

			-- This is a long part laid diagonally across the XZ plane. Its world-space
			-- AABB is a big square, but the box only occupies the diagonal band,
			-- so the AABB corners that the box doesn't reach must stay empty.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(600, 20, 20))
			part.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- The voxels in the empty corners of the AABB aren't registered.
			expect(objectData.voxelKeys[Vector3.new(2, 0, 2)]).toBeNil()
			expect(objectData.voxelKeys[Vector3.new(-2, 0, -2)]).toBeNil()

			-- The occupied diagonal voxels still are.
			expect(objectData.voxelKeys[Vector3.new(2, 0, -2)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(-2, 0, 2)]).toBe(true)

			-- As a sanity check, we register fewer voxels than the full AABB volume
			-- (x runs -3 through 2, y runs -1 through 0, and z runs -3 through 2,
			-- which is 72 voxels), proving we don't just fill the box.
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

			-- The failed add must leave no trace, so the object isn't tracked and
			-- the count is unchanged.
			expect(cullThrottle._lifecycle._objects[folder]).toBeNil()
			expect(cullThrottle:IsTracking(folder)).toBe(false)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			folder:Destroy()
		end)
	end)

	describe("AddPhysicsObject", function()
		it("should add unanchored part to physics objects list", function()
			local part = createMockPart(nil, nil, false)
			cullThrottle:AddPhysicsObject(part)

			expect(cullThrottle._lifecycle._objects[part]).toBeDefined()
			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeDefined()

			part:Destroy()
		end)

		it("should poll physics objects for position changes", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)

			part.Position = Vector3.new(50, 50, 50)

			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())

			local objectData = cullThrottle._lifecycle._objects[part]
			expect(objectData.cframe.Position).toBe(Vector3.new(50, 50, 50))

			part:Destroy()
		end)

		it("polls every remaining object after removals leave the cursor past the end", function()
			local parts = {}
			for i = 1, 9 do
				parts[i] = createMockPart(Vector3.new(i * 10, 0, 0), nil, false)
				cullThrottle:AddPhysicsObject(parts[i])
			end

			-- A prior frame's poll can save the cursor anywhere in the list, so we
			-- park it on the last slot and then shrink the list out from under it.
			cullThrottle._lifecycle._physicsObjectIterIndex = 9
			for i = 6, 9 do
				cullThrottle:RemoveObject(parts[i])
			end

			-- Move the survivors the way physics would, with the change listeners
			-- disconnected so the poll is the only thing that can notice the move.
			for i = 1, 5 do
				for _, connection in cullThrottle._lifecycle._objects[parts[i]].changeConnections do
					connection:Disconnect()
				end
				parts[i].Position = Vector3.new(i * 10, 100, 0)
			end

			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())

			-- The budget is generous enough to cover the whole list in one poll, so
			-- every remaining object's cframe must come out fresh.
			for i = 1, 5 do
				expect(cullThrottle._lifecycle._objects[parts[i]].cframe.Position).toBe(Vector3.new(i * 10, 100, 0))
			end

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("does not refill voxel keys when a polled object has not moved", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)

			-- Count the expensive oriented-box fill by patching the grid instance
			-- (the patch dies with the test). It's installed after the add so the
			-- initial fill from AddObject isn't counted.
			local realUpdate = cullThrottle._grid.updateDesiredVoxelKeys
			local fillCalls = 0
			cullThrottle._grid.updateDesiredVoxelKeys = function(grid, polledObject, objectData)
				fillCalls += 1
				return realUpdate(grid, polledObject, objectData)
			end

			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())
			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())
			expect(fillCalls).toBe(0)

			part:Destroy()
		end)

		it("refills voxel keys when physics moves a polled object", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)

			-- Physics-driven motion changes a part's CFrame without firing the
			-- change signal, so disconnect this object's listeners to mimic that.
			-- The poll is then the only thing that can notice the move.
			for _, connection in cullThrottle._lifecycle._objects[part].changeConnections do
				connection:Disconnect()
			end

			local realUpdate = cullThrottle._grid.updateDesiredVoxelKeys
			local fillCalls = 0
			cullThrottle._grid.updateDesiredVoxelKeys = function(grid, polledObject, objectData)
				fillCalls += 1
				return realUpdate(grid, polledObject, objectData)
			end

			part.Position = Vector3.new(500, 0, 0)

			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())
			expect(fillCalls).toBe(1)
			expect(cullThrottle._lifecycle._objects[part].cframe.Position).toBe(Vector3.new(500, 0, 0))

			-- The cache now matches the part, so a further poll skips the refill.
			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())
			expect(fillCalls).toBe(1)

			part:Destroy()
		end)

		it("should not register duplicates when added twice", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)
			cullThrottle:AddPhysicsObject(part)

			local count = 0
			for _, candidate in cullThrottle._lifecycle._physicsObjects do
				if candidate == part then
					count += 1
				end
			end
			expect(count).toBe(1)

			part:Destroy()
		end)

		it("should upgrade an already-added static object to a physics object", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			-- The dedup guard keys off _physicsObjects rather than _objects, so an
			-- object added statically first can still be upgraded.
			cullThrottle:AddObject(part)
			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeNil()

			cullThrottle:AddPhysicsObject(part)
			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeDefined()

			part:Destroy()
		end)

		it("should leave no dangling entry after removing a doubly-added object", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)
			cullThrottle:AddPhysicsObject(part)

			cullThrottle:RemoveObject(part)

			-- A leftover duplicate would survive RemoveObject's single swap-remove,
			-- leaving a dangling entry that pins the removed instance in the list and
			-- gets pointlessly skipped on every poll. There must be no trace left.
			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeNil()
			expect(#cullThrottle._lifecycle._physicsObjects).toBe(0)

			-- Polling the now-empty list must not error.
			cullThrottle._lifecycle:pollPhysicsObjects(1, os.clock())

			part:Destroy()
		end)
	end)

	describe("RemoveObject", function()
		it("should remove object from tracking", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			cullThrottle:RemoveObject(part)

			expect(cullThrottle._lifecycle._objects[part]).toBeNil()

			part:Destroy()
		end)

		it("should remove object from voxels", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)
			cullThrottle:RemoveObject(part)

			for _, voxel in cullThrottle._grid._voxels do
				for _, objectData in voxel do
					expect(objectData.object).never.toBe(part)
				end
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

			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeNil()

			part:Destroy()
		end)

		it("keeps the other physics objects registered when one is removed from the middle", function()
			local parts = {}
			for i = 1, 3 do
				parts[i] = createMockPart(Vector3.new(i * 10, 0, 0), nil, false)
				cullThrottle:AddPhysicsObject(parts[i])
			end

			cullThrottle:RemoveObject(parts[1])

			local physicsObjects = cullThrottle._lifecycle._physicsObjects
			expect(#physicsObjects).toBe(2)
			expect(table.find(physicsObjects, parts[1])).toBeNil()
			expect(table.find(physicsObjects, parts[2])).toBeDefined()
			expect(table.find(physicsObjects, parts[3])).toBeDefined()

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("removes a physics object that an earlier removal swapped into a new slot", function()
			local parts = {}
			for i = 1, 3 do
				parts[i] = createMockPart(Vector3.new(i * 10, 0, 0), nil, false)
				cullThrottle:AddPhysicsObject(parts[i])
			end

			-- Removing the first object swap-moves the last one into its slot. The
			-- moved object must still be removable from its new slot, without
			-- evicting an innocent neighbor or leaving itself behind.
			cullThrottle:RemoveObject(parts[1])
			cullThrottle:RemoveObject(parts[3])

			local physicsObjects = cullThrottle._lifecycle._physicsObjects
			expect(#physicsObjects).toBe(1)
			expect(physicsObjects[1]).toBe(parts[2])

			for _, part in parts do
				part:Destroy()
			end
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
			expect(cullThrottle._lifecycle._objects[part]).toBeDefined()

			-- Idiomatic Roblox cleanup is object:Destroy(), without ever calling
			-- RemoveObject. CullThrottle should still let go of it.
			part:Destroy()
			task.wait()

			expect(cullThrottle._lifecycle._objects[part]).toBeNil()
		end)

		it("should remove the object from voxels when it is destroyed externally", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			part:Destroy()
			task.wait()

			for _, voxel in cullThrottle._grid._voxels do
				for _, objectData in voxel do
					expect(objectData.object).never.toBe(part)
				end
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
			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeDefined()

			part:Destroy()
			task.wait()

			expect(cullThrottle._lifecycle._objects[part]).toBeNil()
			expect(table.find(cullThrottle._lifecycle._physicsObjects, part)).toBeNil()
		end)

		it("should not fire ObjectExitedView for an object that was removed while visible", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)

			local now = os.clock()
			markInView(cullThrottle, part, now)

			cullThrottle:RemoveObject(part)

			-- The in-view entry must be removed so the next pass doesn't see a
			-- stale "was visible last frame, gone this frame" entry and fire a stray
			-- ObjectExitedView for an object we've already removed.
			expect(cullThrottle._signals._objectsInViewSize).toBe(0)

			local exited = false
			local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
				if obj == part then
					exited = true
				end
			end)

			cullThrottle._signals:signalVisibilityChanges(now + 1)
			cullThrottle._signals:flushVisibilitySignals()
			expect(exited).toBe(false)

			connection:Disconnect()
			part:Destroy()
		end)

		it("keeps the in-view set intact when in-view objects are removed out of order", function()
			local parts = {}
			local now = os.clock()
			for i = 1, 3 do
				parts[i] = createMockPart(Vector3.new(i * 10, 0, 0))
				cullThrottle:AddObject(parts[i])
				markInView(cullThrottle, parts[i], now)
			end

			-- Removing the first in-view object swap-moves the last entry into its
			-- slot, and then that moved entry is removed too. Only the middle object
			-- is left, so it must be the only entry the exit sweep can still see.
			cullThrottle:RemoveObject(parts[1])
			cullThrottle:RemoveObject(parts[3])

			local signals = cullThrottle._signals
			expect(signals._objectsInViewSize).toBe(1)
			expect(signals._objectsInView[1].object).toBe(parts[2])
			expect(signals._objectsInView[2]).toBeNil()
			expect(signals._objectsInView[3]).toBeNil()

			local exited = {}
			local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
				table.insert(exited, obj)
			end)

			cullThrottle._signals:signalVisibilityChanges(now + 1)
			cullThrottle._signals:flushVisibilitySignals()
			expect(exited).toEqual({ parts[2] })

			connection:Disconnect()
			for _, part in parts do
				part:Destroy()
			end
		end)

		it("should remove the object from the voxel update queue", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- Move the object so a voxel update is queued, mimicking the backlog
			-- that builds up when voxel updates exceed their per-frame time budget.
			objectData.cframe = CFrame.new(10000, 0, 0)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			cullThrottle._grid._updateObjectVoxelsQueue:enqueueIncomingBatch()
			expect(cullThrottle._grid._updateObjectVoxelsQueue:contains(part)).toBe(true)

			cullThrottle:RemoveObject(part)

			-- The queue entry must be cleared so the removed instance isn't pinned
			-- in the heap and contains() doesn't keep reporting it as still queued.
			expect(cullThrottle._grid._updateObjectVoxelsQueue:contains(part)).toBe(false)

			part:Destroy()
		end)
	end)

	describe("Ancestor source lifecycle", function()
		it("re-resolves an ancestor-sourced object's source when it is reparented", function()
			local partA = createMockPart(Vector3.new(0, 0, 0))
			local partB = createMockPart(Vector3.new(500, 0, 0))
			local sound = Instance.new("Sound")
			sound.RollOffMaxDistance = 20
			sound.Parent = partA

			cullThrottle:AddObject(sound)
			expect(cullThrottle._lifecycle._objects[sound].cframeSource).toBe(partA)

			-- A Sound reads its position from its parent part, so reparenting it
			-- must re-resolve the source and follow the new part's position rather
			-- than stay frozen at the old one.
			sound.Parent = partB
			task.wait()

			local objectData = cullThrottle._lifecycle._objects[sound]
			expect(objectData).toBeDefined()
			expect(objectData.cframeSource).toBe(partB)
			expect(objectData.cframe.Position.X).toBeCloseTo(500)

			partA:Destroy()
			partB:Destroy()
		end)

		it("keeps tracking after the original source is destroyed once reparented away", function()
			local partA = createMockPart(Vector3.new(0, 0, 0))
			local partB = createMockPart(Vector3.new(500, 0, 0))
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = partA

			cullThrottle:AddObject(light)

			-- Move the light onto partB so its source re-resolves, then destroy the
			-- now-unrelated partA. The light's source is partB now, so partA going
			-- away must not remove it.
			light.Parent = partB
			task.wait()
			partA:Destroy()
			task.wait()

			expect(cullThrottle._lifecycle._objects[light]).toBeDefined()
			expect(cullThrottle._lifecycle._objects[light].cframeSource).toBe(partB)

			partB:Destroy()
		end)

		it("auto-removes an ancestor-sourced object reparented out of a trackable hierarchy", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			local light = Instance.new("PointLight")
			light.Range = 16
			light.Parent = part

			cullThrottle:AddObject(light)
			expect(cullThrottle._lifecycle._objects[light]).toBeDefined()

			-- Once it's reparented under a Folder with no positional ancestor, the
			-- light can no longer be positioned, so it must be dropped rather than
			-- tracked at a stale spot.
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			light.Parent = folder
			task.wait()

			expect(cullThrottle._lifecycle._objects[light]).toBeNil()

			part:Destroy()
			folder:Destroy()
		end)
	end)
end)
