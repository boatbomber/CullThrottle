local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local ScreenGui = Instance.new("ScreenGui")

local DebugInfo = Instance.new("TextLabel")
DebugInfo.Size = UDim2.fromScale(0.2, 0.1)
DebugInfo.Position = UDim2.fromScale(0, 1)
DebugInfo.AnchorPoint = Vector2.yAxis
DebugInfo.TextXAlignment = Enum.TextXAlignment.Left
DebugInfo.TextYAlignment = Enum.TextYAlignment.Top
DebugInfo.TextScaled = true
DebugInfo.TextColor3 = Color3.new(1, 1, 1)
DebugInfo.FontFace = Font.fromEnum(Enum.Font.RobotoMono)
DebugInfo.BackgroundTransparency = 0.9
DebugInfo.BackgroundColor3 = Color3.new(0, 0, 0)
DebugInfo.Parent = ScreenGui
ScreenGui.Parent = PlayerGui

-- Let's make some blocks to run effects on
local blockTimeOffsets = {}

local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"
for _ = 1, 100 do
	local groupOrigin = Vector3.new(math.random(-800, 800), math.random(60, 400), math.random(-800, 800))
	for _ = 1, 100 do
		local part = Instance.new("Part")
		part.Size = Vector3.new(1, 1, 1) * math.random(1, 15)
		part.Color = Color3.new() -- Color3.fromHSV(math.random(), 0.5, 1)
		part.CFrame = CFrame.new(
			groupOrigin + Vector3.new(math.random(-100, 100), math.random(-50, 50), math.random(-100, 100))
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
RunService.RenderStepped:Connect(function(frameDeltaTime)
	local blocks, cframes = {}, {}
	local now = os.clock() / 2
	for block, objectDeltaTime in FloatingBlocksUpdater:getObjectsToUpdate() do
		if objectDeltaTime > 0.4 then
			-- This object hasn't been updated in a while, so if we were to animate
			-- it based on the objectDT, it would jump to where it "should" be now.
			-- For our purposes, we'd rather it just pick up from where it is and avoid popping
			objectDeltaTime = frameDeltaTime
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

	local debugInfoBuffer = {}

	table.insert(debugInfoBuffer, "blocks: " .. #blocks)
	table.insert(debugInfoBuffer, string.format("time: %.3fms", FloatingBlocksUpdater:_getAverageCallTime() * 1000))
	table.insert(
		debugInfoBuffer,
		string.format("falloff factor: %.2f", FloatingBlocksUpdater._performanceFalloffFactor)
	)

	DebugInfo.Text = table.concat(debugInfoBuffer, "\n")
end)
