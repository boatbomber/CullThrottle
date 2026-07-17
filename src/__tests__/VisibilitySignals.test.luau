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
		expect(cullThrottle._signals._inViewCount).toBe(1)

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
		-- mutates the in-view bookkeeping. Deferring the fire to after
		-- signalVisibilityChanges finishes its sweep makes it safe.
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
		expect(cullThrottle._signals._inViewCount).toBe(1)

		-- It comes back into view during the linger through the same markVisible
		-- path ingest uses. Its lastVisibleClock never returned to zero, so the
		-- enter-once guard recognizes it as still in view and fires no duplicate
		-- entered signal beyond the original entry.
		markInView(cullThrottle, part, t + 0.15)
		cullThrottle._signals:signalVisibilityChanges(t + 0.3)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(false)
		expect(enteredFires).toBe(1)
		expect(cullThrottle._signals._inViewCount).toBe(1)

		-- Once we're out past the grace, the exit fires and the in-view entry is dropped.
		cullThrottle._signals:signalVisibilityChanges(t + 0.4)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(true)
		expect(cullThrottle._signals._inViewCount).toBe(0)
		expect(cullThrottle._lifecycle._objects[part].lastVisibleClock).toBe(0)

		enteredConnection:Disconnect()
		exitedConnection:Disconnect()
		part:Destroy()
	end)

	it("only touches a steadily visible object when its grace deadline comes due", function()
		local part = createMockPart()
		cullThrottle:AddObject(part)
		local objectData = cullThrottle._lifecycle._objects[part]

		local t = os.clock()
		markInView(cullThrottle, part, t)
		local scheduledBucket = objectData.exitSweepBucketIndex
		expect(scheduledBucket > 0).toBe(true)

		-- A sweep before the deadline's bucket comes due never opens it, and a
		-- repeat sighting is just the inline clock stamp, so the entry stays
		-- exactly where the entry flip scheduled it.
		cullThrottle._signals:signalVisibilityChanges(t + 0.05)
		markInView(cullThrottle, part, t + 0.1)
		expect(objectData.exitSweepBucketIndex).toBe(scheduledBucket)

		-- Once the original deadline comes due, the sweep sees the newer
		-- sighting and reschedules the object at the deadline that sighting
		-- implies, in a strictly later bucket.
		cullThrottle._signals:signalVisibilityChanges(t + 0.25)
		expect(objectData.exitSweepBucketIndex > scheduledBucket).toBe(true)
		expect(cullThrottle._signals._inViewCount).toBe(1)

		-- With no further sightings, the rescheduled deadline expires and the
		-- object exits.
		local exited = false
		local connection = cullThrottle.ObjectExitedView:Connect(function()
			exited = true
		end)
		cullThrottle._signals:signalVisibilityChanges(t + 0.4)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toBe(true)
		expect(cullThrottle._signals._inViewCount).toBe(0)

		connection:Disconnect()
		part:Destroy()
	end)

	it("re-anchors the sweep after an idle stretch with nothing in view", function()
		local part = createMockPart()
		cullThrottle:AddObject(part)
		local signals = cullThrottle._signals

		-- One full stay ends with nothing left in view.
		local t = os.clock()
		markInView(cullThrottle, part, t)
		signals:signalVisibilityChanges(t + 1)
		expect(signals._inViewCount).toBe(0)

		-- Sweeps during the idle stretch park the resume point just past their
		-- own clock instead of crawling the empty range.
		signals:signalVisibilityChanges(t + 50)
		local idleResumePoint = signals._nextSweepBucketIndex

		-- The next entry after a stretch with no sweeps at all re-anchors the
		-- resume point at the present, so the following sweep starts near its
		-- own clock and the fresh stay still exits on schedule.
		markInView(cullThrottle, part, t + 100)
		expect(signals._nextSweepBucketIndex > idleResumePoint).toBe(true)

		local exited = false
		local connection = cullThrottle.ObjectExitedView:Connect(function()
			exited = true
		end)
		signals:signalVisibilityChanges(t + 101)
		signals:flushVisibilitySignals()
		expect(exited).toBe(true)

		connection:Disconnect()
		part:Destroy()
	end)

	it("evicts an object from the bucket the sweep rescheduled it into", function()
		local part1 = createMockPart(Vector3.new(0, 0, 0))
		local part2 = createMockPart(Vector3.new(0, 0, 0))
		local part3 = createMockPart(Vector3.new(0, 0, 0))
		cullThrottle:AddObject(part1)
		cullThrottle:AddObject(part2)
		cullThrottle:AddObject(part3)

		-- The first object goes stale while the other two are seen again
		-- before their first deadline comes due, so the sweep exits the stale
		-- one and reschedules the fresh pair into a later bucket.
		local now = os.clock()
		markInView(cullThrottle, part1, now - 1)
		markInView(cullThrottle, part2, now)
		markInView(cullThrottle, part3, now)
		local objects = cullThrottle._lifecycle._objects
		local firstBucket = objects[part3].exitSweepBucketIndex

		markInView(cullThrottle, part2, now + 0.1)
		markInView(cullThrottle, part3, now + 0.1)
		cullThrottle._signals:signalVisibilityChanges(now + 0.25)
		cullThrottle._signals:flushVisibilitySignals()

		local signals = cullThrottle._signals
		expect(signals._inViewCount).toBe(2)
		expect(objects[part3].exitSweepBucketIndex).never.toBe(firstBucket)

		-- The moved entry must be evictable from the bucket it lives in now,
		-- leaving only the middle object behind for the final sweep to report.
		cullThrottle:RemoveObject(part3)
		expect(signals._inViewCount).toBe(1)

		local exited = {}
		local connection = cullThrottle.ObjectExitedView:Connect(function(obj)
			table.insert(exited, obj)
		end)
		cullThrottle._signals:signalVisibilityChanges(now + 1)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exited).toEqual({ part2 })

		connection:Disconnect()
		part1:Destroy()
		part2:Destroy()
		part3:Destroy()
	end)

	it("exits every stale entry in a due bucket in a single sweep", function()
		-- One fresh object and four stale ones. Every stale entry in the due
		-- range must exit in the same sweep, while the fresh object's bucket
		-- isn't due and never gets opened.
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

		-- Only the fresh object keeps its place.
		expect(cullThrottle._signals._inViewCount).toBe(1)

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
		-- second one re-enters, landing in a different bucket than its first stay.
		local now = os.clock()
		ingestObjects(cullThrottle, now, { part1, part2 })
		cullThrottle._signals:signalVisibilityChanges(now + 1)
		ingestObjects(cullThrottle, now + 2, { part2 })
		expect(cullThrottle._signals._inViewCount).toBe(1)

		-- Removing it must clear its current entry, not whatever slot it
		-- occupied the first time around.
		cullThrottle:RemoveObject(part2)
		expect(cullThrottle._signals._inViewCount).toBe(0)
		expect(next(cullThrottle._signals._exitSweepBuckets)).toBeNil()

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
		expect(cullThrottle._signals._inViewCount).toBe(1)

		cullThrottle:RemoveObject(part2)
		expect(cullThrottle._signals._inViewCount).toBe(0)
		expect(next(cullThrottle._signals._exitSweepBuckets)).toBeNil()

		cullThrottle._signals:flushVisibilitySignals()
		part1:Destroy()
		part2:Destroy()
	end)

	it("keeps the scheduled entries intact across a buffer resize", function()
		local parts = {}
		local now = os.clock()
		for i = 1, 5 do
			parts[i] = createMockPart(Vector3.new(i * 10, 0, 0))
			cullThrottle:AddObject(parts[i])
			markInView(cullThrottle, parts[i], now)
		end
		cullThrottle._signals:flushVisibilitySignals()

		cullThrottle._signals:resizeBuffers()

		-- The resize only rebuilds the pending buffers and drops the bucket
		-- pool, so everything scheduled stays scheduled with its stored
		-- position still valid.
		local signals = cullThrottle._signals
		expect(signals._inViewCount).toBe(5)

		-- A removal still finds and evicts its object through the stored position.
		cullThrottle:RemoveObject(parts[2])
		expect(signals._inViewCount).toBe(4)

		-- And the exit sweep still drains the remaining entries cleanly.
		local exitedCount = 0
		local connection = cullThrottle.ObjectExitedView:Connect(function()
			exitedCount += 1
		end)
		cullThrottle._signals:signalVisibilityChanges(now + 1)
		cullThrottle._signals:flushVisibilitySignals()
		expect(exitedCount).toBe(4)
		expect(signals._inViewCount).toBe(0)

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
