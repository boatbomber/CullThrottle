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

-- Packed voxel proofs live in f32 Vector3 components, so flushing re-anchors
-- everything at zero before f32 rounding can eat into the SLACK_SAFETY margin
-- (docs/MATH.md section 10). The price of reaching a limit is one cold frame.
local ACCUM_TRANSLATION_FLUSH_LIMIT = 16384 -- This counts voxels of translation plus render distance change.
local ACCUM_ROTATION_FLUSH_LIMIT = 64 -- This one is in radians.

local CameraMotion = {}
CameraMotion.__index = CameraMotion

-- Exported so the tests that drive flushes can pin these without copying the literals.
CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT = ACCUM_TRANSLATION_FLUSH_LIMIT
CameraMotion.ACCUM_ROTATION_FLUSH_LIMIT = ACCUM_ROTATION_FLUSH_LIMIT

type CameraMotionProto = {
	_config: Config.Config,
	_visibilityCache: VisibilityCache.VisibilityCache,

	-- The monotonic accumulators, in voxel units (radians for _accumR). _accumF
	-- tracks render distance changes separately so far-plane breathing only
	-- invalidates far-bound bucket verdicts.
	_accumT: number,
	_accumR: number,
	_accumF: number,
	-- Translation the last processed frame added to _accumT, in voxels. The
	-- occlusion layer reads it as the motion floor for its stamp gate. A flush
	-- resets it to zero, since a flush has no motion bound to report.
	_lastTranslationDelta: number,
	-- Counts every visibility cache flush. The occlusion layer refuses to reuse
	-- umbrae across a flush, since no drift measured across one is trustworthy.
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
		_lastTranslationDelta = 0,
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
	self._lastTranslationDelta = 0
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
	local translationDelta = 0
	if cameraCFrame ~= lastCameraCFrame then
		-- The full axis-angle covers roll, which swings the side plane normals
		-- even though the look vector is unchanged.
		local _axis, rotation = lastCameraCFrame.Rotation:ToObjectSpace(cameraCFrame.Rotation):ToAxisAngle()
		translationDelta = vectorMagnitude(cameraCFrame.Position - lastCameraCFrame.Position) / voxelSize
		self._accumT += translationDelta
		self._accumR += rotation
		self._lastCameraCFrame = cameraCFrame
	end

	-- A projection change sweeps the side planes no farther than a rotation of
	-- the larger half-angle delta would, so it charges the rotation accumulator
	-- instead of flushing (docs/MATH.md covers the bound).
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

	if self._accumT + self._accumF > ACCUM_TRANSLATION_FLUSH_LIMIT or self._accumR > ACCUM_ROTATION_FLUSH_LIMIT then
		self:flushVisibilityCache()
	end

	-- Recorded after any limit flush, because the camera's real motion rate this
	-- frame is still what the occlusion stamp gate should see.
	self._lastTranslationDelta = translationDelta
end

return CameraMotion
