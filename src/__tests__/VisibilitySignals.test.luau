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
local ingestObjects = TestHelpers.ingestObjects
local fastIngestObjects = TestHelpers.fastIngestObjects
local markInView = TestHelpers.markInView

describe("VisibilitySignals", function()
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

	it("should fire ObjectEnteredView when object becomes visible", function()
		local part = createMockPart(Vector3.new(0, 0, 0))
		local fired = false
		local firedObject = nil

		local connection = cullThrottle.ObjectEnteredView:Connect(function(obj)
			fired = true
			firedObject = obj
		end)

		cullThrottle:AddObject(part)
		cullThrottle._lifecycle._objects[part].lastVisibleClock = 0
		ingestObjects(cullThrottle, os.clock(), { part })

		-- The signal is buffered during ingest and fired only on flush, so a
		-- handler can't mutate the tracked set mid-iteration.
		expect(fired).toBe(false)

		cullThrottle._signals:flushVisibilitySignals()

		expect(fired).toBe(true)
		expect(firedObject).toBe(part)

		connection:Disconnect()
		part:Destroy()
	end)

	it("should fire ObjectExitedView when object becomes invisible", function()
		local part = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part)

		local now = os.clock()
		markInView(cullThrottle, part, now - 1)

		local fired = false
		local firedObject = nil

		local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
			fired = true
			firedObject = obj
		end)

		cullThrottle._signals:signalVisibilityChanges(now)

		-- It's buffered during the visibility pass and fired only on flush.
		expect(fired).toBe(false)

		cullThrottle._signals:flushVisibilitySignals()

		expect(fired).toBe(true)
		expect(firedObject).toBe(part)

		connection:Disconnect()
		part:Destroy()
	end)

	it("should let an entered-view handler remove another object without skipping it", function()
		-- Two objects share a voxel, and the handler removes the other object
		-- the moment one enters view. Because the entered-view signals are
		-- buffered and fired only after the ingest pass finishes iterating the
		-- voxel, both still get their event. Firing synchronously mid-ingest
		-- would have mutated the voxel array and skipped the second object.
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)

		local voxelKey = next(cullThrottle._lifecycle._objects[part1].voxelKeys)
		local voxel = cullThrottle._grid._voxels[voxelKey]
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

		cullThrottle._lifecycle._objects[part1].lastVisibleClock = 0
		cullThrottle._lifecycle._objects[part2].lastVisibleClock = 0

		expect(function()
			ingestObjects(cullThrottle, os.clock(), { part1, part2 })
			cullThrottle._signals:flushVisibilitySignals()
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
		-- mutates the in-view set. Deferring the fire to after
		-- signalVisibilityChanges finishes its scan makes it safe.
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)

		local now = os.clock()
		markInView(cullThrottle, part1, now - 1)
		markInView(cullThrottle, part2, now - 1)

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
			cullThrottle._signals:signalVisibilityChanges(now)
			cullThrottle._signals:flushVisibilitySignals()
		end).never.toThrow()

		expect(exited[part1]).toBe(true)
		expect(exited[part2]).toBe(true)

		connection:Disconnect()
		part1:Destroy()
		part2:Destroy()
	end)

	it("holds the exit signal briefly so boundary flicker doesn't fire per frame", function()
		local part = createMockPart()
		cullThrottle:AddObject(part)

		local exited = false
		local connection = cullThrottle.ObjectExitedView:Connect(function()
			exited = true
		end)

		local t = os.clock()
		markInView(cullThrottle, part, t)

		-- The object was last visible 0.1 ago, within the 0.2 exit grace period,
		-- so the exit is held back and it stays in the in-view set.
		cullThrottle._signals:signalVisibilityChanges(t + 0.1)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(false)
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		-- It came back into view during the linger, so nothing ever fires, and
		-- no duplicate entered signal is needed since it never exited.
		cullThrottle._lifecycle._objects[part].lastVisibleClock = t + 0.15
		cullThrottle._signals:signalVisibilityChanges(t + 0.3)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(false)
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		-- Once we're out past the grace, the exit fires and the in-view entry is dropped.
		cullThrottle._signals:signalVisibilityChanges(t + 0.4)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(true)
		expect(cullThrottle._signals._objectsInViewSize).toBe(0)
		expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

		connection:Disconnect()
		part:Destroy()
	end)

	it("removes an object that the exit sweep swapped into a new slot", function()
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		local part3 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)
		cullThrottle:AddObject(part3)

		-- Only the first object is stale, so the sweep exits it and swap-moves the
		-- last entry into its slot.
		local now = os.clock()
		markInView(cullThrottle, part1, now - 1)
		markInView(cullThrottle, part2, now)
		markInView(cullThrottle, part3, now)
		cullThrottle._signals:signalVisibilityChanges(now)
		expect(cullThrottle._signals._objectsInViewSize).toBe(2)

		-- The moved entry must be removable from its new slot, leaving only the
		-- middle object behind.
		cullThrottle:RemoveObject(part3)

		local signals = cullThrottle._signals
		expect(signals._objectsInViewSize).toBe(1)
		expect(signals._objectsInView[1].object).toBe(part2)
		expect(signals._objectsInView[2]).toBeNil()

		cullThrottle._signals:flushVisibilitySignals()
		part1:Destroy()
		part2:Destroy()
		part3:Destroy()
	end)

	it("cleans up an object that re-entered view after an earlier exit", function()
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)
		cullThrottle._lifecycle._objects[part1].lastVisibleClock = 0
		cullThrottle._lifecycle._objects[part2].lastVisibleClock = 0

		-- Both enter view, both exit past the grace period, and then only the
		-- second one re-enters, landing in a different slot than its first stay.
		local now = os.clock()
		ingestObjects(cullThrottle, now, { part1, part2 })
		cullThrottle._signals:signalVisibilityChanges(now + 1)
		ingestObjects(cullThrottle, now + 2, { part2 })
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		-- Removing it must clear its current in-view entry, not whatever slot it
		-- occupied the first time around.
		cullThrottle:RemoveObject(part2)
		expect(cullThrottle._signals._objectsInViewSize).toBe(0)
		expect(next(cullThrottle._signals._objectsInView)).toBeNil()

		cullThrottle._signals:flushVisibilitySignals()
		part1:Destroy()
		part2:Destroy()
	end)

	it("cleans up an object the fast ingest pass re-entered after an earlier exit", function()
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)
		cullThrottle._lifecycle._objects[part1].lastVisibleClock = 0
		cullThrottle._lifecycle._objects[part2].lastVisibleClock = 0

		-- This is the same exit-then-re-enter shuffle as above, but the re-entry
		-- goes through the fast approximate pass, which records the entered-view
		-- bookkeeping at its own site.
		local now = os.clock()
		fastIngestObjects(cullThrottle, now, { part1, part2 })
		cullThrottle._signals:signalVisibilityChanges(now + 1)
		fastIngestObjects(cullThrottle, now + 2, { part2 })
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		cullThrottle:RemoveObject(part2)
		expect(cullThrottle._signals._objectsInViewSize).toBe(0)
		expect(next(cullThrottle._signals._objectsInView)).toBeNil()

		cullThrottle._signals:flushVisibilitySignals()
		part1:Destroy()
		part2:Destroy()
	end)
end)
