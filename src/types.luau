--!strict

export type VoxelKey = Vector3

export type CoarseVoxelKey = Vector3

export type Voxel = { Instance }

export type CFrameSourceType = "BasePart" | "Model" | "Bone" | "Attachment" | "Beam"

export type BoundingBoxSourceType = "BasePart" | "Model" | "Beam" | "Light" | "Sound"

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
	cframeType: CFrameSourceType,
	boundingBoxSource: Instance,
	boundingBoxType: BoundingBoxSourceType,
}

return nil
