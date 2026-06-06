# CullThrottle

Manage effects for tens of thousands of objects, performantly.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
CullThrottle = "boatbomber/cullthrottle@0.1.0-rc.9"
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

    for block, dt, distance, cframe in SpinningBlocks:IterateObjectsToUpdate() do
        dt = math.min(dt, 1 / 15)

        local angularForce = CFrame.Angles(0, math.rad(90) * dt, 0)

        blockIndex += 1
        blocks[blockIndex] = block
        cframes[blockIndex] = cframe * angularForce
    end

    workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)
```

## How it works

Magic! (jk, I'll write a nice explanation soon tm)

## Best Practices

1. **Use IterateObjectsToUpdate for per-frame update logic.** This method is designed to be called every frame and will return objects in order of importance. This ensures that the most important objects are updated first, and that all visible objects are eventually updated.

2. **Prefer BaseParts.** While CullThrottle _can_ accept any instance, it is designed for BaseParts. If you provide an entire model, the bounding box of the model will be used for visibility checks and prioritization. If you're only really updating one part of that model, prefer to add that part as the object instead.

3. **Anchor your BaseParts.** If your part is moved by Roblox's physics engine, it will not fire the cframe changed event when it moves. This means that you'll need to add it with AddPhysicsObject to have CullThrottle poll the object for its position. This has a noticeable performance impact, and can even lead to incorrect visibilities if the object moves too quickly.

4. **Use tags.** CollectionService tags are a powerful way to group objects together and manage them with CullThrottle. You can add and remove tags at runtime, and CullThrottle will automatically track the objects with those tags. It will automatically add BaseParts as physics objects if they are not anchored, so don't forget #3!

## Supported Object Types

CullThrottle tracks each object using two things: a **position** (a CFrame) and a **bounding box** (a size). It derives each one from the object you add, choosing the source based on the object's class. The position source and the bounding box source are resolved independently, so a class can supply one directly while the other comes from an ancestor. For any class not listed below, CullThrottle walks up the object's ancestry until it finds a class it understands; if it finds none, the object cannot be tracked.

| Class | Position | Bounding box | Notes |
| --- | --- | --- | --- |
| `BasePart` | `CFrame` | `Size` | The intended and best supported case. |
| `Model` | `GetPivot()` | `GetBoundingBox()` | Uses the whole model's bounds. With no `PrimaryPart`, position tracks `WorldPivot`. Prefer adding the specific part you animate (see Best Practices). |
| `Bone` | `TransformedWorldCFrame` | nearest ancestor | Position follows the deformed bone; size comes from the ancestor part. |
| `Attachment` | `WorldCFrame` | nearest ancestor | Position follows the attachment; size comes from the ancestor part. |
| `Beam` | midpoint of `Attachment0` and `Attachment1` | `max(Width0, Width1)` square in cross section, by the attachment-to-attachment distance in length | Requires both `Attachment0` and `Attachment1`. Without them, CullThrottle cannot place or size the beam and warns instead. |
| `PointLight` / `SpotLight` | nearest ancestor | `Range` cubed (`Vector3.one * Range`) | Position comes from the part or attachment the light sits in. |
| `Sound` | nearest ancestor | `RollOffMaxDistance` cubed (`Vector3.one * RollOffMaxDistance`) | Position comes from the part or attachment the sound sits in. |

CullThrottle also subscribes to the relevant change signals for whichever source it picked (for example a `BasePart`'s `Size`, a light's `Range`, or a beam's `Width0`/`Width1` and attachment positions), so the position and bounding box stay current as those properties change.

## API

### Constructor

```Luau
CullThrottle.new()
```

Creates a new CullThrottle instance with reasonable defaults.

```Luau
CullThrottle:Destroy()
```

Tears down the CullThrottle instance. Disconnects its internal per-frame processing loop, releases all tag and object change listeners, drops all signal handlers, and clears its tracked state so the instance can be garbage collected.

Call this when you're done with a CullThrottle instance. The instance must not be used afterwards.

**IMPORTANT:** This does not destroy or modify the objects you added to CullThrottle; it only stops CullThrottle from tracking them.

### Object Management

```Luau
CullThrottle:AddObject(object: Instance)
```

Adds an object for CullThrottle to track visibility for.

```Luau
CullThrottle:AddPhysicsObject(object: BasePart)
```

Adds an object that is moved by physics for CullThrottle to track visibility for.

Changed events don't fire for objects that are moved by Roblox's physics engine, so this method informs CullThrottle that it needs to poll this object for position changes.

```Luau
CullThrottle:RemoveObject(object: Instance)
```

Removes an object from CullThrottle's tracking.

```Luau
CullThrottle:CaptureTag(tag: string)
```

Adds all objects with a given tag to CullThrottle's tracking. Listens to the InstanceAdded and InstanceRemoved events for this tag, adding and removing objects automatically.

**IMPORTANT:** It will add the object as a physics object if it is a non-anchored BasePart. Be sure to anchor your objects before they get picked up by InstanceAdded if you do not want this behavior.

```Luau
CullThrottle:ReleaseTag(tag: string)
```

Stops listening to the InstanceAdded and InstanceRemoved events for a given tag.

**IMPORTANT:** It will not remove objects that were added by CaptureTag. You must call RemoveObjectsWithTag explicitly if you want them removed.

```Luau
CullThrottle:RemoveObjectsWithTag(tag: string)
```

Removes all objects with a given tag from CullThrottle's tracking.

```Luau
CullThrottle.ObjectAdded: Signal
```

Fires when an object is added to CullThrottle's tracking. The object is passed as the first argument. Comes in handy when using CaptureTag.

```Luau
CullThrottle.ObjectRemoved: Signal
```

Fires when an object is removed from CullThrottle's tracking. The object is passed as the first argument. Comes in handy when using CaptureTag.

### Primary Functionality

```Luau
CullThrottle:GetVisibleObjects(): { Instance }
```

Returns all objects that CullThrottle believes to be visible this frame.

**IMPORTANT:** CullThrottle does not guarantee that the returned set is exactly the visible set. Under normal conditions it errs on the side of caution, so it may return some objects that are not actually visible. In performance constrained scenarios it is forced to make approximations that may impact accuracy in either direction:

- If the **search** budget runs out, CullThrottle reuses last frame's visibility for the volumes it did not have time to re-check. Until a later frame catches up, that can momentarily keep returning an object that just left view, or omit one that just entered view.
- If the **ingest** budget runs out, CullThrottle dumps the remaining visible objects into the result at a coarse, approximate priority rather than computing a precise one.

The returned list contains no duplicates even when these fallbacks are hit.

```Luau
CullThrottle:IterateObjectsToUpdate(): () -> (Instance?, number?, number?, CFrame?)
```

Returns an iterator that will iterate over objects that should be updated this frame based on the current configuration. Iterator returns the object, the time since the object was last updated, the distance between the object and the camera, and the object's cframe.

Example:

> ```Luau
> RunService.Heartbeat:Connect(function()
>     for object, dt, distance, cframe in CullThrottle:IterateObjectsToUpdate() do
>         -- Update object
>     end
> end)
> ```

```Luau
CullThrottle.ObjectEnteredView: Signal
```

Signal that fires when an object is added to the list of visible objects. The object is passed as the first argument.

Example:

> ```Luau
> CullThrottle.ObjectEnteredView:Connect(function(object: Instance)
>     -- Object is now visible
> end)
> ```

```Luau
CullThrottle.ObjectExitedView: Signal
```

Signal that fires when an object is removed from the list of visible objects. The object is passed as the first argument.

### Configuration

```Luau
CullThrottle:SetVoxelSize(voxelSize: number)
```

Updates the size of the voxels used for visibility checks. Smaller voxels are more accurate but require more memory and computation.

Updating the size of the voxels will force CullThrottle to recompute which voxel each object is in, so this operation can be expensive and should basically only be used right after construction before any objects are added.

```Luau
CullThrottle:SetRenderDistanceTarget(renderDistanceTarget: number)
```

Sets the target render distance for CullThrottle. Objects that are further away than this distance will not be considered for visibility checks.

**IMPORTANT:** By default, dynamic render distance is enabled. CullThrottle will automatically adjust the render distance from your target by up to a 66% reduction or +500% extension in order to maintain an ideal balance of performance and quality. If you disable dynamic render distance, you should manually set the render distance target to a reasonable value for your use case.

```Luau
CullThrottle:SetTimeBudgets(searchTimeBudget: number, ingestTimeBudget: number, updateTimeBudget: number)
```

Sets the time budgets for the search, ingest, and update phases of CullThrottle. These budgets are used to ensure that CullThrottle does not consume too much time in any one phase, which could lead to frame drops.

The search phase finds the voxels that are considered visible. If the budget runs out, CullThrottle will use the last known visibilities of each voxel it did not have time to search. This can lead to incorrect visibilities.

The ingest phase processes the objects that are in the visible voxels. If the budget runs out, CullThrottle will simply dump all remaining objects into the visible list at a low priority. This can lead to bad update prioritization and reduced visual quality.

The update phase is the time spent by `IterateObjectsToUpdate`. If the budget runs out, the iterator will simply stop returning any more objects. The objects are returned in order of importance, so the most important objects will likely be updated already. (Objects that were not updated this frame increase in priority for the next frame, ensuring all visible objects are eventually updated.)

Note that dynamic render distance will adjust the render distance as needed in order to remain within these budgets. A lower budget will result in a lower render distance and vice versa.

```Luau
CullThrottle:SetRefreshRates(bestHz: number, worstHz: number)
```

Sets the desired refresh rates for CullThrottle, in Hz (updates per second). The best refresh rate is the maximum rate at which CullThrottle will update objects, and the worst refresh rate is the minimum rate at which CullThrottle will update objects. Both must be greater than zero, and `bestHz` must be at least `worstHz` (the best rate is the more frequent one); otherwise this throws.

For example, `SetRefreshRates(60, 15)` updates the most important objects up to 60 times per second and the least important ones at least 15 times per second.

**IMPORTANT:** In some scenarios, these rates may be violated. If there is surplus update budget, objects may be updated more frequently than the best refresh rate. If there is not enough update budget, objects may be updated less frequently than the worst refresh rate. If you want to guarantee that objects do not go below the worst rate, even at the cost of game performance, you can use `SetStrictlyEnforceWorstRefreshRate`.

```Luau
CullThrottle:SetComputeVisibilityOnlyOnDemand(computeVisibilityOnlyOnDemand: boolean)
```

If enabled, CullThrottle will compute visibility when `GetVisibleObjects` or `IterateObjectsToUpdate` is called. If disabled, it will compute visibility at the start of every frame.

If you intend to call one of the methods every frame anyway, it is recommended to allow CullThrottle to compute visibility at the start of each frame.

**IMPORTANT:** If there are connections to `ObjectEnteredView` or `ObjectExitedView`, CullThrottle will compute visibility every frame regardless to ensure that those events fire correctly.

```Luau
CullThrottle:SetStrictlyEnforceWorstRefreshRate(strictlyEnforceWorstRefreshRate: boolean)
```

If enabled, CullThrottle will strictly enforce the worst refresh rate, even if it means that the update time budget is exceeded. This may lead to performance issues, and should only be used for cases that truly demand a minimum refresh rate.

```Luau
CullThrottle:SetDynamicRenderDistance(dynamicRenderDistance: boolean)
```

If enabled, CullThrottle will automatically adjust the render distance to maintain an ideal balance of performance and quality for the current scenario and hardware. If disabled, you should manually set the render distance target to a reasonable value for your use case.

It is _highly recommended_ to leave dynamic render distance enabled unless you have a specific reason to disable it. It will get you the best performance and quality within your time budget, and most importantly it will result in more consistent and correct visibilities by avoiding going over budget and using the approximate visibilities.

### Reading Configuration & State

Each configuration setter has a matching getter that returns the same value(s) in the same units.

```Luau
CullThrottle:GetVoxelSize(): number
CullThrottle:GetRenderDistanceTarget(): number
CullThrottle:GetTimeBudgets(): (number, number, number) -- search, ingest, update (seconds)
CullThrottle:GetRefreshRates(): (number, number) -- best, worst (Hz)
CullThrottle:GetComputeVisibilityOnlyOnDemand(): boolean
CullThrottle:GetStrictlyEnforceWorstRefreshRate(): boolean
CullThrottle:GetDynamicRenderDistance(): boolean
```

`GetRefreshRates` returns rates in Hz, matching what you pass to `SetRefreshRates`.

```Luau
CullThrottle:GetRenderDistance(): number
```

Returns the **current, effective** render distance. With dynamic render distance enabled this is the value the controller has settled on, which may differ from the target you set with `SetRenderDistanceTarget` (use `GetRenderDistanceTarget` to read that back).

```Luau
CullThrottle:IsTracking(object: Instance): boolean
CullThrottle:GetTrackedObjects(): { Instance }
CullThrottle:GetTrackedObjectCount(): number
```

`IsTracking` reports whether a specific instance is currently tracked. `GetTrackedObjects` returns a fresh array of every tracked instance (safe to iterate or mutate, since it is a snapshot, not the internal store). `GetTrackedObjectCount` returns how many objects are tracked without allocating.

```Luau
CullThrottle:GetPerformanceMetrics(): {
    searchDuration: number, -- seconds, last frame
    ingestDuration: number, -- seconds, last frame
    skippedSearch: number, -- voxels the search budget skipped last frame
    skippedIngest: number, -- voxels the ingest budget skipped last frame
    averageObjectDeltaTime: number, -- seconds (invert for an average refresh rate in Hz)
}
```

Returns a read-only snapshot of the latest performance metrics. Useful for graphing or tuning your time budgets.

## Roadmap

- Parallel computation of visible voxels. I built the search algorithm with this future optimization in mind, so it should be relatively straightforward.
- Reduced memory footprint. CullThrottle inherently trades CPU time for memory, but we want to minimize this tradeoff as much as possible.
