math.randomseed(0) -- Constant seed for reproducibility

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

local Blocks = require(script.Blocks)
local MetricGraph = require(script.MetricGraph)

local VISIBLE_COLOR = Color3.fromRGB(245, 179, 226)
local INVISIBLE_COLOR = Color3.fromRGB(60, 84, 101)
local TAG = "FloatingBlock"

-- Let's make some blocks to run effects on
local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"

local blockTimeOffsets = {}

for _, block in Blocks.generateBlockClusters(200, 20_000) do
	block:AddTag(TAG)
	block.Color = INVISIBLE_COLOR
	block.Parent = BlocksFolder

	blockTimeOffsets[block] = math.random() * 2
end

BlocksFolder.Parent = workspace

-- We need to tell CullThrottle about all the objects that we want it to manage.
local FloatingBlocksUpdater = CullThrottle.new()
-- FloatingBlocksUpdater:setRenderDistance(800)

for _, block in CollectionService:GetTagged(TAG) do
	FloatingBlocksUpdater:addObject(block)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(function(block)
	FloatingBlocksUpdater:addObject(block)
end)

CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(block)
	FloatingBlocksUpdater:removeObject(block)
end)

-- Change colors of blocks to indicate visibility
FloatingBlocksUpdater.ObjectEnteredView:Connect(function(block)
	block.Color = VISIBLE_COLOR
end)

FloatingBlocksUpdater.ObjectExitedView:Connect(function(block)
	block.Color = INVISIBLE_COLOR
end)

local updateTime = 0
local objectDeltas = {}

local blocks, cframes = {}, {}
RunService.RenderStepped:Connect(function()
	table.clear(blocks)
	table.clear(cframes)

	-- These are for the debug graphs --
	table.clear(objectDeltas)
	local startUpdate = os.clock()
	------------------------------------

	for block, dt in FloatingBlocksUpdater:iterObjectsToUpdate() do
		table.insert(objectDeltas, dt)

		if dt > 0.8 then
			-- This object hasn't been visible in a while so let's
			-- avoid a jump in the spin animation and just start spinning
			-- from where we are
			dt = 1 / 10
		end

		table.insert(blocks, block)
		table.insert(cframes, block.CFrame * CFrame.Angles(0, math.rad(90) * dt, 0))
	end

	updateTime = (os.clock() - startUpdate) * 1000

	workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)

----------------------------------------------------------------------------------
-- The rest of this is debug/dev stuff

local DEBUG = false

local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local ScreenGui = Instance.new("ScreenGui")

local TopLeftGraphs = Instance.new("Frame")
TopLeftGraphs.AutomaticSize = Enum.AutomaticSize.Y
TopLeftGraphs.Size = UDim2.fromScale(0.2, 0)
TopLeftGraphs.Position = UDim2.fromOffset(5, 5)
TopLeftGraphs.BackgroundTransparency = 0.2
TopLeftGraphs.BackgroundColor3 = Color3.fromRGB(113, 152, 181)
TopLeftGraphs.Parent = ScreenGui

local TopLeftListLayout = Instance.new("UIListLayout")
TopLeftListLayout.SortOrder = Enum.SortOrder.LayoutOrder
TopLeftListLayout.FillDirection = Enum.FillDirection.Vertical
TopLeftListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
TopLeftListLayout.Padding = UDim.new(0, 10)
TopLeftListLayout.Parent = TopLeftGraphs

local BottomLeftGraphs = Instance.new("Frame")
BottomLeftGraphs.AutomaticSize = Enum.AutomaticSize.Y
BottomLeftGraphs.Size = UDim2.fromScale(0.2, 0)
BottomLeftGraphs.Position = UDim2.new(0, 5, 1, -5)
BottomLeftGraphs.AnchorPoint = Vector2.new(0, 1)
BottomLeftGraphs.BackgroundTransparency = 0.2
BottomLeftGraphs.BackgroundColor3 = Color3.fromRGB(113, 152, 181)
BottomLeftGraphs.Parent = ScreenGui

local BottomLeftListLayout = Instance.new("UIListLayout")
BottomLeftListLayout.SortOrder = Enum.SortOrder.LayoutOrder
BottomLeftListLayout.FillDirection = Enum.FillDirection.Vertical
BottomLeftListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
BottomLeftListLayout.Padding = UDim.new(0, 10)
BottomLeftListLayout.Parent = BottomLeftGraphs

local BottomRightGraphs = Instance.new("Frame")
BottomRightGraphs.AutomaticSize = Enum.AutomaticSize.Y
BottomRightGraphs.Size = UDim2.fromScale(0.2, 0)
BottomRightGraphs.Position = UDim2.new(1, -5, 1, -5)
BottomRightGraphs.AnchorPoint = Vector2.new(1, 1)
BottomRightGraphs.BackgroundTransparency = 0.2
BottomRightGraphs.BackgroundColor3 = Color3.fromRGB(113, 152, 181)
BottomRightGraphs.Parent = ScreenGui

