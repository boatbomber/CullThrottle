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
		local enteredFires = 0
		local firedObject = nil

		local connection = cullThrottle.ObjectEnteredView:Connect(function(obj)
			enteredFires += 1
			firedObject = obj
		end)

		cullThrottle:AddObject(part)
		ingestObjects(cullThrottle, os.clock(), { part })

		-- The signal is buffered during ingest and fired only on flush, so a
		-- handler can't mutate the tracked set mid-iteration.
		expect(enteredFires).toBe(0)

		cullThrottle._signals:flushVisibilitySignals()

		expect(enteredFires).toBe(1)
		expect(firedObject).toBe(part)

		-- The flush consumed the buffer, so flushing again fires nothing.
		cullThrottle._signals:flushVisibilitySignals()
		expect(enteredFires).toBe(1)

		connection:Disconnect()
		part:Destroy()
	end)

	it("should fire ObjectExitedView when object becomes invisible", function()
		local part = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part)

		local now = os.clock()
		markInView(cullThrottle, part, now - 1)

		local exitedFires = 0
		local firedObject = nil

		local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
			exitedFires += 1
			firedObject = obj
		end)

		cullThrottle._signals:signalVisibilityChanges(now)

		-- It's buffered during the visibility pass and fired only on flush.
		expect(exitedFires).toBe(0)

		cullThrottle._signals:flushVisibilitySignals()

		expect(exitedFires).toBe(1)
		expect(firedObject).toBe(part)

		-- The flush consumed the buffer, so flushing again fires nothing.
		cullThrottle._signals:flushVisibilitySignals()
		expect(exitedFires).toBe(1)

		connection:Disconnect()
		part:Destroy()
	end)

	it("fires ObjectEnteredView once for an object marked visible on consecutive frames", function()
		local part = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part)

		local enteredFires = 0
		local connection = cullThrottle.ObjectEnteredView:Connect(function()
			enteredFires += 1
		end)

		-- Staying visible frame after frame is the steady state, and only the
		-- flip from out of view to in view may buffer an entered event. A repeat
		-- mark must neither buffer another event nor grow the in-view set.
		local now = os.clock()
		markInView(cullThrottle, part, now)
		markInView(cullThrottle, part, now + 0.05)
		cullThrottle._signals:flushVisibilitySignals()

		expect(enteredFires).toBe(1)
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		connection:Disconnect()
		part:Destroy()
	end)

	it("fires all entered signals before any exited signals in a flush", function()
		local enteringPart = createMockPart(Vector3.new(0, 0, 0))
		local exitingPart = createMockPart(Vector3.new(10, 0, 0))
		cullThrottle:AddObject(enteringPart)
		cullThrottle:AddObject(exitingPart)

		-- The exiting object entered view on an earlier frame, with its own
		-- entered event already flushed before the recorders connect.
		local now = os.clock()
		markInView(cullThrottle, exitingPart, now - 1)
		cullThrottle._signals:flushVisibilitySignals()

		local order = {}
		local enteredConnection = cullThrottle.ObjectEnteredView:Connect(function(obj)
			table.insert(order, { signal = "entered", object = obj })
		end)
		local exitedConnection = cullThrottle.ObjectExitedView:Connect(function(obj)
			table.insert(order, { signal = "exited", object = obj })
		end)

		-- One object exits in the same frame another enters. The exit is even
		-- buffered first here, yet the flush still delivers arrivals before
		-- departures, so a consumer always hears about the replacement before
		-- the vacancy.
		cullThrottle._signals:signalVisibilityChanges(now)
		markInView(cullThrottle, enteringPart, now)
		cullThrottle._signals:flushVisibilitySignals()

		expect(#order).toBe(2)
		expect(order[1].signal).toBe("entered")
		expect(order[1].object).toBe(enteringPart)
		expect(order[2].signal).toBe("exited")
		expect(order[2].object).toBe(exitingPart)

		enteredConnection:Disconnect()
		exitedConnection:Disconnect()
		enteringPart:Destroy()
		exitingPart:Destroy()
	end)

	it("releases each pending buffer slot when the flush fires it", function()
		-- The pending buffers are reused between frames behind a size counter,
		-- so a flush that only reset the counter would keep the last frame's
		-- instances pinned in the arrays until some later frame overwrote
		-- them. Each fired slot must be released immediately.
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(10, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)

		local now = os.clock()
		markInView(cullThrottle, part1, now - 1)
		markInView(cullThrottle, part2, now - 1)

		local signals = cullThrottle._signals
		expect(signals._pendingEnteredView[1]).never.toBeNil()
		expect(signals._pendingEnteredView[2]).never.toBeNil()

		cullThrottle._signals:flushVisibilitySignals()

		expect(signals._pendingEnteredView[1]).toBeNil()
		expect(signals._pendingEnteredView[2]).toBeNil()

		-- The exit sweep buffers both stale objects, and flushing the exits
		-- must release those slots the same way.
		cullThrottle._signals:signalVisibilityChanges(now)
		expect(signals._pendingExitedView[1]).never.toBeNil()
		expect(signals._pendingExitedView[2]).never.toBeNil()

		cullThrottle._signals:flushVisibilitySignals()

		expect(signals._pendingExitedView[1]).toBeNil()
		expect(signals._pendingExitedView[2]).toBeNil()

		part1:Destroy()
		part2:Destroy()
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
		local enteredFires = 0
		local exitedConnection = cullThrottle.ObjectExitedView:Connect(function()
			exited = true
		end)
		local enteredConnection = cullThrottle.ObjectEnteredView:Connect(function()
			enteredFires += 1
		end)

		local t = os.clock()
		markInView(cullThrottle, part, t)

		-- The object was last visible 0.1 ago, within the 0.2 exit grace period,
		-- so the exit is held back and it stays in the in-view set.
		cullThrottle._signals:signalVisibilityChanges(t + 0.1)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(false)
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		-- It comes back into view during the linger through the same markVisible
		-- path ingest uses. Its lastVisibleClock never returned to zero, so the
		-- enter-once guard recognizes it as still in view and fires no duplicate
		-- entered signal beyond the original entry.
		markInView(cullThrottle, part, t + 0.15)
		cullThrottle._signals:signalVisibilityChanges(t + 0.3)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(false)
		expect(enteredFires).toBe(1)
		expect(cullThrottle._signals._objectsInViewSize).toBe(1)

		-- Once we're out past the grace, the exit fires and the in-view entry is dropped.
		cullThrottle._signals:signalVisibilityChanges(t + 0.4)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(true)
		expect(cullThrottle._signals._objectsInViewSize).toBe(0)
		expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

		enteredConnection:Disconnect()
		exitedConnection:Disconnect()
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

	it("exits every consecutive stale entry in a single sweep", function()
		-- The sweep swap-removes a stale entry by pulling the tail entry into
		-- its slot, and when the tail is stale too the swapped-in entry must
		-- get rechecked at the same index instead of skipped. One fresh object
		-- ahead of four stale ones forces that swap chain on every removal.
		local freshPart = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(freshPart)

		local now = os.clock()
		markInView(cullThrottle, freshPart, now)

		local staleParts = {}
		for i = 1, 4 do
			staleParts[i] = createMockPart(Vector3.new(i * 10, 0, 0))
			cullThrottle:AddObject(staleParts[i])
			markInView(cullThrottle, staleParts[i], now - 1)
		end
		cullThrottle._signals:flushVisibilitySignals()

		local exitedCount = 0
		local exited = {}
		local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
			exitedCount += 1
			exited[obj] = true
		end)

		cullThrottle._signals:signalVisibilityChanges(now)
		cullThrottle._signals:flushVisibilitySignals()

		expect(exitedCount).toBe(4)
		for _, part in staleParts do
			expect(exited[part]).toBe(true)
		end

		-- Only the fresh object keeps its place, and the freed slots are nil.
		local signals = cullThrottle._signals
		expect(signals._objectsInViewSize).toBe(1)
		expect(signals._objectsInView[1].object).toBe(freshPart)
		expect(signals._objectsInView[2]).toBeNil()

		connection:Disconnect()
		freshPart:Destroy()
		for _, part in staleParts do
			part:Destroy()
		end
	end)

	it("cleans up an object that re-entered view after an earlier exit", function()
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)

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

	it("preserves the in-view set and its indices across a buffer resize", function()
		local parts = {}
		local now = os.clock()
		for i = 1, 5 do
			parts[i] = createMockPart(Vector3.new(i * 10, 0, 0))
			cullThrottle:AddObject(parts[i])
			markInView(cullThrottle, parts[i], now)
		end
		cullThrottle._signals:flushVisibilitySignals()

		cullThrottle._signals:resizeBuffers()

		-- The rebuilt array must hold exactly the in-view objects, each with its
		-- stored index pointing at its own slot, or the swap-remove bookkeeping
		-- falls apart. Which slot any particular object lands in is the
		-- container's own business.
		local signals = cullThrottle._signals
		expect(signals._objectsInViewSize).toBe(5)
		local seen = {}
		for i = 1, 5 do
			local objectData = signals._objectsInView[i]
			expect(objectData.inViewIndex).toBe(i)
			seen[objectData.object] = true
		end
		for _, part in parts do
			expect(seen[part]).toBe(true)
		end

		-- A removal still finds and evicts its object through the stored index.
		cullThrottle:RemoveObject(parts[2])
		expect(signals._objectsInViewSize).toBe(4)

		-- And the exit sweep still walks the rebuilt array cleanly.
		local exitedCount = 0
		local connection = cullThrottle.ObjectExitedView:Connect(function()
			exitedCount += 1
		end)
		cullThrottle._signals:signalVisibilityChanges(now + 1)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exitedCount).toBe(4)
		expect(signals._objectsInViewSize).toBe(0)

		connection:Disconnect()
		for _, part in parts do
			part:Destroy()
		end
	end)

	it("delivers a clean signal cycle after resizing between frames", function()
		-- A resize recreates the pending arrays empty without touching their
		-- size counters, which is only safe while both buffers are already
		-- flushed. The driver resizes between frames where that holds, so this
		-- walks the same sequence and checks a full signal cycle still
		-- delivers through the rebuilt buffers.
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(10, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)

		-- One full frame cycle ends flushed, with nothing pending.
		local now = os.clock()
		markInView(cullThrottle, part1, now - 1)
		cullThrottle._signals:flushVisibilitySignals()

		local signals = cullThrottle._signals
		expect(signals._pendingEnteredViewSize).toBe(0)
		expect(signals._pendingExitedViewSize).toBe(0)

		cullThrottle._signals:resizeBuffers()

		local entered = 0
		local exited = 0
		local enteredConnection = cullThrottle.ObjectEnteredView:Connect(function()
			entered += 1
		end)
		local exitedConnection = cullThrottle.ObjectExitedView:Connect(function()
			exited += 1
		end)

		-- The next frame enters one object and exits the other through the
		-- rebuilt buffers.
		markInView(cullThrottle, part2, now)
		cullThrottle._signals:signalVisibilityChanges(now)
		cullThrottle._signals:flushVisibilitySignals()

		expect(entered).toBe(1)
		expect(exited).toBe(1)

		enteredConnection:Disconnect()
		exitedConnection:Disconnect()
		part1:Destroy()
		part2:Destroy()
	end)
end)
