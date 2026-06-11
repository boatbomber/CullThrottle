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
	-- This stores one packed proof per voxel. X is the visible expiry, Y is the
	-- culled expiry (-1 marks the verdict the proof does not carry), and Z is the
	-- arm factor the rotation debit is charged at. The proof is trusted while
	-- (accumT + accumF) + accumR * Z stays at or under the stored expiry.
	_voxelProofs: { [types.VoxelKey]: Vector3 },
	_bucketVerdicts: { [types.CoarseVoxelKey]: types.BucketVerdict },
}

export type VisibilityCache = typeof(setmetatable({} :: VisibilityCacheProto, VisibilityCache))

--[[
	Builds an empty cache.
]]
function VisibilityCache.new(): VisibilityCache
	local self = setmetatable({
		_voxelProofs = {},
		_bucketVerdicts = {},
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
end

return VisibilityCache
