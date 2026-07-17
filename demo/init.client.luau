math.randomseed(1) -- A constant seed keeps runs reproducible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))
local CameraCache = require(Packages:WaitForChild("CullThrottle").Utilities.CameraCache)

local Blocks = require(script.Blocks)
local MetricGraph = require(script.MetricGraph)
local Utility = require(script.Utility)

-- Blocks rest at this color while out of view. The exited-view handler resets
-- them to it, and the heatmap tint takes over while a block is updating.
local INVISIBLE_COLOR = Color3.fromRGB(77, 127, 182)
-- Every block carries this CollectionService tag, and CaptureTag tracks the lot.
local TAG = "FloatingBlock"

-- Let's make some blocks to run effects on.
local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"

local blockMetadata = {}

for _, block in Blocks.generateBlockClusters(200, 150) do
	block:AddTag(TAG)
	block.Color = INVISIBLE_COLOR
	block.Parent = BlocksFolder

	blockMetadata[block] = {
		Seed = math.random() * 7,
		Origin = block.CFrame,
	}
end

BlocksFolder.Parent = workspace

-- Let's add occluders that can hide some blocks.
local OccludersFolder = Instance.new("Folder")

for _ = 1, 20 do
	local occluder = Instance.new("Part")
	occluder:AddTag("CullThrottleOccluder")
	occluder.Anchored = true
	occluder.CanCollide = false
	occluder.Color = Color3.new(0, 0, 0)
	occluder.Transparency = 0.3
	occluder.Size = Vector3.new(math.random(5, 50), math.random(100, 200), math.random(300, 500))
	occluder.CFrame = CFrame.lookAlong(
		Vector3.new(math.random(-1000, 1000), math.random(-500, 500), math.random(-1000, 1000)),
		Vector3.new(math.random(-100, 100) / 100, math.random(-100, 100) / 100, math.random(-100, 100) / 100)
	)
	occluder.Parent = OccludersFolder
end

task.delay(1, function()
	-- Create a consistent occluder right in front of the camera.
	-- Toggle it on and off to easily measure how much occlusion saves.
	local occluder = Instance.new("Part")
	occluder:AddTag("CullThrottleOccluder")
	occluder.Anchored = true
	occluder.CanCollide = false
	occluder.Color = Color3.new(0, 1, 0)
	occluder.Transparency = 0.6
	occluder.Size = Vector3.new(400, 400, 10)
	occluder.CFrame =
		CFrame.lookAlong(CameraCache.Position + (CameraCache.CFrame.LookVector * 15), CameraCache.CFrame.LookVector)
	occluder.Parent = OccludersFolder

	while task.wait(5) do
		occluder:RemoveTag("CullThrottleOccluder")
		occluder.Color = Color3.new(1, 0, 0)
		task.wait(5)
		occluder:AddTag("CullThrottleOccluder")
		occluder.Color = Color3.new(0, 1, 0)
	end
end)

OccludersFolder.Parent = workspace

-- We need to tell CullThrottle about all the objects that we want it to manage.
local FloatingBlocksUpdater = CullThrottle.new()
FloatingBlocksUpdater:CaptureTag(TAG)

local refreshRates = FloatingBlocksUpdater:GetRefreshRates()
local bestRefreshHz, worstRefreshHz = refreshRates.Max, refreshRates.Min

-- Blocks fade back to the invisible color when they leave view. Entering view
-- needs no handler of its own, since the update loop heatmap-tints every block
-- it refreshes.
FloatingBlocksUpdater.ObjectExitedView:Connect(function(block)
	block.Color = INVISIBLE_COLOR
end)

local updateDuration = 0
local objectDeltas = {}

local blocks, cframes, alphas = {}, {}, {}
RunService.PreAnimation:Connect(function()
	table.clear(blocks)
	table.clear(cframes)
	table.clear(alphas)
	table.clear(objectDeltas) -- This one is for the debug graphs.

	local now = os.clock()
	for block, dt in FloatingBlocksUpdater:IterateObjectsToUpdate() do
		-- Alpha lands at 1 for a block refreshing at the best rate and 0 at the worst,
		-- which is what the heatmap tint shows.
		local alpha = math.clamp(math.map(dt, 1 / bestRefreshHz, 1 / worstRefreshHz, 1, 0), 0, 1)
		table.insert(alphas, alpha)

		table.insert(objectDeltas, dt)
		-- The raw dt was recorded for the graphs first, since this cap on long gaps
		-- and the 3x speedup are only meant for the animation.
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
	for i, block in blocks do
		task.defer(Utility.applyHeatmapColor, block, alphas[i])
	end
end)

-- The rest of this is debug/dev stuff.

-- CullThrottle reads this global too, and in dev builds it draws its debug visuals while the flag is on.
_G.__VISUALIZE__ = false

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
BottomLeftGraphs.Size = UDim2.fromScale(0.2, 0.25)
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

local searchTimeBudget, ingestTimeBudget, updateTimeBudget = FloatingBlocksUpdater:GetTimeBudgets()
local searchDurationGraph =
	MetricGraph.new("Search Duration", table.create(50, 0), 0, searchTimeBudget * 1e6 * 1.25, "%dμs")
local ingestDurationGraph =
	MetricGraph.new("Ingest Duration", table.create(50, 0), 0, ingestTimeBudget * 1e6 * 1.25, "%dμs")
