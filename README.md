# CullThrottle

Manage effects for tens of thousands of objects, performantly.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
CullThrottle = "boatbomber/cullthrottle@0.1.0-rc.9"
```

Alternatively, grab the `.rbxm` standalone model from the latest [release](https://github.com/boatbomber/CullThrottle/releases/latest).

## Example Usage

```Luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CullThrottle = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("CullThrottle"))

-- Create 20,000 parts.
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

-- Create a CullThrottle instance.
local SpinningBlocks = CullThrottle.new()
-- Register all the tagged parts with CullThrottle.
SpinningBlocks:CaptureTag("SpinningBlock")

-- Every frame, animate the blocks that CullThrottle provides.
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

[docs/SYSTEM.md](./docs/SYSTEM.md) walks through the whole pipeline, covering what CullThrottle does each frame and why each piece is built the way it is. [docs/MATH.md](./docs/MATH.md) is its companion, showing the formulas and proofs behind those mechanisms.

## Best Practices

1. Use IterateObjectsToUpdate for per-frame update logic. This method is designed to be called every frame and will return objects in order of importance. This ensures that the most important objects are updated first, and that all visible objects are eventually updated.

2. Prefer BaseParts. While CullThrottle can accept any instance, it is designed for BaseParts. If you provide an entire model, the bounding box of the model will be used for visibility checks and prioritization. If you're only really updating one part of that model, prefer to add that part as the object instead.

3. Anchor your BaseParts. If your part is moved by Roblox's physics engine, it will not fire the cframe changed event when it moves. This means that you'll need to add it with AddPhysicsObject to have CullThrottle poll the object for its position. This has a noticeable performance impact, and can even lead to incorrect visibilities if the object moves too quickly.

4. Use tags. CollectionService tags are a powerful way to group objects together and manage them with CullThrottle. You can add and remove tags at runtime, and CullThrottle will automatically track the objects with those tags. It will automatically add BaseParts as physics objects if they are not anchored at the moment they're captured, so don't forget #3! It will not switch modes if anchored changes after it was already added.

## Supported Object Types

CullThrottle tracks each object using two things, a position (a CFrame) and a bounding box (a size). It derives each one from the object you add, choosing the source based on the object's class. The position source and the bounding box source are resolved independently, so a class can supply one directly while the other comes from an ancestor. For any class not listed below, CullThrottle walks up the object's ancestry until it finds a class it understands, and if it finds none, the object cannot be tracked.

| Class | Position | Bounding box | Notes |
| --- | --- | --- | --- |
| `BasePart` | `CFrame` | `Size` | The intended and best supported case. |
| `Model` | `GetPivot()` | `GetBoundingBox()` | Uses the whole model's bounds. With no `PrimaryPart`, position tracks `WorldPivot`. Prefer adding the specific part you animate (see Best Practices). |
| `Bone` | `TransformedWorldCFrame` | nearest ancestor | Position follows the deformed bone, and size comes from the ancestor part. |
| `Attachment` | `WorldCFrame` | nearest ancestor | Position follows the attachment, and size comes from the ancestor part. |
| `Beam` | midpoint of `Attachment0` and `Attachment1` | `max(Width0, Width1)` square in cross section, by the attachment-to-attachment distance in length | Requires both `Attachment0` and `Attachment1`. Without them, CullThrottle cannot place or size the beam and warns instead. |
| `PointLight` / `SpotLight` | nearest ancestor | `Range` cubed (`Vector3.one * Range`) | Position comes from the part or attachment the light sits in. |
| `Sound` | nearest ancestor | `RollOffMaxDistance` cubed (`Vector3.one * RollOffMaxDistance`) | Position comes from the part or attachment the sound sits in. |

