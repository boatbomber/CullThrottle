# CullThrottle

Manage effects for tens of thousands of objects, performantly.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
CullThrottle = "boatbomber/cullthrottle@0.1.0-rc.1"
```

Alternatively, grab the `.rbxm` standalone model from the latest [release.](https://github.com/boatbomber/CullThrottle/releases/latest)

## Example Usage

```Luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CullThrottle = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("CullThrottle"))

-- Create 20,000 parts
for i = 1, 20_000 do
    local block = Instance.new("Part")
    block.Name = "SpinningBlock" .. i
    block.Size = Vector3.one * math.random(1, 10)
    block.Color = Color3.fromHSV(math.random(), 0.5, 0.8)
    block.CFrame = CFrame.new(math.random(-1000, 1000), math.random(-1000, 1000), math.random(-1000, 1000))
        * CFrame.Angles(math.random(-math.pi, math.pi), math.random(-math.pi, math.pi), math.random(-math.pi, math.pi))
    block.Anchored = true
    block.CanCollide = false
    block.CastShadow = false
    block:AddTag("SpinningBlock")

    block.Parent = workspace
end

-- Create a CullThrottle instance
local SpinningBlocks = CullThrottle.new()
-- Register all the tagged parts with CullThrottle
SpinningBlocks:CaptureTag("SpinningBlock")

-- Every frame, animate the blocks that CullThrottle provides
local blocks, cframes, blockIndex = {}, {}, 0
RunService.Heartbeat:Connect(function()
    blockIndex = 0
    table.clear(blocks)
    table.clear(cframes)

    for block, dt in SpinningBlocks:IterateObjectsToUpdate() do
        dt = math.min(dt, 1 / 15)

        local angularForce = CFrame.Angles(0, math.rad(90) * dt, 0)

        blockIndex += 1
        blocks[blockIndex] = block
        cframes[blockIndex] = block.CFrame * angularForce
    end

    workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)
```

## Best Practices

TODO

## API

### Constructor

```Luau
CullThrottle.new()
```

### Object Management

```Luau
CullThrottle:AddObject(object: Instance)
```

```Luau
CullThrottle:AddPhysicsObject(object: BasePart)
```

```Luau
CullThrottle:RemoveObject(object: Instance)
```

```Luau
CullThrottle:CaptureTag(tag: string)
```

```Luau
CullThrottle:ReleaseTag(tag: string)
```

### Primary Functionality

```Luau
CullThrottle:GetVisibleObjects(): { Instance }
```

```Luau
CullThrottle:IterateObjectsToUpdate(): () -> (Instance?, number?, number?)
```

```Luau
CullThrottle.ObjectEnteredView: Signal
```

```Luau
CullThrottle.ObjectExitedView: Signal
```

### Configuration

```Luau
CullThrottle:SetVoxelSize(voxelSize: number)
```

```Luau
CullThrottle:SetRenderDistanceTarget(renderDistanceTarget: number)
```

```Luau
CullThrottle:SetTimeBudgets(searchTimeBudget: number, ingestTimeBudget: number, updateTimeBudget: number)
```

```Luau
CullThrottle:SetRefreshRates(bestRefreshRate: number, worstRefreshRate: number)
```

```Luau
CullThrottle:SetComputeVisibilityOnlyOnDemand(computeVisibilityOnlyOnDemand: boolean)
```

```Luau
CullThrottle:SetStrictlyEnforceWorstRefreshRate(strictlyEnforceWorstRefreshRate: boolean)
```

```Luau
CullThrottle:SetDynamicRenderDistance(dynamicRenderDistance: boolean)
```

## Roadmap

- Parallel computation of visible voxels. I built the search algorithm with this future optimization in mind, so it should be relatively straightforward.
- Reduced memory footprint. CullThrottle inherently trades CPU time for memory, but we want to minimize this tradeoff as much as possible.
