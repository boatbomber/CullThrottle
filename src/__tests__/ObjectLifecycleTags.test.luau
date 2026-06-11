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

			expect(cullThrottle:IsTracking(part1)).toBe(true)
			expect(cullThrottle:IsTracking(part2)).toBe(true)

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
			expect(cullThrottle:IsTracking(part)).toBe(true)

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(part, tag)
			part:Destroy()
		end)

		it("should stop tracking objects when tag is removed", function()
			local tag = "TestTag"
			local part = createMockPart()
			CollectionService:AddTag(part, tag)

			cullThrottle:CaptureTag(tag)
			expect(cullThrottle:IsTracking(part)).toBe(true)

			CollectionService:RemoveTag(part, tag)
			task.wait()
			expect(cullThrottle:IsTracking(part)).toBe(false)

			cullThrottle:ReleaseTag(tag)
			part:Destroy()
		end)

		it("routes an unanchored tagged part to physics tracking and an anchored one to static", function()
			local tag = "AnchorRoutingTag"
			local anchoredPart = createMockPart()
			local physicsPart = createMockPart(Vector3.new(50, 0, 0), nil, false)
			CollectionService:AddTag(anchoredPart, tag)
			CollectionService:AddTag(physicsPart, tag)

			cullThrottle:CaptureTag(tag)

			expect(cullThrottle:IsTracking(anchoredPart)).toBe(true)
			expect(cullThrottle:IsTracking(physicsPart)).toBe(true)

			-- Only the unanchored part needs polling. The anchored one moves via
			-- property writes that fire change signals.
			expect(table.find(cullThrottle._lifecycle._physicsObjects, anchoredPart)).toBeNil()
			expect(table.find(cullThrottle._lifecycle._physicsObjects, physicsPart)).toBeDefined()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(anchoredPart, tag)
			CollectionService:RemoveTag(physicsPart, tag)
			anchoredPart:Destroy()
			physicsPart:Destroy()
		end)

		it("keeps a captured part in its original tracking mode when Anchored later flips", function()
			local tag = "AnchorReadOnceTag"
			local staticPart = createMockPart()
			local physicsPart = createMockPart(Vector3.new(50, 0, 0), nil, false)
			CollectionService:AddTag(staticPart, tag)
			CollectionService:AddTag(physicsPart, tag)

			cullThrottle:CaptureTag(tag)
			expect(table.find(cullThrottle._lifecycle._physicsObjects, physicsPart)).toBeDefined()
			expect(table.find(cullThrottle._lifecycle._physicsObjects, staticPart)).toBeNil()

			-- Anchored is read once at capture and deliberately never watched, so
			-- flipping it afterwards must not migrate either part between modes.
			physicsPart.Anchored = true
			staticPart.Anchored = false
			task.wait()

			expect(table.find(cullThrottle._lifecycle._physicsObjects, physicsPart)).toBeDefined()
			expect(table.find(cullThrottle._lifecycle._physicsObjects, staticPart)).toBeNil()

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(staticPart, tag)
			CollectionService:RemoveTag(physicsPart, tag)
			staticPart:Destroy()
			physicsPart:Destroy()
		end)

		it("untracks a directly-added object when it loses its last captured tag", function()
			local tag = "DirectAddOverlapTag"
			local part = createMockPart()
			cullThrottle:AddObject(part)

			CollectionService:AddTag(part, tag)
			cullThrottle:CaptureTag(tag)
			expect(cullThrottle:IsTracking(part)).toBe(true)

			-- Tracking doesn't record how an object arrived, so losing the last
			-- captured tag untracks the object even though it was added directly
			-- first. The tag-removed handler and the README both document this
			-- contract, and a caller who wants the object to outlive its tags must
			-- re-add it after the toggle.
			CollectionService:RemoveTag(part, tag)
			task.wait()

			expect(cullThrottle:IsTracking(part)).toBe(false)

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
			expect(cullThrottle:IsTracking(part)).toBe(true)

			-- Losing one captured tag must not untrack the object while another
			-- captured tag still applies to it.
			CollectionService:RemoveTag(part, tagA)
			task.wait()
			expect(cullThrottle:IsTracking(part)).toBe(true)

			-- Losing the last captured tag untracks it for real.
			CollectionService:RemoveTag(part, tagB)
			task.wait()
			expect(cullThrottle:IsTracking(part)).toBe(false)

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

			expect(cullThrottle:IsTracking(part1)).toBe(true)
			expect(cullThrottle:IsTracking(part2)).toBe(true)
			expect(cullThrottle:IsTracking(folder)).toBe(false)

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(part1, tag)
			CollectionService:RemoveTag(folder, tag)
			CollectionService:RemoveTag(part2, tag)
			part1:Destroy()
			folder:Destroy()
			part2:Destroy()
		end)

		it("warns and skips a tagged Beam without attachments instead of erroring", function()
			local tag = "BeamCaptureTag"
			local beam = Instance.new("Beam")
			beam.Parent = workspace
			local part = createMockPart()
			CollectionService:AddTag(beam, tag)
			CollectionService:AddTag(part, tag)

			-- A Beam without attachments can't be placed or sized, so direct
			-- AddObject errors on it. The tag path is bulk and declarative, so the
			-- capture must warn about the beam and keep tracking everything else.
			-- The beam warnings in the test output here are expected.
			expect(function()
				cullThrottle:CaptureTag(tag)
			end).never.toThrow()

			expect(cullThrottle:IsTracking(beam)).toBe(false)
			expect(cullThrottle:IsTracking(part)).toBe(true)

			cullThrottle:ReleaseTag(tag)
			CollectionService:RemoveTag(beam, tag)
			CollectionService:RemoveTag(part, tag)
			beam:Destroy()
			part:Destroy()
		end)

		it("should not throw when every tagged instance is un-addable", function()
			local tag = "UnaddableCaptureTag"
			local folder = Instance.new("Folder")
			folder.Parent = workspace
			CollectionService:AddTag(folder, tag)

			expect(function()
				cullThrottle:CaptureTag(tag)
			end).never.toThrow()
			expect(cullThrottle:IsTracking(folder)).toBe(false)

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

			expect(cullThrottle:IsTracking(part)).toBe(false)

			CollectionService:RemoveTag(part, tag)
			part:Destroy()
		end)

		it("keeps objects captured through the tag tracked after the tag is released", function()
			local tag = "KeepTrackedTag"
			local part = createMockPart()
			CollectionService:AddTag(part, tag)

			cullThrottle:CaptureTag(tag)
			expect(cullThrottle:IsTracking(part)).toBe(true)

			cullThrottle:ReleaseTag(tag)

			-- Releasing a tag only stops watching it. Objects it already captured
			-- stay tracked until they're removed some other way.
			expect(cullThrottle:IsTracking(part)).toBe(true)

			-- With the listeners gone, losing the tag no longer untracks it either.
			CollectionService:RemoveTag(part, tag)
			task.wait()
			expect(cullThrottle:IsTracking(part)).toBe(true)

			part:Destroy()
		end)

		it("is a no-op for a tag that was never captured", function()
			local capturedTag = "CapturedSiblingTag"
			cullThrottle:CaptureTag(capturedTag)
			local capturedConnections = cullThrottle._lifecycle._tagConnections[capturedTag]

			-- Releasing a tag that was never captured must not throw and must not
			-- disturb the connections of a tag that was.
			expect(function()
				cullThrottle:ReleaseTag("NeverCapturedTag")
			end).never.toThrow()

			expect(cullThrottle._lifecycle._tagConnections[capturedTag]).toBe(capturedConnections)
			for _, connection in capturedConnections do
				expect(connection.Connected).toBe(true)
			end

			cullThrottle:ReleaseTag(capturedTag)
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

			expect(cullThrottle:IsTracking(part1)).toBe(false)
			expect(cullThrottle:IsTracking(part2)).toBe(false)
			expect(cullThrottle:IsTracking(part3)).toBe(true)

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
				if not cullThrottle:IsTracking(extra) then
					cullThrottle:AddObject(extra)
				end
			end)

			expect(function()
				cullThrottle:RemoveObjectsWithTag(tag)
			end).never.toThrow()

			-- Every tagged object was removed despite the mid-loop insertion.
			for _, part in tagged do
				expect(cullThrottle:IsTracking(part)).toBe(false)
			end
			-- The object added by the handler survived (it isn't tagged, so the
			-- pre-removal snapshot never included it).
			expect(cullThrottle:IsTracking(extra)).toBe(true)

			connection:Disconnect()
			for _, part in tagged do
				CollectionService:RemoveTag(part, tag)
				part:Destroy()
			end
			extra:Destroy()
		end)
	end)
end)
