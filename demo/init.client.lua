math.randomseed(0) -- Constant seed for reproducibility

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

local Utility = require(script.Utility)

local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local ScreenGui = Instance.new("ScreenGui")

local DebugInfo = Instance.new("TextLabel")
DebugInfo.Size = UDim2.fromScale(0.2, 0.14)
DebugInfo.Position = UDim2.fromScale(0.03, 0.03)
DebugInfo.TextXAlignment = Enum.TextXAlignment.Left
DebugInfo.TextYAlignment = Enum.TextYAlignment.Bottom
DebugInfo.TextScaled = true
DebugInfo.BackgroundTransparency = 0.4
DebugInfo.BackgroundColor3 = Color3.new(0, 0, 0)
DebugInfo.TextColor3 = Color3.new(1, 1, 1)
DebugInfo.TextStrokeColor3 = Color3.new(0, 0, 0)
DebugInfo.TextStrokeTransparency = 0.5
DebugInfo.FontFace = Font.fromEnum(Enum.Font.RobotoMono)
DebugInfo.Parent = ScreenGui
ScreenGui.Parent = PlayerGui

-- Let's make some blocks to run effects on
local blockTimeOffsets = {}

local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"
for _ = 1, 100 do
	local groupOrigin = Vector3.new(math.random(-800, 800), math.random(-200, 200), math.random(-800, 800))
	for _ = 1, 150 do
		local part = Instance.new("Part")
		part.Size = Vector3.new(1, 1, 1) * math.random(1, 15)
		part.Color = Color3.new() -- Color3.fromHSV(math.random(), 0.5, 1)
		part.CFrame = CFrame.new(
			groupOrigin + Vector3.new(math.random(-120, 120), math.random(-80, 80), math.random(-120, 120))
		) * CFrame.Angles(math.rad(math.random(360)), math.rad(math.random(360)), math.rad(math.random(360)))
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.CanTouch = false
		part.CanQuery = false
		part.Locked = true
		part:AddTag("FloatingBlock")
		part.Parent = BlocksFolder

		blockTimeOffsets[part] = math.random() * 2
	end
end

BlocksFolder.Parent = workspace

local FloatingBlocksUpdater = CullThrottle.new()
FloatingBlocksUpdater.DEBUG_MODE = false

FloatingBlocksUpdater:setRefreshRates(1 / 90, 1 / 15)

if false then
	local testCam = Instance.new("Part")
	testCam.Name = "_CullThrottleTestCam"
	testCam.Size = Vector3.new(16, 9, 2)
	testCam.Anchored = true
	testCam.Parent = workspace

	local targetCF = CFrame.new()

	task.defer(function()
		while true do
			targetCF = CFrame.new(math.random(-800, 800), math.random(-200, 200), math.random(-800, 800))
				* CFrame.Angles(math.random(-0.1, 0.1), math.random(-3.14, 3.14), math.random(-3.14, 3.14))

			task.wait(5)
		end
	end)

	task.spawn(function()
		while task.wait() do
			local distanceToTarget = (testCam.CFrame.Position - targetCF.Position).Magnitude
			testCam.CFrame = testCam.CFrame:Lerp(targetCF, math.min(1 / distanceToTarget, 1))
		end
	end)
end

-- We need to tell CullThrottle about all the objects that we want it to manage.
for _, block in CollectionService:GetTagged("FloatingBlock") do
	FloatingBlocksUpdater:addObject(block)
end

CollectionService:GetInstanceAddedSignal("FloatingBlock"):Connect(function(block)
	FloatingBlocksUpdater:addObject(block)
end)

CollectionService:GetInstanceRemovedSignal("FloatingBlock"):Connect(function(block)
	FloatingBlocksUpdater:removeObject(block)
end)

-- Each frame, we'll ask CullThrottle for all the objects that should be updated this frame,
-- and then rotate them accordingly with BulkMoveTo.
local ROT_SPEED = math.rad(90)
local MOVE_AMOUNT = 10

local last_debug_text_update = os.clock()
RunService.RenderStepped:Connect(function(frameDeltaTime)
	local blocks, cframes = {}, {}
	local now = os.clock() / 2

	local deltas = {}

	for block, objectDeltaTime in FloatingBlocksUpdater:iterObjectsToUpdate() do
		if objectDeltaTime > 1 / 5 then
			-- This object hasn't been updated in a while, so if we were to animate
			-- it based on the objectDT, it would jump to where it "should" be now.
			-- For our purposes, we'd rather it just pick up from where it is and avoid popping
			objectDeltaTime = 1 / 60
		else
			table.insert(deltas, objectDeltaTime)

			task.defer(
				Utility.applyHeatmapColor,
				block,
				1 - (objectDeltaTime - FloatingBlocksUpdater._bestRefreshRate) / FloatingBlocksUpdater._refreshRateRange
			)
		end

		local movement = math.sin(now + blockTimeOffsets[block]) * MOVE_AMOUNT

		table.insert(blocks, block)
		table.insert(
			cframes,
			block.CFrame
				* CFrame.new(0, movement * objectDeltaTime, 0)
				* CFrame.Angles(0, ROT_SPEED * objectDeltaTime, 0)
		)
	end

	workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	if os.clock() - last_debug_text_update > 1 / 5 then
		last_debug_text_update = os.clock()
		local debugInfoBuffer = {}
		local updated = #blocks
		local skipped = FloatingBlocksUpdater._visibleObjectsQueue:len()
		local visible = updated + skipped
		table.sort(deltas)

		table.insert(debugInfoBuffer, "objects visible: " .. visible)
		table.insert(
			debugInfoBuffer,
			string.format("objects updated: %d (%d%%)", updated, 100 * (updated / (if visible > 0 then visible else 1)))
		)
		table.insert(
			debugInfoBuffer,
			string.format("time spent: %.3fms", FloatingBlocksUpdater:_getAverageCallTime() * 1000)
		)
		table.insert(debugInfoBuffer, string.format("game fps: %d", 1 / frameDeltaTime))
		table.insert(
			debugInfoBuffer,
			string.format(
				"object fps range: %d -> %d",
				math.round(1 / (deltas[math.floor(#deltas * 0.97)] or 1)),
				math.round(1 / (deltas[math.ceil(#deltas * 0.03)] or 1))
			)
		)

		DebugInfo.Text = table.concat(debugInfoBuffer, "\n")
	end
end)
