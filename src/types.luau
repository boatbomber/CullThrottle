--!strict

--[[
	These are the shared data type definitions, the shapes that travel between
	subsystems (object records, voxel keys, cached verdicts, perf metrics). Each
	subsystem's own type lives with its class, so only data that more than one
	module reads belongs here.
]]

export type VoxelKey = Vector3

export type CoarseVoxelKey = Vector3

export type Voxel = { ObjectData }

export type CFrameSourceType = "BasePart" | "Model" | "Bone" | "Attachment" | "Beam"

export type BoundingBoxSourceType = "BasePart" | "Model" | "Beam" | "Light" | "Sound"

export type BucketVerdict = {
	-- The cached frustum verdict for one coarse bucket's unclipped box, proven
	-- against the motion accumulators. state is BUCKET_CULLED or BUCKET_INSIDE.
	-- A straddling bucket stores no record at all.
	state: number,
	armFactor: number,
	sideExpiry: number,
	farExpiry: number,
}

export type ObjectData = {
	-- Backref to the tracked instance, so ObjectData-holding paths never pay an
	-- Instance-keyed map lookup.
	object: Instance,
	cframe: CFrame,
	position: Vector3,
	distance: number,
	halfBoundingBox: Vector3,
	radius: number,
	-- voxelKeys is the current occupancy set, and desiredVoxelKeys is the
	-- pending diff against it (true enters, false leaves).
	voxelKeys: { [VoxelKey]: true },
	desiredVoxelKeys: { [VoxelKey]: boolean },
	lastCheckClock: number,
	lastUpdateClock: number,
	-- Zero means out of view. The ingest stamps it every visible frame and the
	-- zero-to-nonzero flip is the enter event.
	lastVisibleClock: number,
	-- The object's bucket and slot in the exit sweep's due buckets, or zero
	-- while out of view, kept current so removal can evict directly.
	exitSweepBucketIndex: number,
	exitSweepSlot: number,
	-- The object's slot in the physics poll list, or zero when not
	-- physics-driven. Doubles as the duplicate registration guard.
	physicsObjectIndex: number,
	jitterOffset: number,
	changeConnections: { RBXScriptConnection },
	cframeSource: Instance,
	cframeType: CFrameSourceType,
	boundingBoxSource: Instance,
	boundingBoxType: BoundingBoxSourceType,
}

export type PerfMetrics = {
	-- Ring buffers, indexed by _skippedFramesCursor, of voxels skipped when the
	-- search and ingest budgets ran out.
	_skippedSearch: { number },
	_skippedIngest: { number },
	_skippedFramesCursor: number,
	-- Voxels the current frame's search skipped as inside an occluder's umbra.
	_occludedVoxelCount: number,
	_searchDuration: number,
	_ingestDuration: number,
	_averageObjectDeltaTime: number,
	-- Delta times accumulate here and the next frame's reset commits them, so
	-- an iterator the consumer abandoned early still contributes.
	_sumOfObjectDeltaTimes: number,
	_updatedObjectCount: number,
	_getAverage: ({ number }) -> number,
}

return nil
