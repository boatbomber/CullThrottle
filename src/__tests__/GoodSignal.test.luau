local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local CullThrottle = Packages:WaitForChild("CullThrottle")
local GoodSignal = require(CullThrottle:WaitForChild("Utilities"):WaitForChild("GoodSignal"))

describe("GoodSignal", function()
	local signal

	beforeEach(function()
		signal = GoodSignal.new()
	end)

	describe("new", function()
		it("starts with no connections", function()
			expect(signal:HasConnections()).toBe(false)
			-- The handler list sentinel only needs to read as empty, whatever
			-- falsy value the implementation picks.
			expect(signal._handlerListHead).toBeFalsy()
		end)
	end)

	describe("Connect and Fire", function()
		it("runs connected handlers with the fired arguments", function()
			-- Non-yielding handlers run synchronously during Fire.
			local received
			signal:Connect(function(a, b)
				received = { a, b }
			end)

			signal:Fire(1, 2)

			expect(received[1]).toBe(1)
			expect(received[2]).toBe(2)
		end)

		it("runs every connected handler", function()
			local count = 0
			signal:Connect(function()
				count += 1
			end)
			signal:Connect(function()
				count += 1
			end)

			signal:Fire()

			expect(count).toBe(2)
		end)

		it("runs handlers in most-recently-connected-first order", function()
			-- The mutation-during-fire tests below stage themselves around this
			-- order, so it gets pinned directly instead of only by implication.
			local order = {}
			signal:Connect(function()
				table.insert(order, "first")
			end)
			signal:Connect(function()
				table.insert(order, "second")
			end)
			signal:Connect(function()
				table.insert(order, "third")
			end)

			signal:Fire()

			expect(order).toEqual({ "third", "second", "first" })
		end)

		it("reports connections exactly while any handler remains connected", function()
			expect(signal:HasConnections()).toBe(false)

			local c1 = signal:Connect(function() end)
			local c2 = signal:Connect(function() end)
			expect(signal:HasConnections()).toBe(true)

			-- One handler is still live here, so an undercounting bug (like a
			-- double decrement) would wrongly flip this to false.
			c1:Disconnect()
			expect(signal:HasConnections()).toBe(true)

			c2:Disconnect()
			expect(signal:HasConnections()).toBe(false)
		end)

		it("still reports a connection when another handler is disconnected twice", function()
			local c1 = signal:Connect(function() end)
			signal:Connect(function() end)

			-- The second disconnect must be a no-op. If it took effect again, the
			-- signal would report no connections while a live handler remains, and
			-- anything gating work on that report would wrongly see no demand.
			c1:Disconnect()
			c1:Disconnect()

			expect(signal:HasConnections()).toBe(true)
		end)

		it("does not run a handler after it is disconnected", function()
			local count = 0
			local connection = signal:Connect(function()
				count += 1
			end)

			signal:Fire()
			connection:Disconnect()
			signal:Fire()

			expect(count).toBe(1)
		end)

		it("is a no-op to fire with no connections", function()
			expect(function()
				signal:Fire(1, 2, 3)
			end).never.toThrow()
		end)
	end)

	describe("DisconnectAll", function()
		it("removes every handler", function()
			local count = 0
			signal:Connect(function()
				count += 1
			end)
			signal:Connect(function()
				count += 1
			end)

			signal:DisconnectAll()
			signal:Fire()

			expect(count).toBe(0)
			expect(signal:HasConnections()).toBe(false)
		end)

		it("makes a later Disconnect on a swept connection a no-op", function()
			local connection = signal:Connect(function() end)

			signal:DisconnectAll()

			-- Disconnecting a connection the sweep already covered must stay a
			-- no-op, leaving the signal reporting no connections.
			connection:Disconnect()

			expect(connection.Connected).toBe(false)
			expect(signal:HasConnections()).toBe(false)
		end)
	end)

	describe("Once", function()
		it("runs the handler only once", function()
			local count = 0
			signal:Once(function()
				count += 1
			end)

			signal:Fire()
			signal:Fire()

			expect(count).toBe(1)
			-- The one-shot connection cleans itself up, which the facade's
			-- on-demand gate relies on to see demand disappear.
			expect(signal:HasConnections()).toBe(false)
		end)

		it("passes the fired arguments to the handler", function()
			local received
			signal:Once(function(value)
				received = value
			end)

			signal:Fire("hello")

			expect(received).toBe("hello")
		end)
	end)

	describe("Wait", function()
		it("resumes the waiting coroutine with the fired arguments", function()
			local results = {}
			task.spawn(function()
				local a, b = signal:Wait()
				results.a = a
				results.b = b
			end)

			signal:Fire(7, 8)
			task.wait()

			expect(results.a).toBe(7)
			expect(results.b).toBe(8)
			-- Wait connects a temporary handler that disconnects itself on fire.
			expect(signal:HasConnections()).toBe(false)
		end)
	end)

	describe("mutation during fire", function()
		it("lets a handler disconnect itself mid-fire without error", function()
			local count = 0
			local connection
			connection = signal:Connect(function()
				count += 1
				connection:Disconnect()
			end)

			expect(function()
				signal:Fire()
			end).never.toThrow()

			-- After the self-disconnect, a second fire must not reach it again.
			signal:Fire()
			expect(count).toBe(1)
		end)

		it("keeps firing the remaining handlers after one disconnects itself mid-fire", function()
			-- Handlers are prepended, so the handler connected last fires first
			-- and the one connected first still waits its turn behind it. The
			-- first-firing handler disconnects itself, and the fire must still
			-- walk forward off the unhooked node to reach the remaining handler.
			-- Once and Wait self-disconnect on every fire, so any mixed set of
			-- connections hits this path constantly.
			local aRan = false
			signal:Connect(function()
				aRan = true
			end)
			local connectionB
			connectionB = signal:Connect(function()
				connectionB:Disconnect()
			end)

			signal:Fire()

			expect(aRan).toBe(true)
		end)

		it("does not invoke a handler connected during a fire", function()
			local lateRan = false
			signal:Connect(function()
				signal:Connect(function()
					lateRan = true
				end)
			end)

			signal:Fire()

			expect(lateRan).toBe(false)
		end)

		it("lets a handler disconnect a later handler before it runs", function()
			-- Handlers are prepended, so the handler connected last fires first.
			-- Connecting 'a' first puts it later in the iteration, so the handler
			-- that runs first can unhook 'a' before the fire walks to it.
			local aRan = false
			local connectionA = signal:Connect(function()
				aRan = true
			end)
			signal:Connect(function()
				connectionA:Disconnect()
			end)

			signal:Fire()

			expect(aRan).toBe(false)
		end)

		it("handles a handler firing the same signal again", function()
			-- The refiring handler is connected last so it runs first, nesting a
			-- whole second dispatch before the witness gets its turn in the
			-- outer one. The witness must hear both fires.
			local witnessed = 0
			signal:Connect(function()
				witnessed += 1
			end)
			local refired = false
			signal:Connect(function()
				if not refired then
					refired = true
					signal:Fire()
				end
			end)

			expect(function()
				signal:Fire()
			end).never.toThrow()

			expect(witnessed).toBe(2)
		end)

		it("lets a handler disconnect everything mid-fire and leaves later fires silent", function()
			local laterRan = 0
			signal:Connect(function()
				laterRan += 1
			end)
			signal:Connect(function()
				signal:DisconnectAll()
			end)

			expect(function()
				signal:Fire()
			end).never.toThrow()

			-- The sweep marked every node disconnected, so the fire's walk skips
			-- the handler it had not reached yet and later fires reach nobody.
			expect(laterRan).toBe(0)
			expect(signal:HasConnections()).toBe(false)

			signal:Fire()
			expect(laterRan).toBe(0)
		end)
	end)

	describe("handlers that never return", function()
		-- A handler that throws takes the cached runner coroutine down exactly
		-- like one that parks forever, since both leave the runner acquired and
		-- never release it, and task.spawn contains either outcome to that
		-- thread. These tests stage the loss with a bare yield because a real
		-- throw would land an error report in the test output, which the test
		-- runner treats as a failed run.
		it("keeps firing the remaining handlers when one takes the runner down mid-fire", function()
			local survivorRan = false
			signal:Connect(function()
				survivorRan = true
			end)
			signal:Connect(function()
				coroutine.yield()
			end)

			expect(function()
				signal:Fire()
			end).never.toThrow()

			-- Handlers fire most-recently-connected first, so the runner was
			-- already lost by the time the survivor's turn came. It must have
			-- been dispatched on a fresh runner within the same fire.
			expect(survivorRan).toBe(true)
		end)

		it("fires normally again after a handler took the runner down", function()
			local stalling = signal:Connect(function()
				coroutine.yield()
			end)
			signal:Fire()
			stalling:Disconnect()

			-- The parked handler never released the cached runner coroutine, so
			-- this fire has to stand up a fresh runner rather than reuse it.
			local ran = false
			signal:Connect(function()
				ran = true
			end)
			signal:Fire()

			expect(ran).toBe(true)
		end)
	end)

	describe("yield-safe handlers", function()
		it("does not block the fire when a handler yields, and still resumes it", function()
			local resumed = false
			signal:Connect(function()
				task.wait(0.05)
				resumed = true
			end)

			expect(function()
				signal:Fire()
			end).never.toThrow()

			-- The handler yielded, so Fire returned before it finished.
			expect(resumed).toBe(false)

			task.wait(0.1)
			expect(resumed).toBe(true)
		end)

		it("keeps firing on a fresh runner thread after a handler yields", function()
			local firstResumed = false
			signal:Connect(function()
				task.wait(0.05)
				firstResumed = true
			end)
			signal:Fire()

			-- A second handler fired while the first is still suspended must run.
			local secondRan = false
			signal:Connect(function()
				secondRan = true
			end)
			signal:Fire()

			expect(secondRan).toBe(true)

			task.wait(0.1)
			expect(firstResumed).toBe(true)
		end)
	end)
end)
