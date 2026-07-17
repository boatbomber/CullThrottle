--!strict
--!optimize 2
--!native

--[[
	These are the motion-proof visibility caches, the per-voxel proofs and the
	per-bucket verdicts, both proven against the camera-motion accumulators. The
	search writes and trusts them, the voxel grid invalidates single entries as
	voxels and buckets empty, and the camera motion tracker flushes everything
	when no motion bound can relate the old frustum to the new one. Owning them
	in this leaf module lets all three depend downward instead of on each other.
]]

local types = require(script.Parent.types)

local tableClear = table.clear

local VisibilityCache = {}
VisibilityCache.__index = VisibilityCache

type VisibilityCacheProto = {
	-- This stores one packed frustum proof per voxel, trusted while the
	-- charged motion (accumT + accumF, plus accumR at the stored arm factor)
	-- stays at or under the stored expiry. VisibilitySearch's
	-- packVisibleVoxelProof and packCulledVoxelProof are the layout
	-- authority, and their headers name the inlined decode sites.
	_voxelProofs: { [types.VoxelKey]: Vector3 },
	_bucketVerdicts: { [types.CoarseVoxelKey]: types.BucketVerdict },
	-- This stores one packed occlusion proof per coarse bucket, carrying a
	-- hidden verdict or a clear verdict (the bucket is outside
	-- every umbra), trusted while its generation matches and accumT stays at
	-- or under its expiry. Occlusion depends only on camera position, so
	-- rotation and render distance charge nothing, and the proofs live apart
	-- from the bucket verdicts because occlusion is durable even for
	-- frustum-straddling buckets, which cache no frustum verdict at all.
	-- VisibilitySearch's packOccludedProof and packClearProof are the layout
	-- authority, and their headers name the inlined decode sites.
	_bucketOcclusionProofs: { [types.CoarseVoxelKey]: Vector3 },
	-- This stores the same packed occlusion proof per voxel, for cells
	-- inside umbra-contested search volumes where the bucket proof above
	-- can't apply. The clear-generation slot here carries the not-occluded
	-- verdict, that no umbra fully contains the cell, either inherited
	-- slice-wide from a search volume that pruned its last umbra or
	-- measured at the cell's own leaf test through a poke-out witness
	-- (MATH.md section 13). It's weaker than the bucket record's clear
	-- verdict, which is fine for a leaf cell, since nothing sits inside it
	-- for the weaker claim to miss.
	_voxelOcclusionProofs: { [types.VoxelKey]: Vector3 },
}

export type VisibilityCache = typeof(setmetatable({} :: VisibilityCacheProto, VisibilityCache))

--[[
	Builds an empty cache.
]]
function VisibilityCache.new(): VisibilityCache
	local self = setmetatable({
		_voxelProofs = {},
		_bucketVerdicts = {},
		_bucketOcclusionProofs = {},
		_voxelOcclusionProofs = {},
	}, VisibilityCache)

	return self
end

--[[
	Drops every cached proof and verdict. Callers that re-anchor the motion
	accumulators must clear alongside, or old proofs would be resurrected.
	CameraMotion:flushVisibilityCache pairs the two.
]]
function VisibilityCache.clear(self: VisibilityCache)
	tableClear(self._voxelProofs)
	tableClear(self._bucketVerdicts)
	tableClear(self._bucketOcclusionProofs)
	tableClear(self._voxelOcclusionProofs)
end

--[[
	Drops every cached occlusion proof at both granularities while leaving the
	frustum proofs and bucket verdicts alone. OcclusionCulling calls this when
	a generation counter wraps, since a wrapped counter could otherwise
	falsely match an ancient proof.
]]
function VisibilityCache.clearOcclusionProofs(self: VisibilityCache)
	tableClear(self._bucketOcclusionProofs)
	tableClear(self._voxelOcclusionProofs)
end

return VisibilityCache
