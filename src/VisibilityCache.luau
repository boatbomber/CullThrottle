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
	-- One packed frustum proof per voxel, trusted while accumT + accumF plus
	-- accumR at the stored arm factor stays at or under the stored expiry.
	-- VisibilitySearch's pack functions are the layout authority.
	_voxelProofs: { [types.VoxelKey]: Vector3 },
	_bucketVerdicts: { [types.CoarseVoxelKey]: types.BucketVerdict },
	-- One packed occlusion proof per coarse bucket (hidden or clear), trusted
	-- while its generation matches and accumT stays at or under its expiry.
	-- Occlusion depends only on camera position, and these live apart from the
	-- bucket verdicts because occlusion is durable even for frustum-straddling
	-- buckets. VisibilitySearch's pack functions are the layout authority.
	_bucketOcclusionProofs: { [types.CoarseVoxelKey]: Vector3 },
	-- The same packed proof per voxel, for cells inside umbra-contested search
	-- volumes where the bucket proof can't apply. The clear-generation slot
	-- carries the weaker not-occluded verdict (MATH.md section 13), which is
	-- fine for a leaf cell, since nothing sits inside it for the weaker claim
	-- to miss.
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
