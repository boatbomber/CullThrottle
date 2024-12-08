math.randomseed(0) -- Constant seed for reproducibility

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

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

local blockMetadata = {}

for _, block in Blocks.generateBlockClusters(60, 200) do
	block:AddTag(TAG)
	block.Color = Color3.fromHSV(math.random(), 0.6, 1) --INVISIBLE_COLOR
	block.Parent = BlocksFolder

	blockMetadata[block] = {
		Seed = math.random() * 7,
		Origin = block.CFrame,
	}
end

BlocksFolder.Parent = workspace

-- We need to tell CullThrottle about all the objects that we want it to manage.
local FloatingBlocksUpdater = CullThrottle.new()
FloatingBlocksUpdater:CaptureTag(TAG)

-- Change colors of blocks to indicate visibility
-- FloatingBlocksUpdater.ObjectEnteredView:Connect(function(block)
-- 	block.Color = VISIBLE_COLOR
-- end)

-- FloatingBlocksUpdater.ObjectExitedView:Connect(function(block)
-- 	block.Color = INVISIBLE_COLOR
-- end)

local updateDuration = 0
local objectDeltas = {}

local blocks, cframes = {}, {}
RunService.PreAnimation:Connect(function()
	table.clear(blocks)
	table.clear(cframes)

	table.clear(objectDeltas) -- For the debug graphs

	local now = os.clock()
	for block, dt in FloatingBlocksUpdater:IterateObjectsToUpdate() do
		table.insert(objectDeltas, dt)
		dt = math.min(dt, 1 / 15) * 3

		local metadata = blockMetadata[block]

		local angularForce = CFrame.Angles(
			math.noise(metadata.Seed, 0.327, now) * dt,
			math.noise(0.12, metadata.Seed, now) * dt,
			math.noise(now, metadata.Seed, now) * dt
		)

		table.insert(blocks, block)
		table.insert(cframes, block.CFrame * angularForce)
	end

	updateDuration = os.clock() - now

	workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)

----------------------------------------------------------------------------------
-- The rest of this is debug/dev stuff

local DEBUG = false

local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local ScreenGui = Instance.new("ScreenGui")

local TopLeftGraphs = Instance.new("Frame")
TopLeftGraphs.Size = UDim2.fromScale(0.2, 0.3)
TopLeftGraphs.Position = UDim2.fromOffset(5, 5)
TopLeftGraphs.BackgroundTransparency = 1
TopLeftGraphs.Parent = ScreenGui

local TopLeftListLayout = Instance.new("UIListLayout")
TopLeftListLayout.SortOrder = Enum.SortOrder.LayoutOrder
TopLeftListLayout.FillDirection = Enum.FillDirection.Vertical
TopLeftListLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
TopLeftListLayout.Padding = UDim.new(0, 5)
TopLeftListLayout.Parent = TopLeftGraphs

local BottomLeftGraphs = Instance.new("Frame")
BottomLeftGraphs.Size = UDim2.fromScale(0.2, 0.2)
BottomLeftGraphs.Position = UDim2.new(0, 5, 1, -5)
BottomLeftGraphs.AnchorPoint = Vector2.new(0, 1)
BottomLeftGraphs.BackgroundTransparency = 1
BottomLeftGraphs.Parent = ScreenGui

local BottomLeftListLayout = TopLeftListLayout:Clone()
BottomLeftListLayout.Parent = BottomLeftGraphs

local TopRightGraphs = Instance.new("Frame")
TopRightGraphs.Size = UDim2.fromScale(0.2, 0.3)
TopRightGraphs.Position = UDim2.new(1, -5, 0, 5)
TopRightGraphs.AnchorPoint = Vector2.new(1, 0)
TopRightGraphs.BackgroundTransparency = 1
TopRightGraphs.Parent = ScreenGui

local TopRightListLayout = TopLeftListLayout:Clone()
TopRightListLayout.Parent = TopRightGraphs

local BottomRightGraphs = Instance.new("Frame")
BottomRightGraphs.Size = UDim2.fromScale(0.2, 0.4)
BottomRightGraphs.Position = UDim2.new(1, -5, 1, -5)
BottomRightGraphs.AnchorPoint = Vector2.new(1, 1)
BottomRightGraphs.BackgroundTransparency = 1
BottomRightGraphs.Parent = ScreenGui

local BottomRightListLayout = TopLeftListLayout:Clone()
BottomRightListLayout.Parent = BottomRightGraphs

local searchDurationGraph = MetricGraph.new(
	"Search Duration",
	table.create(50, 0),
	0,
	FloatingBlocksUpdater._config.searchTimeBudget * 1e6 * 1.25,
	"%dμs"
)
local ingestDurationGraph = MetricGraph.new(
	"Ingest Duration",
	table.create(50, 0),
	0,
	FloatingBlocksUpdater._config.ingestTimeBudget * 1e6 * 1.25,
	"%dμs"
)
local updateDurationGraph = MetricGraph.new(
	"Update Duration",
	table.create(50, 0),
	0,
	FloatingBlocksUpdater._config.updateTimeBudget * 1e6 * 1.25,
	"%dμs"
)

searchDurationGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
ingestDurationGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
updateDurationGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
searchDurationGraph.Frame.Parent = TopLeftGraphs
ingestDurationGraph.Frame.Parent = TopLeftGraphs
updateDurationGraph.Frame.Parent = TopLeftGraphs

local skippedSearchGraph = MetricGraph.new("Skipped Search", table.create(50, 0), 0, 90, "%d")
local skippedIngestGraph = MetricGraph.new("Skipped Ingest", table.create(50, 0), 0, 50, "%d")
local renderDistanceGraph = MetricGraph.new(
	"Render Distance",
	table.create(50, 0),
	FloatingBlocksUpdater._config._minRenderDistance,
	FloatingBlocksUpdater._config._maxRenderDistance,
	"%d"
)

skippedSearchGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
skippedIngestGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
renderDistanceGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
skippedSearchGraph.Frame.Parent = TopRightGraphs
skippedIngestGraph.Frame.Parent = TopRightGraphs
renderDistanceGraph.Frame.Parent = TopRightGraphs

local objectsVisibleGraph = MetricGraph.new("Objects Visible", table.create(50, 0), 0, 900)
local objectsUpdatedGraph = MetricGraph.new("Objects Updated", table.create(50, 0), 0, 450)

objectsVisibleGraph.Frame.Size = UDim2.fromScale(1, 1 / 2)
objectsUpdatedGraph.Frame.Size = UDim2.fromScale(1, 1 / 2)
objectsVisibleGraph.Frame.Parent = BottomLeftGraphs
objectsUpdatedGraph.Frame.Parent = BottomLeftGraphs

local gameRefreshRateGraph = MetricGraph.new("Game Refresh Rate", table.create(50, 0), 0, 144, "%dHz")
local p05ObjectRefreshRateGraph = MetricGraph.new(
	"p05 Obj Refresh",
	table.create(50, 0),
	1 / FloatingBlocksUpdater._config.worstRefreshRate,
	1 / FloatingBlocksUpdater._config.bestRefreshRate,
	"%dHz"
)
local avgObjectRefreshRateGraph = MetricGraph.new(
	"Avg Obj Refresh",
	table.create(50, 0),
	1 / FloatingBlocksUpdater._config.worstRefreshRate,
	1 / FloatingBlocksUpdater._config.bestRefreshRate,
	"%dHz"
)
local p95ObjectRefreshRateGraph = MetricGraph.new(
	"p95 Obj Refresh",
	table.create(50, 0),
	1 / FloatingBlocksUpdater._config.worstRefreshRate,
	1 / FloatingBlocksUpdater._config.bestRefreshRate,
	"%dHz"
)

gameRefreshRateGraph.Frame.Size = UDim2.fromScale(1, 1 / 4)
p05ObjectRefreshRateGraph.Frame.Size = UDim2.fromScale(1, 1 / 4)
avgObjectRefreshRateGraph.Frame.Size = UDim2.fromScale(1, 1 / 4)
p95ObjectRefreshRateGraph.Frame.Size = UDim2.fromScale(1, 1 / 4)

gameRefreshRateGraph.Frame.Parent = BottomRightGraphs
p05ObjectRefreshRateGraph.Frame.Parent = BottomRightGraphs
avgObjectRefreshRateGraph.Frame.Parent = BottomRightGraphs
p95ObjectRefreshRateGraph.Frame.Parent = BottomRightGraphs

ScreenGui.Parent = PlayerGui

UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.G then
		ScreenGui.Enabled = not ScreenGui.Enabled
	end
end)

local lastMeasurement = os.clock()
RunService.PostSimulation:Connect(function(gameDelta)
	if not ScreenGui.Enabled then
		return
	end

	local now = os.clock()
	if now - lastMeasurement < 1 / 70 then
		return
	end
	lastMeasurement = now

	table.sort(objectDeltas, function(a, b)
		return a > b
	end)
	local visibleObjectCount = #FloatingBlocksUpdater:GetVisibleObjects()
	local updatedObjectCount = #objectDeltas

	searchDurationGraph:measure(FloatingBlocksUpdater._perfMetrics._searchDuration * 1e6)
	ingestDurationGraph:measure(FloatingBlocksUpdater._perfMetrics._ingestDuration * 1e6)
	updateDurationGraph:measure(updateDuration * 1e6)
	skippedSearchGraph:measure(FloatingBlocksUpdater._perfMetrics._skippedSearch[1])
	skippedIngestGraph:measure(FloatingBlocksUpdater._perfMetrics._skippedIngest[1])
	renderDistanceGraph:measure(FloatingBlocksUpdater._config._renderDistance)
	objectsVisibleGraph:measure(visibleObjectCount)
	objectsUpdatedGraph.Max = math.max(table.unpack(objectsVisibleGraph._data))
	objectsUpdatedGraph:measure(updatedObjectCount)
	p05ObjectRefreshRateGraph:measure(1 / (objectDeltas[math.floor(#objectDeltas * 0.05)] or math.huge))
	avgObjectRefreshRateGraph:measure(1 / FloatingBlocksUpdater._perfMetrics._averageObjectDeltaTime)
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