local updateDurationGraph =
	MetricGraph.new("Update Duration", table.create(50, 0), 0, updateTimeBudget * 1e6 * 1.25, "%dμs")

searchDurationGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
ingestDurationGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
updateDurationGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
searchDurationGraph.Frame.Parent = TopLeftGraphs
ingestDurationGraph.Frame.Parent = TopLeftGraphs
updateDurationGraph.Frame.Parent = TopLeftGraphs

local skippedSearchGraph = MetricGraph.new("Skipped Search", table.create(50, 0), 0, 90, "%d")
local skippedIngestGraph = MetricGraph.new("Skipped Ingest", table.create(50, 0), 0, 50, "%d")
local renderDistanceRange = FloatingBlocksUpdater:GetRenderDistanceRange()
local renderDistanceGraph =
	MetricGraph.new("Render Distance", table.create(50, 0), renderDistanceRange.Min, renderDistanceRange.Max, "%d")

skippedSearchGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
skippedIngestGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
renderDistanceGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
skippedSearchGraph.Frame.Parent = TopRightGraphs
skippedIngestGraph.Frame.Parent = TopRightGraphs
renderDistanceGraph.Frame.Parent = TopRightGraphs

local objectsVisibleGraph = MetricGraph.new("Objects Visible", table.create(50, 0), 0, 900)
local objectsUpdatedGraph = MetricGraph.new("Objects Updated", table.create(50, 0), 0, 450)
local occludedVoxelsGraph = MetricGraph.new("Voxels Occluded", table.create(50, 0), 0, 100)

objectsVisibleGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
objectsUpdatedGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
occludedVoxelsGraph.Frame.Size = UDim2.fromScale(1, 1 / 3)
objectsVisibleGraph.Frame.Parent = BottomLeftGraphs
objectsUpdatedGraph.Frame.Parent = BottomLeftGraphs
occludedVoxelsGraph.Frame.Parent = BottomLeftGraphs

local gameRefreshRateGraph = MetricGraph.new("Game Refresh Rate", table.create(50, 0), 0, 144, "%dHz")
local p05ObjectRefreshRateGraph =
	MetricGraph.new("p05 Obj Refresh", table.create(50, 0), worstRefreshHz, bestRefreshHz, "%dHz")
local avgObjectRefreshRateGraph =
	MetricGraph.new("Avg Obj Refresh", table.create(50, 0), worstRefreshHz, bestRefreshHz, "%dHz")
local p95ObjectRefreshRateGraph =
	MetricGraph.new("p95 Obj Refresh", table.create(50, 0), worstRefreshHz, bestRefreshHz, "%dHz")

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

	local perfMetrics = FloatingBlocksUpdater:GetPerformanceMetrics()
	local renderDistance = FloatingBlocksUpdater:GetRenderDistance()
	searchDurationGraph:measure(perfMetrics.searchDuration * 1e6)
	ingestDurationGraph:measure(perfMetrics.ingestDuration * 1e6)
	updateDurationGraph:measure(updateDuration * 1e6)
	skippedSearchGraph:measure(perfMetrics.skippedSearch)
	skippedIngestGraph:measure(perfMetrics.skippedIngest)
	renderDistanceGraph:measure(renderDistance)
	objectsVisibleGraph:measure(visibleObjectCount)
	-- The updated graph borrows the visible graph's peak as its max so the two graphs share a scale.
	objectsUpdatedGraph.Max = math.max(table.unpack(objectsVisibleGraph._data))
	objectsUpdatedGraph:measure(updatedObjectCount)
	occludedVoxelsGraph:measure(perfMetrics.occludedVoxelCount)
	p05ObjectRefreshRateGraph:measure(1 / (objectDeltas[math.floor(#objectDeltas * 0.05)] or math.huge))
	avgObjectRefreshRateGraph:measure(1 / perfMetrics.averageObjectDeltaTime)
	p95ObjectRefreshRateGraph:measure(1 / (objectDeltas[math.floor(#objectDeltas * 0.95)] or math.huge))
	gameRefreshRateGraph:measure(1 / gameDelta)

	-- We adjust the fog to visualize the render distance, but not when VISUALIZE
	-- is true because then we need to see the entire scene.
	if not _G.__VISUALIZE__ then
		game:GetService("Lighting").FogEnd = renderDistance * 2
		game:GetService("Lighting").FogStart = renderDistance
	end
end)

-- We use a fake camera to get a third person view.
if _G.__VISUALIZE__ then
	-- We disable dynamic render distance since the cost of the debug visuals
	-- cause it to end up near the smallest possible render distance.
	FloatingBlocksUpdater:SetRenderDistanceRange(NumberRange.new(1000))

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

	-- Unhooking CameraCache from the real camera lets this fake camera's values stick.
	CameraCache.cleanup()
	CameraCache.ViewportSize = Vector2.new(1920, 1080)
	CameraCache.AspectRatio = CameraCache.ViewportSize.X / CameraCache.ViewportSize.Y

	task.spawn(function()
		while task.wait() do
			local distanceToTarget = (testCam.CFrame.Position - targetCF.Position).Magnitude
			testCam.CFrame = testCam.CFrame:Lerp(targetCF, math.min(1 / distanceToTarget, 1))
			CameraCache.CFrame = testCam.CFrame
			CameraCache.Position = testCam.CFrame.Position
		end
	end)
end