CullThrottle also subscribes to the relevant change signals for whichever source it picked (for example a `BasePart`'s `Size`, a light's `Range`, or a beam's `Width0`/`Width1` and attachment positions), so the position and bounding box stay current as those properties change.

Setting an object's `Parent` to `nil` behaves differently depending on where its sources live. An object whose position or bounding box comes from an ancestor (a light, sound, attachment, or bone) can no longer resolve that source and is dropped from tracking. An object that supplies its own geometry (a `BasePart` or `Model`) stays tracked at its last location, since leaving the world fires no destruction signal. If you pool parts by setting `Parent = nil`, remove them from CullThrottle explicitly.

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

This does not destroy or modify the objects you added to CullThrottle. It only stops CullThrottle from tracking them.

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

Unanchored BaseParts are added as physics objects, so be sure to anchor your objects before they get picked up by InstanceAdded if you do not want that behavior. This routing happens once, when the object is captured. Changing a part's Anchored property later does not move it between static and physics tracking, so re-toggle the tag (or remove and re-add the object) if its anchored state changes.

Tracking does not record how an object arrived. When an object loses the last captured tag it carries, it is removed from tracking even if it was also added directly with AddObject. Re-add such an object after the tag toggle if you want it to stay tracked.

```Luau
CullThrottle:ReleaseTag(tag: string)
```

Stops listening to the InstanceAdded and InstanceRemoved events for a given tag.

Releasing a tag does not remove the objects that CaptureTag already added. Call RemoveObjectsWithTag explicitly if you want them removed.

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

CullThrottle does not guarantee that the returned set is exactly the visible set. Under normal conditions it errs on the side of caution, so it may return some objects that are not actually visible. In performance constrained scenarios it is forced to make approximations that may impact accuracy in either direction. If the search budget runs out, CullThrottle reuses last frame's visibility for the volumes it did not have time to re-check, which can momentarily keep returning an object that just left view, or omit one that just entered view, until a later frame catches up. If the ingest budget runs out, CullThrottle dumps the remaining visible objects into the result at a coarse, approximate priority rather than computing a precise one. The returned list contains no duplicates even when these fallbacks are hit.

```Luau
CullThrottle:IterateObjectsToUpdate(): () -> (Instance?, number?, number?, CFrame?)
```

Returns an iterator that will iterate over objects that should be updated this frame based on the current configuration. The iterator returns the object, the time since the object was last updated, the distance between the object and the camera, and the object's cframe.

Example:

> ```Luau
> RunService.Heartbeat:Connect(function()
>     for object, dt, distance, cframe in CullThrottle:IterateObjectsToUpdate() do
>         -- Update the object here.
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
>     -- The object is now visible.
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
CullThrottle:SetRenderDistanceRange(renderDistanceRange: NumberRange)
```

Sets the render distance range for CullThrottle, in studs. Objects that are further away than the current render distance will not be considered for visibility checks.

The range's `Min` and `Max` are the bounds that dynamic render distance is allowed to move between, and its midpoint is the baseline the render distance starts at and settles around. For example, `SetRenderDistanceRange(NumberRange.new(200, 3000))` lets CullThrottle render anywhere from 200 to 3000 studs, starting at the 1600 stud midpoint.

Dynamic render distance is implied by the range. When `Min` and `Max` differ, CullThrottle automatically adjusts the render distance within those bounds to maintain an ideal balance of performance and quality. To pin the render distance to a fixed value (disabling dynamic adjustment), pass a zero-width range such as `NumberRange.new(600, 600)`.

```Luau
CullThrottle:SetTimeBudgets(searchTimeBudget: number, ingestTimeBudget: number, updateTimeBudget: number)
```

Sets the time budgets for the search, ingest, and update phases of CullThrottle. These budgets are used to ensure that CullThrottle does not consume too much time in any one phase, which could lead to frame drops.

The search phase finds the voxels that are considered visible. If the budget runs out, CullThrottle will use the last known visibilities of each voxel it did not have time to search. This can lead to incorrect visibilities.

The ingest phase processes the objects that are in the visible voxels. If the budget runs out, CullThrottle will simply dump all remaining objects into the visible list at a low priority. This can lead to bad update prioritization and reduced visual quality.

The update phase is the time spent by `IterateObjectsToUpdate`. If the budget runs out, the iterator will simply stop returning any more objects. The objects are returned in order of importance, so the most important objects will likely be updated already. (Objects that were not updated this frame increase in priority for the next frame, ensuring all visible objects are eventually updated.)

Note that dynamic render distance will adjust the render distance as needed in order to remain within these budgets. A lower budget will result in a lower render distance and vice versa.

```Luau
CullThrottle:SetRefreshRates(refreshRates: NumberRange)
```

Sets the desired refresh rates for CullThrottle, in Hz (updates per second). The range's `Max` is the best (most frequent) refresh rate, the maximum rate at which CullThrottle will update objects, and its `Min` is the worst (least frequent) refresh rate, the minimum rate at which CullThrottle will update objects. The rates must be greater than zero, otherwise this throws.

For example, `SetRefreshRates(NumberRange.new(15, 60))` updates the most important objects up to 60 times per second and the least important ones at least 15 times per second.

In some scenarios, these rates may be violated. If there is surplus update budget, objects may be updated more frequently than the best refresh rate. If there is not enough update budget, objects may be updated less frequently than the worst refresh rate. If you want to guarantee that objects do not go below the worst rate, even at the cost of game performance, you can use `SetStrictlyEnforceWorstRefreshRate`.

```Luau
CullThrottle:SetComputeVisibilityOnlyOnDemand(computeVisibilityOnlyOnDemand: boolean)
```

If enabled, CullThrottle will compute visibility when `GetVisibleObjects` or `IterateObjectsToUpdate` is called. If disabled, it will compute visibility at the start of every frame.

If you intend to call one of the methods every frame anyway, it is recommended to allow CullThrottle to compute visibility at the start of each frame.

If there are connections to `ObjectEnteredView` or `ObjectExitedView`, CullThrottle will compute visibility every frame regardless to ensure that those events fire correctly.

```Luau
CullThrottle:SetStrictlyEnforceWorstRefreshRate(strictlyEnforceWorstRefreshRate: boolean)
```

If enabled, CullThrottle will strictly enforce the worst refresh rate, even if it means that the update time budget is exceeded. This may lead to performance issues, and should only be used for cases that truly demand a minimum refresh rate.

### Reading Configuration & State

Each configuration setter has a matching getter that returns the same value(s) in the same units.

```Luau
CullThrottle:GetVoxelSize(): number
CullThrottle:GetRenderDistanceRange(): NumberRange
CullThrottle:GetTimeBudgets(): (number, number, number)
CullThrottle:GetRefreshRates(): NumberRange
CullThrottle:GetComputeVisibilityOnlyOnDemand(): boolean
CullThrottle:GetStrictlyEnforceWorstRefreshRate(): boolean
CullThrottle:GetDynamicRenderDistance(): boolean
```

`GetTimeBudgets` returns the search, ingest, and update budgets in that order, all in seconds. `GetRefreshRates` returns a `NumberRange` in Hz, matching what you pass to `SetRefreshRates` (`Max` is the best rate, `Min` is the worst).

`GetDynamicRenderDistance` is derived, returning `true` whenever the configured render distance range spans more than a single value.

```Luau
CullThrottle:GetRenderDistance(): number
```

Returns the current, effective render distance. With dynamic render distance enabled this is the value the controller has currently settled on. To read the range you set with `SetRenderDistanceRange`, use `GetRenderDistanceRange` instead.

```Luau
CullThrottle:IsTracking(object: Instance): boolean
CullThrottle:GetTrackedObjects(): { Instance }
CullThrottle:GetTrackedObjectCount(): number
```

`IsTracking` reports whether a specific instance is currently tracked. `GetTrackedObjects` returns a fresh array of every tracked instance (safe to iterate or mutate, since it is a snapshot, not the internal store). `GetTrackedObjectCount` returns how many objects are tracked without allocating.

```Luau
CullThrottle:GetPerformanceMetrics(): {
    searchDuration: number,
    ingestDuration: number,
    skippedSearch: number,
    skippedIngest: number,
    averageObjectDeltaTime: number,
}
```

Returns a read-only snapshot of the latest performance metrics, useful for graphing or tuning your time budgets. The durations are last frame's search and ingest costs in seconds, the skipped counts are how many voxels last frame's search and ingest budgets had to skip, and averageObjectDeltaTime is the average seconds between updates across the objects the iterator handed out (invert it for an average refresh rate in Hz).

## Roadmap

Two improvements are currently planned. The first is parallel computation of visible voxels. The second is a reduced memory footprint, since CullThrottle inherently spends memory to save CPU time and we want to minimize that tradeoff as much as possible.
