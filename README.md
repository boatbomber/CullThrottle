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
--TODO
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
CullThrottle:CaptureTagged(tag: string)
```

```Luau
CullThrottle:ReleaseTagged(tag: string)
```

### Primary Functionality

```Luau
CullThrottle:GetVisibleObjects(): { Instance }
```

```Luau
CullThrottle:IterateObjectsToUpdate(): () -> (Instance?, number?, number?)
```

### Configuration

```Luau
CullThrottle:SetVoxelSize(voxelSize: number)
```

```Luau
CullThrottle:SetTargetRenderDistance(renderDistanceTarget: number)
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

- Parallel computation of visible voxels. The search algorithm has been built with this future optimization in mind, so it should be relatively straightforward.
- Reduced memory footprint. CullThrottle inherently trades CPU time for memory, but we want to minimize this tradeoff as much as possible.
