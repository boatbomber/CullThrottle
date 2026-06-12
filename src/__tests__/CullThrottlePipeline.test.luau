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
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local markInView = TestHelpers.markInView
local visibleVoxelProof = TestHelpers.visibleVoxelProof

describe("CullThrottle frame pipeline", function()
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

	describe("_processObjectVisibility", function()
		it("returns the skipped tallies to zero on a frame that skips nothing", function()
			-- A bad frame leaves nonzero tallies behind in the ring slots, and a
			-- healthy frame must not inherit them, or the render distance
			-- controller would keep shrinking on stale pressure after the load
			-- has passed.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)
			cullThrottle:SetTimeBudgets(1, 1, 1)

			local perfMetrics = cullThrottle._perfMetrics
			for i in perfMetrics._skippedIngest do
				perfMetrics._skippedIngest[i] = 7
				perfMetrics._skippedSearch[i] = 7
			end

			cullThrottle:_findVisibleObjects(os.clock())

			local metrics = cullThrottle:GetPerformanceMetrics()
			expect(metrics.skippedSearch).toBe(0)
			expect(metrics.skippedIngest).toBe(0)

			part:Destroy()
		end)

		it("fires view signals through the frame pipeline as objects enter and leave view", function()
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			cullThrottle:SetTimeBudgets(1, 1, 1)

			local enteredCount, exitedCount = 0, 0
			cullThrottle.ObjectEnteredView:Connect(function(object)
				if object == part then
					enteredCount += 1
				end
			end)
			cullThrottle.ObjectExitedView:Connect(function(object)
				if object == part then
					exitedCount += 1
				end
			end)

			local now = os.clock()
			cullThrottle:_processObjectVisibility(now)
			expect(enteredCount).toBe(1)
			expect(exitedCount).toBe(0)

			-- A second frame with the part still visible must not fire a
			-- duplicate entered signal.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(now + 0.05)
			expect(enteredCount).toBe(1)

			-- Move the part behind the camera, staged the way the change
			-- connections record a move. The next frame's voxel maintenance
			-- applies it, the search stops finding the part, and once it has
			-- been out of view past the exit grace period the sweep buffers the
			-- exit signal for the end-of-frame flush.
			local behind = (camera.CFrame * CFrame.new(0, 0, 120)).Position
			part.Position = behind
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.cframe = CFrame.new(behind)
			objectData.position = behind
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			-- A frame processed at the same clock the part was last seen sits at
			-- the very start of the exit grace period, so no exit can fire here
			-- no matter how the grace period is tuned.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(now + 0.05)
			expect(exitedCount).toBe(0)

			-- Backdating the last-seen stamp far past any plausible grace period
			-- forces the sweep to give up on the part this frame, which pins the
			-- pipeline wiring without coupling to the grace constant. The exact
			-- constant is pinned in the VisibilitySignals suite.
			objectData.lastVisibleClock = now - 1000
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(now + 0.1)
			expect(exitedCount).toBe(1)
			expect(enteredCount).toBe(1)

			part:Destroy()
		end)

		it("polls physics objects through the frame pipeline", function()
			local part = createMockPart(Vector3.new(0, 0, 0), nil, false)
			cullThrottle:AddPhysicsObject(part)

			-- Physics-driven motion changes a part's CFrame without firing the
			-- change signal, so the listeners get disconnected to mimic that.
			-- The pipeline's poll is then the only thing that can notice the move.
			local objectData = cullThrottle._lifecycle._objects[part]
			for _, connection in objectData.changeConnections do
				connection:Disconnect()
			end
			part.Position = Vector3.new(50, 0, 0)

			cullThrottle:_processObjectVisibility(os.clock())

			expect(objectData.position.X).toBeCloseTo(50)

			part:Destroy()
		end)

		it("applies queued voxel moves through the frame pipeline", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- Stage a queued move into a different voxel the way the change
			-- connections record one, then let the pipeline's voxel maintenance
			-- apply it.
			objectData.cframe = CFrame.new(450, 50, 50)
			objectData.position = Vector3.new(450, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			expect(objectData.voxelKeys[Vector3.new(4, 0, 0)]).toBeUndefined()

			cullThrottle:_processObjectVisibility(os.clock())

			expect(objectData.voxelKeys[Vector3.new(4, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBeUndefined()

			part:Destroy()
		end)

		it("adjusts the render distance through the frame pipeline", function()
			-- Stage one frame's worth of very slow object updates. The pipeline
			-- commits them into the average delta time at the start of the pass,
			-- and the controller step at the end must see a load far over budget
			-- and shrink the render distance.
			cullThrottle._perfMetrics._sumOfObjectDeltaTimes = 100
			cullThrottle._perfMetrics._updatedObjectCount = 1

			local initialRenderDistance = cullThrottle._config.renderDistance
			cullThrottle:_processObjectVisibility(os.clock())

			expect(cullThrottle._config.renderDistance).toBeLessThan(initialRenderDistance)
		end)

		it("keeps a lingering object out of the queries while its exit grace runs", function()
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			cullThrottle:SetTimeBudgets(1, 1, 1)

			local exitedCount = 0
			cullThrottle.ObjectExitedView:Connect(function(object)
				if object == part then
					exitedCount += 1
				end
			end)

			local now = os.clock()
			cullThrottle:_processObjectVisibility(now)
			expect(table.find(cullThrottle:GetVisibleObjects(), part)).never.toBeNil()

			-- Move the part behind the camera, staged the way the change
			-- connections record a move, so the next frame's search stops
			-- finding it.
			local behind = (camera.CFrame * CFrame.new(0, 0, 120)).Position
			part.Position = behind
			local objectData = cullThrottle._lifecycle._objects[part]
			objectData.cframe = CFrame.new(behind)
			objectData.position = behind
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			-- Processing at the same clock the part was last seen lands inside
			-- the exit grace period for any tuning, so the part lingers in the
			-- in-view set without ObjectExitedView having fired yet.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(now)

			expect(exitedCount).toBe(0)
			-- A nonzero last-visible stamp is what lingering means, the sweep
			-- hasn't given up on the object.
			expect(objectData.lastVisibleClock).never.toBe(0)

			-- The grace period is signal smoothing only, so the lingering object
			-- must not come back from the queries or take update budget.
			expect(table.find(cullThrottle:GetVisibleObjects(), part)).toBeNil()
			local updateCount = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				updateCount += 1
			end
			expect(updateCount).toBe(0)

			part:Destroy()
		end)

		it("completes a frame with every budget at zero and still sweeps the exit signals", function()
			-- The part sits far beyond render distance so the frame can't
			-- re-mark it visible and reset the staged grace period below.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, 5000)).Position)
			cullThrottle:AddObject(part)

			-- Stage the part as having been in view long ago so the sweep has
			-- work to do even though the searches are budgeted off.
			local now = os.clock()
			markInView(cullThrottle, part, now - 100)

			local exitedCount = 0
			cullThrottle.ObjectExitedView:Connect(function(object)
				if object == part then
					exitedCount += 1
				end
			end)

			cullThrottle:SetTimeBudgets(0, 0, 0)

			expect(function()
				cullThrottle:_processObjectVisibility(now)
			end).never.toThrow()

			-- Zero budgets skip the work rather than erroring, so nothing becomes
			-- visible and nothing is yielded for update, but the exit sweep and
			-- the end-of-frame signal flush still run.
			expect(#cullThrottle:GetVisibleObjects()).toBe(0)
			local updateCount = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				updateCount += 1
			end
			expect(updateCount).toBe(0)
			expect(exitedCount).toBe(1)

			part:Destroy()
		end)

		it("lets a view signal handler query the snapshot without recomputing the frame", function()
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			cullThrottle:SetTimeBudgets(1, 1, 1)

			local findCalls = 0
			cullThrottle._findVisibleObjects = function(self, now)
				findCalls += 1
				return CullThrottle._findVisibleObjects(self, now)
			end

			-- Re-entering from inside the flush must short-circuit onto this
			-- frame's results instead of recursing into another visibility pass.
			local snapshot
			cullThrottle.ObjectEnteredView:Connect(function()
				snapshot = cullThrottle:GetVisibleObjects()
			end)

			cullThrottle:_processObjectVisibility(os.clock())

			expect(snapshot).toBeDefined()
			expect(table.find(snapshot, part)).never.toBeNil()
			expect(findCalls).toBe(1)

			part:Destroy()
		end)
	end)

	describe("camera motion", function()
		local savedCameraCFrame

		beforeEach(function()
			savedCameraCFrame = workspace.CurrentCamera.CFrame
		end)

		afterEach(function()
			-- Restoring in afterEach keeps a failed assertion from stranding the
			-- shared camera in a moved pose for every later suite. The wait lets
			-- the deferred CFrame change signal propagate back into the camera
			-- cache before the next test anchors against it.
			workspace.CurrentCamera.CFrame = savedCameraCFrame
			task.wait()
		end)

		it("advances the motion accumulators when the camera moves between frames", function()
			local motion = cullThrottle._motion

			-- One processed frame anchors the motion tracker at the camera's
			-- current pose, so the move below is the only motion in play.
			cullThrottle:_findVisibleObjects(os.clock())
			local translationBefore = motion._accumT

			-- A 150 stud move is 1.5 voxels at the default 100 stud voxel size,
			-- nowhere near the re-anchor flush limit.
			local camera = workspace.CurrentCamera
			camera.CFrame = camera.CFrame * CFrame.new(0, 0, -150)
			-- The CFrame change signal fires deferred, so let it propagate into
			-- the camera cache before the next frame reads it.
			task.wait()

			-- Cached visibility verdicts can only be trusted if the frame
			-- pipeline charges the accumulators for this move before consulting
			-- any of them. Skipping the charge would make every cached proof
			-- immortal.
			cullThrottle:_findVisibleObjects(os.clock())

			expect(motion._accumT - translationBefore).toBeCloseTo(1.5, 3)
		end)
	end)

	describe("PreRender loop", function()
		it("computes visibility every frame by default", function()
			local processedFrames = 0
			cullThrottle._processObjectVisibility = function()
				processedFrames += 1
			end

			-- Give the render loop a little real time to take at least one step.
			local deadline = os.clock() + 0.5
			while processedFrames == 0 and os.clock() < deadline do
				task.wait()
			end

			expect(processedFrames).toBeGreaterThanOrEqual(1)
		end)

		it("skips the per-frame computation in on-demand mode", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			local processedFrames = 0
			cullThrottle._processObjectVisibility = function()
				processedFrames += 1
			end

			-- Give the render loop several real frames in which a regression
			-- would wrongly fire.
			for _ = 1, 5 do
				task.wait()
			end

			expect(processedFrames).toBe(0)
		end)

		it("computes every frame in on-demand mode while a view signal is connected", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			-- Entered and exited signals can only fire if visibility gets
			-- computed, so a connected handler counts as standing demand.
			cullThrottle.ObjectEnteredView:Connect(function() end)

			local processedFrames = 0
			cullThrottle._processObjectVisibility = function()
				processedFrames += 1
			end

			local deadline = os.clock() + 0.5
			while processedFrames == 0 and os.clock() < deadline do
				task.wait()
			end

			expect(processedFrames).toBeGreaterThanOrEqual(1)
		end)

		it("processes visibility on demand when only the exited signal is connected", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			-- Exit signals can only fire if visibility gets computed, so a lone
			-- exited connection counts as standing demand all by itself.
			cullThrottle.ObjectExitedView:Connect(function() end)

			cullThrottle:_onPreRender(os.clock())

			expect(cullThrottle._processedVisibilityThisFrame).toBe(true)
		end)

		it("leaves visibility unprocessed in on-demand mode when nothing demands it", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			cullThrottle:_onPreRender(os.clock())

			expect(cullThrottle._processedVisibilityThisFrame).toBe(false)
		end)

		it("rebuilds the reusable buffers once the resize period elapses", function()
			local searchVoxelKeysBefore = cullThrottle._search._searchVoxelKeys
			local pendingEnteredViewBefore = cullThrottle._signals._pendingEnteredView

			-- Backdating the last resize far past the period makes this frame the
			-- one that rebuilds.
			cullThrottle._lastTableResize = os.clock() - 60

			local now = os.clock()
			cullThrottle:_onPreRender(now)

			-- The rebuild swaps in fresh tables sized to their current occupancy,
			-- so a buffer identity change in each subsystem is the observable.
			expect(cullThrottle._search._searchVoxelKeys).never.toBe(searchVoxelKeysBefore)
			expect(cullThrottle._signals._pendingEnteredView).never.toBe(pendingEnteredViewBefore)
			-- The stamp moves up so the next rebuild waits a full period again.
			expect(cullThrottle._lastTableResize).toBe(now)
		end)
	end)

	describe("Destroy", function()
		it("clears the visibility cache and the signal buffers", function()
			local part = createMockPart(Vector3.new(0, 0, -50))
			cullThrottle:AddObject(part)

			-- Stage a cached proof, a bucket verdict, an in-view object with its
			-- buffered entered signal, and a buffered exited signal, the state a
			-- live frame leaves around. All of it must be released on teardown so
			-- nothing pins the instances it referenced.
			local visibilityCache = cullThrottle._visibilityCache
			visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = visibleVoxelProof(100, 1)
			visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] = {
				state = Frustum.BUCKET_INSIDE,
				armFactor = 1,
				sideExpiry = 100,
				farExpiry = math.huge,
			}
			markInView(cullThrottle, part, os.clock())

			local signals = cullThrottle._signals
			signals._pendingExitedView[signals._pendingExitedViewSize + 1] = part
			signals._pendingExitedViewSize += 1

			expect(signals._objectsInViewSize).toBe(1)
			expect(signals._pendingEnteredViewSize).toBe(1)

			cullThrottle:Destroy()

			expect(next(visibilityCache._voxelProofs)).toBeNil()
			expect(next(visibilityCache._bucketVerdicts)).toBeNil()
			expect(signals._objectsInViewSize).toBe(0)
			expect(next(signals._objectsInView)).toBeNil()
			expect(signals._pendingEnteredViewSize).toBe(0)
			expect(next(signals._pendingEnteredView)).toBeNil()
			expect(signals._pendingExitedViewSize).toBe(0)
			expect(next(signals._pendingExitedView)).toBeNil()

			part:Destroy()
		end)
	end)
end)
