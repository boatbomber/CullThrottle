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
			expect(signal._connectionCount).toBe(0)
			expect(signal._handlerListHead).toBe(false)
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

		it("tracks the connection count as handlers connect and disconnect", function()
			expect(signal._connectionCount).toBe(0)

			local c1 = signal:Connect(function() end)
			local c2 = signal:Connect(function() end)
			expect(signal._connectionCount).toBe(2)

			c1:Disconnect()
			expect(signal._connectionCount).toBe(1)

			c2:Disconnect()
			expect(signal._connectionCount).toBe(0)
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
			expect(signal._connectionCount).toBe(0)
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
			expect(signal._connectionCount).toBe(0)
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
			expect(signal._connectionCount).toBe(0)
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
