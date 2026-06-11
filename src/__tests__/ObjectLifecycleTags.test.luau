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

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart

describe("ObjectLifecycle tags", function()
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

	describe("CaptureTag", function()
		it("should capture all objects with a tag", function()
			local tag = "TestTag"
			local part1 = createMockPart()
			local part2 = createMockPart()

			CollectionService:AddTag(part1, tag)
			CollectionService:AddTag(part2, tag)

			cullThrottle:CaptureTag(tag)

			expect(cullThrottle._lifecycle._objects[part1]).toBeDefined()
			expect(cullThrottle._lifecycle._objects[part2]).toBeDefined()

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
			expect(cullThrottle._lifecycle._objects[part]).toBeDefined()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(part, tag)
			part:Destroy()
		end)

		it("should stop tracking objects when tag is removed", function()
			local tag = "TestTag"
			local part = createMockPart()
			CollectionService:AddTag(part, tag)

			cullThrottle:CaptureTag(tag)
			expect(cullThrottle._lifecycle._objects[part]).toBeDefined()

			CollectionService:RemoveTag(part, tag)
			task.wait()
			expect(cullThrottle._lifecycle._objects[part]).toBeNil()

			cullThrottle:ReleaseTag(tag)
			part:Destroy()
		end)

		it("keeps an object tracked while another captured tag still applies", function()
			local tagA = "MultiTagA"
			local tagB = "MultiTagB"
			local part = createMockPart()
			CollectionService:AddTag(part, tagA)
			CollectionService:AddTag(part, tagB)

			cullThrottle:CaptureTag(tagA)
			cullThrottle:CaptureTag(tagB)
			expect(cullThrottle._lifecycle._objects[part]).toBeDefined()

			-- Losing one captured tag must not untrack the object while another
			-- captured tag still applies to it.
			CollectionService:RemoveTag(part, tagA)
			task.wait()
			expect(cullThrottle._lifecycle._objects[part]).toBeDefined()

			-- Losing the last captured tag untracks it for real.
			CollectionService:RemoveTag(part, tagB)
			task.wait()
			expect(cullThrottle._lifecycle._objects[part]).toBeNil()

			cullThrottle:ReleaseTag(tagA)
			cullThrottle:ReleaseTag(tagB)
			part:Destroy()
		end)

		it("should skip an un-addable tagged instance without aborting the rest of the capture", function()
			local tag = "MixedCaptureTag"
			local part1 = createMockPart()
			-- A Folder has no resolvable CFrame or bounding box, so addObject errors on it.
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

			expect(cullThrottle._lifecycle._objects[part1]).toBeDefined()
			expect(cullThrottle._lifecycle._objects[part2]).toBeDefined()
			expect(cullThrottle._lifecycle._objects[folder]).toBeNil()

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
			expect(cullThrottle._lifecycle._objects[folder]).toBeNil()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(folder, tag)
			folder:Destroy()
		end)

		it("should disconnect the previous connections when a tag is re-captured", function()
			local tag = "RecaptureTag"
			cullThrottle:CaptureTag(tag)

			local firstConnections = cullThrottle._lifecycle._tagConnections[tag]
			expect(firstConnections).toBeDefined()

			cullThrottle:CaptureTag(tag)

			-- The first capture's connections must be disconnected, not left dangling.
			-- Leaked connections stay live and double-handle every tagged add and remove.
			for _, connection in firstConnections do
				expect(connection.Connected).toBe(false)
			end

			expect(cullThrottle._lifecycle._tagConnections[tag]).never.toBe(firstConnections)
			for _, connection in cullThrottle._lifecycle._tagConnections[tag] do
				expect(connection.Connected).toBe(true)
			end

			cullThrottle:ReleaseTag(tag)
		end)
	end)

	describe("ReleaseTag", function()
		it("should disconnect tag connections", function()
			local tag = "TestTag"
			cullThrottle:CaptureTag(tag)

			expect(cullThrottle._lifecycle._tagConnections[tag]).toBeDefined()

			cullThrottle:ReleaseTag(tag)

			local part = createMockPart()
			CollectionService:AddTag(part, tag)
			task.wait()

			expect(cullThrottle._lifecycle._objects[part]).toBeNil()

			CollectionService:RemoveTag(part, tag)
			part:Destroy()
		end)

		it("should clear the tag connection entry", function()
			local tag = "ClearedTag"
			cullThrottle:CaptureTag(tag)
			expect(cullThrottle._lifecycle._tagConnections[tag]).toBeDefined()

			cullThrottle:ReleaseTag(tag)

			-- The entry (and its now-dead connection objects) must be dropped, not
			-- left as a stale truthy "captured" marker referencing disconnected
			-- connections.
			expect(cullThrottle._lifecycle._tagConnections[tag]).toBeNil()
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

			expect(cullThrottle._lifecycle._objects[part1]).toBeNil()
			expect(cullThrottle._lifecycle._objects[part2]).toBeNil()
			expect(cullThrottle._lifecycle._objects[part3]).toBeDefined()

			CollectionService:RemoveTag(part1, tag)
			CollectionService:RemoveTag(part2, tag)
			part1:Destroy()
			part2:Destroy()
			part3:Destroy()
		end)

		it("should snapshot before removing so an ObjectRemoved handler may mutate the tracked set", function()
			-- RemoveObjectsWithTag must not iterate the tracked set live while
			-- removing, because removeObject fires ObjectRemoved and a handler may
			-- add or remove tracked objects. Snapshotting the matches first makes
			-- that mid-removal mutation safe.
			local tag = "ReentrancyTag"
			local tagged = {}
			for i = 1, 5 do
				local part = createMockPart(Vector3.new(i * 10, 0, 0))
				CollectionService:AddTag(part, tag)
				cullThrottle:AddObject(part)
				tagged[i] = part
			end

			-- This is an untagged object the handler adds partway through the removal.
			local extra = createMockPart(Vector3.new(0, 500, 0))

			local connection = cullThrottle.ObjectRemoved:Connect(function()
				if not cullThrottle._lifecycle._objects[extra] then
					cullThrottle:AddObject(extra)
				end
			end)

			expect(function()
				cullThrottle:RemoveObjectsWithTag(tag)
			end).never.toThrow()

			-- Every tagged object was removed despite the mid-loop insertion.
			for _, part in tagged do
				expect(cullThrottle._lifecycle._objects[part]).toBeNil()
			end
			-- The object added by the handler survived (it isn't tagged, so the
			-- pre-removal snapshot never included it).
			expect(cullThrottle._lifecycle._objects[extra]).toBeDefined()

			connection:Disconnect()
			for _, part in tagged do
				CollectionService:RemoveTag(part, tag)
				part:Destroy()
			end
			extra:Destroy()
		end)
	end)
end)