local BottomRightListLayout = Instance.new("UIListLayout")
BottomRightListLayout.SortOrder = Enum.SortOrder.LayoutOrder
BottomRightListLayout.FillDirection = Enum.FillDirection.Vertical
BottomRightListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
BottomRightListLayout.Padding = UDim.new(0, 10)
BottomRightListLayout.Parent = BottomRightGraphs

local computeTimeGraph = MetricGraph.new(
	"Visibility Compute Time",
	table.create(50, 0),
	0,
	FloatingBlocksUpdater.Config.searchTimeBudget * 1050,
	"%.3fms"
)
local updateTimeGraph = MetricGraph.new(
	"Object Update Time",
	table.create(50, 0),
	0,
	FloatingBlocksUpdater.Config.updateTimeBudget * 1050,
	"%.3fms"
)
local perfFactorGraph = MetricGraph.new("Performance Factor", table.create(50, 0.5), 0.5, 2, "%.3f")

computeTimeGraph.Frame.Parent = TopLeftGraphs
updateTimeGraph.Frame.Parent = TopLeftGraphs
perfFactorGraph.Frame.Parent = TopLeftGraphs

local objectsVisibleGraph = MetricGraph.new("Objects Visible", table.create(50, 0), 0, 1300)
local objectsUpdatedGraph = MetricGraph.new("Objects Updated", table.create(50, 0), 0, 1300)

objectsVisibleGraph.Frame.Parent = BottomLeftGraphs
objectsUpdatedGraph.Frame.Parent = BottomLeftGraphs

local gameRefreshRateGraph = MetricGraph.new("Game Refresh Rate", table.create(50, 0), 0, 240, "%dHz")
local p05ObjectRefreshRateGraph = MetricGraph.new(
	"p05 Object Refresh Rate",
	table.create(50, 0),
	1 / FloatingBlocksUpdater.Config.worstRefreshRate,
	1 / FloatingBlocksUpdater.Config.bestRefreshRate,
	"%dHz"
)
local p50ObjectRefreshRateGraph = MetricGraph.new(
	"p50 Object Refresh Rate",
	table.create(50, 0),
	1 / FloatingBlocksUpdater.Config.worstRefreshRate,
	1 / FloatingBlocksUpdater.Config.bestRefreshRate,
	"%dHz"
)
local p95ObjectRefreshRateGraph = MetricGraph.new(
	"p95 Object Refresh Rate",
	table.create(50, 0),
	1 / FloatingBlocksUpdater.Config.worstRefreshRate,
	1 / FloatingBlocksUpdater.Config.bestRefreshRate,
	"%dHz"
)
gameRefreshRateGraph.Frame.Parent = BottomRightGraphs
p05ObjectRefreshRateGraph.Frame.Parent = BottomRightGraphs
p50ObjectRefreshRateGraph.Frame.Parent = BottomRightGraphs
p95ObjectRefreshRateGraph.Frame.Parent = BottomRightGraphs

ScreenGui.Parent = PlayerGui

local lastMeasurement = os.clock()
RunService.PreRender:Connect(function(gameDelta)
	local now = os.clock()
	if now - lastMeasurement < 1 / 15 then
		return
	end
	lastMeasurement = now

	table.sort(objectDeltas, function(a, b)
		return a > b
	end)
	local visibleObjectCount = #FloatingBlocksUpdater:getObjectsInView()
	local updatedObjectCount = #objectDeltas

	computeTimeGraph:measure(FloatingBlocksUpdater:_getAverageCallTime() * 1000)
	updateTimeGraph:measure(updateTime)
	perfFactorGraph:measure(FloatingBlocksUpdater.Config.performanceFalloffFactor)
	objectsVisibleGraph:measure(visibleObjectCount)
	objectsUpdatedGraph.Max = visibleObjectCount
	objectsUpdatedGraph:measure(updatedObjectCount)
	p05ObjectRefreshRateGraph:measure(1 / (objectDeltas[math.floor(#objectDeltas * 0.05)] or math.huge))
	p50ObjectRefreshRateGraph:measure(1 / (objectDeltas[#objectDeltas // 2] or math.huge))
	p95ObjectRefreshRateGraph:measure(1 / (objectDeltas[math.floor(#objectDeltas * 0.95)] or math.huge))
	gameRefreshRateGraph:measure(1 / gameDelta)
end)

-- Use a fake camera to get a third person view
if DEBUG then
	local testCam = Instance.new("Part")
	testCam.Name = "_CullThrottleTestCam"
	testCam.Size = Vector3.new(16, 9, 3)
	testCam.Color = Color3.fromRGB(255, 225, 0)
	testCam.CanCollide = false
	testCam.Locked = true
	testCam.CastShadow = false
	testCam.CanTouch = false
	testCam.CanQuery = false
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
