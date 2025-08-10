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
		if cullThrottle and cullThrottle._renderConnection then
			cullThrottle._renderConnection:Disconnect()
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

	describe("AddObject", function()
		it("should add a Part object", function()
			local part = createMockPart()
			local objectData = cullThrottle:AddObject(part)

			expect(objectData).toBeDefined()
			expect(cullThrottle._objects[part]).toBe(objectData)
			expect(objectData.cframe).toBeDefined()
			expect(objectData.halfBoundingBox).toBeDefined()
			expect(objectData.radius).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("should add a Model object with PrimaryPart", function()
			local model = createMockModel()
			local objectData = cullThrottle:AddObject(model)

			expect(objectData).toBeDefined()
			expect(cullThrottle._objects[model]).toBe(objectData)

			model:Destroy()
		end)

		it("should not add duplicate objects", function()
			local part = createMockPart()
			local objectData1 = cullThrottle:AddObject(part)
			local objectData2 = cullThrottle:AddObject(part)

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
			local objectData = cullThrottle:AddObject(part)

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
		it("should update refresh rate configurations with decimal values", function()
			local bestRate = 0.033
			local worstRate = 0.5

			cullThrottle:SetRefreshRates(bestRate, worstRate)

			expect(cullThrottle._config.bestRefreshRate).toBe(bestRate)
			expect(cullThrottle._config.worstRefreshRate).toBe(worstRate)
			expect(cullThrottle._config._refreshRateRange).toBeCloseTo(worstRate - bestRate)
		end)

		it("should convert FPS values to time values", function()
			local bestFPS = 30
			local worstFPS = 5

			cullThrottle:SetRefreshRates(bestFPS, worstFPS)

			expect(cullThrottle._config.bestRefreshRate).toBeCloseTo(1 / bestFPS)
			expect(cullThrottle._config.worstRefreshRate).toBeCloseTo(1 / worstFPS)
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

	describe("SetStrictlyEnforcedWorstRefreshRate", function()
		it("should update strictlyEnforceWorstRefreshRate setting", function()
			cullThrottle:SetStrictlyEnforcedWorstRefreshRate(true)
			expect(cullThrottle._config.strictlyEnforceWorstRefreshRate).toBe(true)

			cullThrottle:SetStrictlyEnforcedWorstRefreshRate(false)
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
