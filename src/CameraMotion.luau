--!strict
--!optimize 2
--!native

--[[
	This module owns the camera-motion accumulators every cached visibility
	verdict is proven against. _accumT (translation, in voxel units), _accumR
	(rotation, radians, covering full axis-angle turns so roll counts, plus
	projection half-angle swings since FOV and aspect changes rotate the side
	planes about the camera) and _accumF (render distance changes) only ever
	grow, so a verdict that stores the accumulator reading past which it can no
	longer be trusted is validated with a single comparison. When no motion
	bound can relate the old frustum to the new one, the caches flush and the
	accumulators re-anchor at zero instead.
]]

local Config = require(script.Parent.Config)
local VisibilityCache = require(script.Parent.VisibilityCache)
local CameraCache = require(script.Parent.Utilities.CameraCache)

local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number

-- Voxel proofs are packed into Vector3s, whose f32 components lose absolute
-- precision as the motion accumulators grow. Flushing re-anchors everything at
-- zero before f32 rounding (about 1.2e-7 of the compared magnitude) can eat
-- into the SLACK_SAFETY margin that keeps proofs from outliving their
-- verdicts. Reaching either limit takes a lot of sustained motion,
-- and the price is one cold frame.
local ACCUM_TRANSLATION_FLUSH_LIMIT = 16384 -- This counts voxels of translation plus render distance change.
local ACCUM_ROTATION_FLUSH_LIMIT = 64 -- This one is in radians.

local CameraMotion = {}
CameraMotion.__index = CameraMotion

type CameraMotionProto = {
	_config: Config.Config,
	_visibilityCache: VisibilityCache.VisibilityCache,

	-- These are the camera-motion accumulators, in voxel units, monotone
	-- non-decreasing. Every cached visibility verdict stores expiries in these
	-- metrics, and a verdict is trusted only while the accumulated motion since
	-- its proof stays under the clearance the proof established. _accumF tracks
	-- render distance changes separately so far-plane breathing only invalidates
	-- far-bound bucket verdicts. Voxel proofs charge it in full alongside
	-- translation.
	_accumT: number,
	_accumR: number,
	_accumF: number,
	-- This counts every visibility cache flush. The search's whole-frame
	-- replay compares it across frames, because a flush leaves the
	-- accumulators at zero while re-anchoring what they measure from (and can
	-- mean the camera itself was replaced), so matching accumulator readings
	-- across one prove nothing.
	_flushCount: number,
	_lastCameraCFrame: CFrame,
	_lastRenderDistanceVoxels: number,
	_lastHalfVerticalFOV: number,
	_lastHalfHorizontalFOV: number,
	_lastCameraGeneration: number,
}

export type CameraMotion = typeof(setmetatable({} :: CameraMotionProto, CameraMotion))

--[[
	Builds the tracker anchored to the camera's current pose, with every
	accumulator starting at zero.
]]
function CameraMotion.new(config: Config.Config, visibilityCache: VisibilityCache.VisibilityCache): CameraMotion
	local self = setmetatable({
		_config = config,
		_visibilityCache = visibilityCache,
		_accumT = 0,
		_accumR = 0,
		_accumF = 0,
		_flushCount = 0,
		_lastCameraCFrame = CameraCache.CFrame,
		_lastRenderDistanceVoxels = config.renderDistance / config.voxelSize,
		_lastHalfVerticalFOV = CameraCache.HalfVerticalFOV,
		_lastHalfHorizontalFOV = CameraCache.HalfHorizontalFOV,
		_lastCameraGeneration = CameraCache.Generation,
	}, CameraMotion)

	return self
end

--[[
	Drops every cached visibility verdict and re-anchors the motion accumulators
	to the camera's current pose. Resetting the accumulators without clearing
	the caches would resurrect old proofs, so the two always happen together.
	This is needed when no motion bound can relate the old planes to the new
	ones, meaning the camera itself was replaced or the voxel size changed
	(every cached quantity is in voxel units).
]]
function CameraMotion.flushVisibilityCache(self: CameraMotion)
	self._visibilityCache:clear()
	self._accumT = 0
	self._accumR = 0
	self._accumF = 0
	self._flushCount += 1
	self._lastCameraCFrame = CameraCache.CFrame
	self._lastRenderDistanceVoxels = self._config.renderDistance / self._config.voxelSize
	self._lastHalfVerticalFOV = CameraCache.HalfVerticalFOV
	self._lastHalfHorizontalFOV = CameraCache.HalfHorizontalFOV
	self._lastCameraGeneration = CameraCache.Generation
end

--[[
	Advances the motion accumulators by how far the camera moved since the last
	processed frame. Only endpoint poses matter for the bound, so gaps between
	processed frames (computeVisibilityOnlyOnDemand) are covered. A camera swap
	has no motion bound at all, so it flushes instead.
]]
function CameraMotion.accumulate(self: CameraMotion)
	if CameraCache.Generation ~= self._lastCameraGeneration then
		self:flushVisibilityCache()
		return
	end

	local voxelSize = self._config.voxelSize
	local renderDistanceVoxels = self._config.renderDistance / voxelSize

	local cameraCFrame = CameraCache.CFrame
	local lastCameraCFrame = self._lastCameraCFrame
	if cameraCFrame ~= lastCameraCFrame then
		-- We take the full axis-angle of the orientation delta, so roll is covered
		-- too (roll swings the side plane normals even though the look vector is
		-- unchanged).
		local _axis, rotation = lastCameraCFrame.Rotation:ToObjectSpace(cameraCFrame.Rotation):ToAxisAngle()
		self._accumT += vectorMagnitude(cameraCFrame.Position - lastCameraCFrame.Position) / voxelSize
		self._accumR += rotation
		self._lastCameraCFrame = cameraCFrame
	end

	-- A projection change rotates each side plane about the camera by the
	-- change in that axis's half-angle and leaves the far plane alone, so it
	-- sweeps the planes no farther than a camera rotation of the larger
	-- half-angle delta would. That lets it charge the rotation accumulator
	-- instead of flushing the caches.
	local halfVerticalFOV = CameraCache.HalfVerticalFOV
	local halfHorizontalFOV = CameraCache.HalfHorizontalFOV
	if halfVerticalFOV ~= self._lastHalfVerticalFOV or halfHorizontalFOV ~= self._lastHalfHorizontalFOV then
		self._accumR += math.max(
			math.abs(halfVerticalFOV - self._lastHalfVerticalFOV),
			math.abs(halfHorizontalFOV - self._lastHalfHorizontalFOV)
		)
		self._lastHalfVerticalFOV = halfVerticalFOV
		self._lastHalfHorizontalFOV = halfHorizontalFOV
	end

	local farDelta = math.abs(renderDistanceVoxels - self._lastRenderDistanceVoxels)
	if farDelta > 0 then
		self._accumF += farDelta
		self._lastRenderDistanceVoxels = renderDistanceVoxels
	end

	-- Re-anchor before the accumulator magnitudes can push the f32 rounding of
	-- the packed voxel proofs into the SLACK_SAFETY margin.
	if self._accumT + self._accumF > ACCUM_TRANSLATION_FLUSH_LIMIT or self._accumR > ACCUM_ROTATION_FLUSH_LIMIT then
		self:flushVisibilityCache()
	end
end

return CameraMotion
