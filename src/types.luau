--!strict

export type VoxelKey = Vector3

export type Voxel = { Instance }

export type Volume = { any }

export type ObjectData = {
	cframe: CFrame,
	distance: number,
	halfBoundingBox: Vector3,
	radius: number,
	voxelKeys: { [VoxelKey]: true },
	desiredVoxelKeys: { [VoxelKey]: boolean },
	lastCheckClock: number,
	lastUpdateClock: number,
	jitterOffset: number,
	changeConnections: { RBXScriptConnection },
	cframeSource: Instance,
	cframeType: string,
	boundingBoxSource: Instance,
	boundingBoxType: string,
}

return nil
