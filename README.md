# CullThrottle

Manage effects for tens of thousands of objects, performantly.

CullThrottle is a client-side Roblox Luau library. You hand it every object that wants a small per-frame effect (spinning, bobbing, flickering, pulsing), and each frame it hands back the ones worth updating, most important first, cut off by a time budget. Objects nobody can see cost you nothing, and the objects players are looking at update the most smoothly.

[Please consider supporting my work.](https://github.com/sponsors/boatbomber)

## Installation

Via [wally](https://wally.run):

```toml
[dependencies]
CullThrottle = "boatbomber/cullthrottle@0.1.0-rc.10"
```

Alternatively, grab the `.rbxm` standalone model from the latest [release](https://github.com/boatbomber/CullThrottle/releases/latest).

## Quick start

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

For a richer example, `demo/init.client.luau` drives an interactive scene of spinning blocks with a visibility heatmap and live metric graphs.

## How it works

Suppose your game has fifty thousand objects that each want a small per-frame effect. A frame at 60 FPS gives you about 16 milliseconds for everything the game does, and a loop that merely touches 50,000 objects eats a meaningful slice of that before doing any real work. Updating them all every frame is out of the question. But almost none of those objects are on screen at once, and of the ones that are, the big nearby ones matter far more than the distant specks. The work you actually need each frame is small. The hard part is figuring out which work that is, fast enough that the figuring saves more than it costs.

The name describes the two halves of the answer. The cull half decides what's visible without asking each object. CullThrottle divides the world into large cubic voxels and tracks which objects occupy each one, so visibility is decided per voxel against the camera's view frustum, and a room packed with a thousand objects costs one verdict instead of a thousand. On top of that, consecutive frames are nearly identical, so every verdict is cached together with how much camera movement it provably survives. On a typical frame, most of the world re-validates with a single comparison per cached answer instead of a fresh geometry test.

The throttle half decides what the visible objects deserve. Each one is scored, dominated by how large it looms on screen, with smaller corrections so neglected objects gain urgency and nearby ones get a nudge. The scores feed a priority queue, and your update loop drains it under a time budget. Anything that misses a frame comes back more urgent the next, and an object overdue past its worst allowed refresh rate jumps to the front of the line. Every visible object keeps updating, update frequency tracks importance, and under sustained pressure the whole system slows down smoothly instead of letting some objects freeze.

Budgets tie all of it together. Every phase of the per-frame pipeline runs under a fixed time allowance with a defined fallback when it runs out, so a heavy frame degrades the precision of the answers rather than your frame rate. A small controller also floats the render distance between the bounds you configure, shrinking it when the budgets strain and growing it back when there's headroom, so the workload converges to whatever the current scene can afford.

### Going deeper

That summary is enough to use the library, and the API reference below covers the rest of what you need day to day. If you want to actually understand the machinery, [docs/SYSTEM.md](./docs/SYSTEM.md) walks the entire per-frame pipeline mechanism by mechanism, building up the voxel grid, the frustum test, the motion-proof cache, the search, the priority scoring, and every degradation path, with the goal that CullThrottle goes from black magic to entirely obvious by the end. [docs/MATH.md](./docs/MATH.md) is its companion for the formulas and proofs behind those mechanisms, from the frustum plane construction to the soundness argument for the motion proofs to a ledger of every approximation and the direction it errs. Read SYSTEM.md first, since MATH.md leans on its vocabulary.

## Best practices

1. Use `IterateObjectsToUpdate` for per-frame update logic. It's designed to be called every frame and returns objects in order of importance, so the most important objects are updated first and all visible objects are eventually reached.

2. Prefer BaseParts. While CullThrottle can accept many instance types, it is designed for BaseParts. If you provide an entire model, the bounding box of the model is used for visibility checks and prioritization. If you're only really updating one part of that model, add that part as the object instead.

3. Anchor your BaseParts. A part moved by Roblox's physics engine doesn't fire the CFrame changed event when it moves, so it has to be added with `AddPhysicsObject` so CullThrottle polls its position instead. Polling has a noticeable performance cost and can even produce incorrect visibility if the object moves too quickly.

4. Use tags. CollectionService tags are a powerful way to group objects and let CullThrottle manage them. You can add and remove tags at runtime, and CullThrottle tracks the tagged objects automatically. A BasePart that is unanchored at the moment it's captured is added as a physics object, so anchor your objects before they get picked up if you don't want that (see the previous practice). That routing happens once at capture, so changing the Anchored property later doesn't move an object between static and physics tracking.

## Supported object types

CullThrottle tracks each object using two things, a position (a CFrame) and a bounding box (a size). It derives each one from the object you add, choosing the source based on the object's class. The position source and the bounding box source are resolved independently, so a class can supply one directly while the other comes from an ancestor. For any class not listed below, CullThrottle walks up the object's ancestry until it finds a class it understands, and if it finds none, the object cannot be tracked.

| Class | Position | Bounding box | Notes |
| --- | --- | --- | --- |
| `BasePart` | `CFrame` | `Size` | The intended and best supported case. |
| `Model` | `GetPivot()` | `GetBoundingBox()` | Uses the whole model's bounds. With no `PrimaryPart`, position tracks `WorldPivot`. Prefer adding the specific part you animate (see best practices). |
| `Bone` | `TransformedWorldCFrame` | nearest ancestor | Position follows the deformed bone, and size comes from the ancestor part. |
| `Attachment` | `WorldCFrame` | nearest ancestor | Position follows the attachment, and size comes from the ancestor part. |
| `Beam` | midpoint of `Attachment0` and `Attachment1` | `max(Width0, Width1)` square in cross section, by the attachment-to-attachment distance in length | Requires both `Attachment0` and `Attachment1`. Without them, CullThrottle cannot place or size the beam and warns instead. |
| `PointLight` / `SpotLight` | nearest ancestor | `Range` cubed (`Vector3.one * Range`) | Position comes from the part or attachment the light sits in. |
| `Sound` | nearest ancestor | `RollOffMaxDistance` cubed (`Vector3.one * RollOffMaxDistance`) | Position comes from the part or attachment the sound sits in. |

CullThrottle also subscribes to the relevant change signals for whichever source it picked (for example a `BasePart`'s `Size`, a light's `Range`, or a beam's `Width0`/`Width1` and attachment positions), so the position and bounding box stay current as those properties change.

Setting an object's `Parent` to `nil` behaves differently depending on where its sources live. An object whose position or bounding box comes from an ancestor (a light, sound, attachment, or bone) can no longer resolve that source and is dropped from tracking. An object that supplies its own geometry (a `BasePart` or `Model`) stays tracked at its last location, since leaving the world fires no destruction signal. If you pool parts by setting `Parent = nil`, remove them from CullThrottle explicitly.

## API reference

Every entry below shows the full signature, followed by what it does. Configuration entries pair each setter with its matching getter and list the default.

### Creating and destroying

```Luau
CullThrottle.new(): CullThrottle
```

Creates a new CullThrottle instance with reasonable defaults (listed under configuration below) and starts its per-frame processing loop.

```Luau
CullThrottle:Destroy()
```

Tears down the instance. Disconnects its internal per-frame processing loop, releases all tag and object change listeners, drops all signal handlers, and clears its tracked state so the instance can be garbage collected. Call this when you're done with an instance, and don't use it afterwards.

This does not destroy or modify the objects you added to CullThrottle. It only stops CullThrottle from tracking them.

### Adding and removing objects

```Luau
CullThrottle:AddObject(object: Instance)
```

Adds an object for CullThrottle to track visibility for.

```Luau
CullThrottle:AddPhysicsObject(object: BasePart)
```

Adds an object that is moved by physics for CullThrottle to track visibility for. Changed events don't fire for objects moved by Roblox's physics engine, so this method tells CullThrottle to poll the object for position changes instead.

```Luau
CullThrottle:RemoveObject(object: Instance)
```

Removes an object from CullThrottle's tracking.

```Luau
CullThrottle:CaptureTag(tag: string)
```

Adds all objects with the given CollectionService tag to CullThrottle's tracking, then listens to the tag's InstanceAdded and InstanceRemoved events so objects are added and removed automatically as the tag set changes.

Unanchored BaseParts are added as physics objects, so be sure to anchor your objects before they get picked up if you don't want that behavior. This routing happens once, when the object is captured. Changing a part's Anchored property later does not move it between static and physics tracking, so re-toggle the tag (or remove and re-add the object) if its anchored state changes.

Tracking does not record how an object arrived. When an object loses the last captured tag it carries, it is removed from tracking even if it was also added directly with `AddObject`. Re-add such an object after the tag toggle if you want it to stay tracked.

```Luau
CullThrottle:ReleaseTag(tag: string)
```

Stops listening to the InstanceAdded and InstanceRemoved events for the given tag. Releasing a tag does not remove the objects that `CaptureTag` already added. Call `RemoveObjectsWithTag` explicitly if you want them removed.

```Luau
CullThrottle:RemoveObjectsWithTag(tag: string)
```

Removes all objects with the given tag from CullThrottle's tracking.

### Reading visibility

```Luau
CullThrottle:IterateObjectsToUpdate(): () -> (Instance?, number?, number?, CFrame?)
```

Returns an iterator over this frame's visible objects in update-priority order. The order is banded rather than exact, so objects with nearly identical priorities may come out in either order, while any meaningful priority difference is respected. Each iteration yields the object, the time in seconds since that particular object's last update (which is what your effect should advance by), the object's distance from the camera, and the object's CFrame. The distance and CFrame are values CullThrottle already computed this frame, handed over so you don't pay to read them again.

```Luau
RunService.Heartbeat:Connect(function()
    for object, dt, distance, cframe in CullThrottle:IterateObjectsToUpdate() do
        -- Update the object here.
    end
end)
```

The iterator checks the clock as it goes and simply stops when the update time budget runs out. Whatever didn't get updated grows more urgent next frame, so all visible objects are eventually reached. Objects overdue past the worst refresh rate are allowed to run the budget a little over (or far over, with `SetStrictlyEnforceWorstRefreshRate` enabled) so the minimum rate holds up.

```Luau
CullThrottle:GetVisibleObjects(): { Instance }
```

Returns all objects that CullThrottle believes to be visible this frame.

CullThrottle does not guarantee that the returned set is exactly the visible set. Under normal conditions it errs on the side of caution, so it may return some objects that are not actually visible. In performance constrained scenarios it is forced to make approximations that may impact accuracy in either direction. If the search budget runs out, CullThrottle reuses last frame's visibility for the volumes it did not have time to re-check, which can momentarily keep returning an object that just left view, or omit one that just entered view, until a later frame catches up. If the ingest budget runs out, CullThrottle dumps the remaining visible objects into the result at a coarse, approximate priority rather than computing a precise one. The returned list contains no duplicates even when these fallbacks are hit.

### Signals

```Luau
CullThrottle.ObjectAdded: Signal<Instance>
CullThrottle.ObjectRemoved: Signal<Instance>
```

Fire when an object is added to or removed from CullThrottle's tracking, with the object as the argument. These come in handy with `CaptureTag`, where objects arrive and leave without you calling anything.

```Luau
CullThrottle.ObjectEnteredView: Signal<Instance>
CullThrottle.ObjectExitedView: Signal<Instance>
```

Fire when an object joins or leaves the visible set, with the object as the argument. These are for effects that only care about appearing and disappearing rather than per-frame updates.

```Luau
CullThrottle.ObjectEnteredView:Connect(function(object: Instance)
    -- The object is now visible.
end)
```

Both signals are buffered during the frame and fired together at the end, after all of CullThrottle's own iteration is finished, so a handler can safely add or remove objects. Every entered event fires before any exited event. Exits are also softened by a short grace period, so an object flickering at the edge of view doesn't fire a storm of events. An object you remove from tracking is evicted from the visible set silently, with `ObjectRemoved` as the only announcement.

A connection to either signal counts as standing demand for visibility, so the pipeline runs every frame even when `SetComputeVisibilityOnlyOnDemand` is enabled.

### Configuration

```Luau
CullThrottle:SetVoxelSize(voxelSize: number)
CullThrottle:GetVoxelSize(): number
```

The size of the voxels used for visibility checks, in studs. The default is 100. Smaller voxels make visibility more precise but cost more memory and more search work. Changing the size forces CullThrottle to recompute which voxels every object occupies and to flush its visibility caches, so it's expensive and best done right after construction, before any objects are added. The size must be a finite number greater than zero.

```Luau
CullThrottle:SetRenderDistanceRange(renderDistanceRange: NumberRange)
CullThrottle:GetRenderDistanceRange(): NumberRange
CullThrottle:GetDynamicRenderDistance(): boolean
```

The bounds, in studs, that the render distance is allowed to move between. The default is 150 to 2000. Objects beyond the current render distance are not considered for visibility checks.

The live distance starts at the range's midpoint, and a controller adjusts it within the bounds every frame, growing it when the time budgets have headroom and shrinking it when they strain. For example, `SetRenderDistanceRange(NumberRange.new(200, 3000))` lets CullThrottle render anywhere from 200 to 3000 studs, starting at the 1600 stud midpoint. To pin the render distance to a fixed value (disabling dynamic adjustment), pass a zero-width range such as `NumberRange.new(600, 600)`.

`GetDynamicRenderDistance` is derived from the range, returning true whenever the configured range spans more than a single value. The bounds must be finite and greater than zero.

```Luau
CullThrottle:SetTimeBudgets(searchTimeBudget: number, ingestTimeBudget: number, updateTimeBudget: number)
CullThrottle:GetTimeBudgets(): (number, number, number)
```

The per-frame time allowances, in seconds, for the search, ingest, and update phases. The defaults are 0.0008, 0.0012, and 0.0004 (0.8 ms, 1.2 ms, and 0.4 ms). These budgets ensure CullThrottle never consumes enough of a frame to cause drops, and each phase has a graceful fallback when its budget runs out.

The search phase finds the voxels that are considered visible. If its budget runs out, CullThrottle reuses the last known visibility of each voxel it did not have time to search, which can be momentarily incorrect.

The ingest phase scores the objects in the visible voxels into the update queue. If its budget runs out, the remaining objects are queued at a coarse priority rather than a precise one, which can reduce how well the update order matches importance.

The update phase is the time spent by `IterateObjectsToUpdate`. If its budget runs out, the iterator simply stops returning objects. The most important objects come first, so they'll likely have been updated already, and whatever was left grows in priority for the next frame.

Dynamic render distance adjusts to keep the work fitting these budgets, so a lower budget settles at a shorter render distance and vice versa. Budgets must be non-negative, and a budget of zero turns its phase off entirely.

```Luau
CullThrottle:SetRefreshRates(refreshRates: NumberRange)
CullThrottle:GetRefreshRates(): NumberRange
```

The range of refresh rates objects can earn, in Hz (updates per second). The default is `NumberRange.new(15, 60)`. The range's `Max` is the best (most frequent) rate, the fastest CullThrottle will update any object, and its `Min` is the worst (least frequent) rate, the slowest a visible object is allowed to fall to. The default updates the most important objects up to 60 times per second and the least important ones at least 15 times per second. Both rates must be greater than zero, otherwise this throws.

In some scenarios these rates may be violated. If there is surplus update budget, objects may be updated more frequently than the best rate. If there is not enough update budget, objects may slip below the worst rate. If you want to guarantee that objects never fall below the worst rate, even at the cost of game performance, use `SetStrictlyEnforceWorstRefreshRate`.

```Luau
CullThrottle:SetComputeVisibilityOnlyOnDemand(computeVisibilityOnlyOnDemand: boolean)
CullThrottle:GetComputeVisibilityOnlyOnDemand(): boolean
```

Off by default. When enabled, CullThrottle computes visibility only when `GetVisibleObjects` or `IterateObjectsToUpdate` is called, instead of at the start of every frame. If you intend to call one of those methods every frame anyway, leave this off so the work happens at a predictable point in the frame. A connection to `ObjectEnteredView` or `ObjectExitedView` counts as demand, so visibility is computed every frame regardless while either has listeners.

```Luau
CullThrottle:SetStrictlyEnforceWorstRefreshRate(strictlyEnforceWorstRefreshRate: boolean)
CullThrottle:GetStrictlyEnforceWorstRefreshRate(): boolean
```

Off by default. When enabled, objects that are overdue past the worst refresh rate ignore the update time budget entirely, trading frame time for a guaranteed minimum refresh rate. This can lead to performance issues, so only use it for cases that truly demand a floor.

### Inspecting state

```Luau
CullThrottle:GetRenderDistance(): number
```

Returns the current, effective render distance in studs. With dynamic render distance enabled this is the value the controller has currently settled on. To read the configured bounds, use `GetRenderDistanceRange` instead.

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
