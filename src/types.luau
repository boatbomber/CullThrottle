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
	-- This is the cached frustum verdict for one coarse bucket's full (unclipped)
	-- box, proven against the camera-motion accumulators. The state field is
	-- BUCKET_CULLED or BUCKET_INSIDE. A straddling bucket stores no record at all
	-- (its verdict can flip with any motion, so there is nothing durable to cache).
	state: number,
	armFactor: number,
	sideExpiry: number,
	farExpiry: number,
}

export type ObjectData = {
	-- This is a backref to the tracked instance. Voxels and the visible-objects
	-- queue store ObjectData directly so neither the ingest loops nor the update
	-- iterator pay an Instance-keyed objects-map lookup, and signals and the
	-- iterator hand out the Instance through this field.
	object: Instance,
	cframe: CFrame,
	position: Vector3,
	distance: number,
	halfBoundingBox: Vector3,
	radius: number,
	-- voxelKeys is the set of voxels the object currently occupies, while
	-- desiredVoxelKeys is the pending diff against it (true means enter that
	-- voxel, false means leave it) that VoxelGrid.updateObjectVoxels drains.
	voxelKeys: { [VoxelKey]: true },
	desiredVoxelKeys: { [VoxelKey]: boolean },
	lastCheckClock: number,
	lastUpdateClock: number,
	-- A lastVisibleClock of zero means the object is out of view. The ingest
	-- stamps it every visible frame and treats the zero-to-nonzero flip as the
	-- enter event, and it only returns to zero when the exit sweep gives up on
	-- the object after the signal grace period (or when it is removed).
	lastVisibleClock: number,
	-- These locate the object's entry in the signals' exit sweep due buckets
	-- (which bucket it is scheduled in and its slot there), or zero while it is
	-- out of view. Every reschedule and swap-remove keeps them current so
	-- removal can clear the entry directly instead of scanning for it.
	exitSweepBucketIndex: number,
	exitSweepSlot: number,
	-- This is the object's slot in the lifecycle's physics poll list, or zero
	-- when the object isn't physics-driven. It doubles as the duplicate
	-- registration guard and the direct removal handle.
	physicsObjectIndex: number,
	jitterOffset: number,
	changeConnections: { RBXScriptConnection },
	cframeSource: Instance,
	cframeType: CFrameSourceType,
	boundingBoxSource: Instance,
	boundingBoxType: BoundingBoxSourceType,
}

export type PerfMetrics = {
	-- These are ring buffers, indexed by _skippedFramesCursor, of how many voxels
	-- the last few frames' search and ingest passes had to skip when their budgets
	-- ran out.
	_skippedSearch: { number },
	_skippedIngest: { number },
	_skippedFramesCursor: number,
	_searchDuration: number,
	_ingestDuration: number,
	_averageObjectDeltaTime: number,
	-- The update iteration accumulates delta times here, and the next frame's
	-- reset commits them into the average. Committing at the start of the frame
	-- means an iterator the consumer abandoned early still contributes.
	_sumOfObjectDeltaTimes: number,
	_updatedObjectCount: number,
	_getAverage: ({ number }) -> number,
}

return nil
