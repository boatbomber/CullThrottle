--!strict
--!optimize 2
--!native

--[[
	These are the frustum tests for the visibility search, in voxel coordinates
	throughout. It's a stateless function library where every input arrives as
	an argument, so the tests have no instance to construct.

	Both tests measure how far a box sits from each frustum plane and report the
	verdict together with the clearance that proves it, meaning how much camera
	motion (translation, plus rotation charged at the box's arm) must accumulate
	before the verdict could flip. Those clearances are what the voxel proof and
	bucket verdict caches store as expiries.

	The five frustum planes (left, right, top, bottom, far) form a bitmask. Each
	search volume carries the mask of planes it still straddles, so child volumes
	skip the planes an enclosing volume was already completely inside of.
]]

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local vectorAbs = (vector.abs :: any) :: (Vector3 | vector) -> Vector3

-- Guard band for the plane comparisons, in voxel units.
local EPSILON = 1e-4

-- Bucket verdict states. Only culled and inside are cacheable, a straddling
-- bucket is re-searched while it straddles.
local BUCKET_STRADDLING = 0
local BUCKET_CULLED = 1
local BUCKET_INSIDE = 2

local Frustum = {}

Frustum.BUCKET_STRADDLING = BUCKET_STRADDLING
Frustum.BUCKET_CULLED = BUCKET_CULLED
Frustum.BUCKET_INSIDE = BUCKET_INSIDE

--[[
	Tests one voxel-space box against the frustum planes still active in
	planeMask, returning (intersects, mask of straddled planes with 0 meaning
	completely inside, slack, exitSlack, sideSlack, farSlack, rejectedByFar).
	This is the shared per-plane core that classifyBucket wraps as well, so the
	voxel proofs and the bucket verdicts can never disagree about the same
	geometry.

	When the box intersects, the slack is how far inside it sits from the
	nearest tested non-straddled plane (in voxel units), so the box stays inside
	those planes until camera motion accumulates past it. Planes skipped by the
	mask contribute nothing, and callers combine the returned slack with the
	slack inherited from the volume that was inside those planes.
	The exitSlack is how much motion the nearest straddled plane needs before it
	can sweep fully past the box (the box keeps intersecting until
	then), or math.huge when no tested plane is straddled. The sideSlack and
	farSlack are the same clearance as slack split by plane, the min over the
	side planes and the far plane's own, kept separate because the far plane is
	the only one a render distance change moves. When the box is rejected, the
	slack is instead the margin past the rejecting plane (the box stays outside
	until camera motion accumulates past that), and rejectedByFar says whether
	the rejecting plane was the far plane.

	Callers pass ordered voxel-space bounds (x0 <= x1, y0 <= y1, z0 <= z1)
	because the root volumes are built min-to-max and splits preserve the
	ordering. The planes are also in voxel coordinates (CameraCache divides the
	positions by voxelSize, and normals are unchanged by uniform scaling), so
	the whole test runs without unit conversion.

	planeMask carries the planes this box's ancestors straddled. A plane an
	enclosing box was completely inside of can neither reject nor straddle
	anything within it, so those planes are skipped outright.
]]
function Frustum.isBoxInFrustum(
	frustumPlanes: { Vector3 }, -- The layout is {pos, normal, pos, normal, ...}.
	planeMask: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (boolean, number, number, number, number, number, boolean)
	local center = Vector3.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
	local extents = Vector3.new((x1 - x0) * 0.5, (y1 - y0) * 0.5, (z1 - z0) * 0.5)

	-- The circumscribing sphere settles most planes without the exact box test.
	local sphereRadius = vectorMagnitude(extents)

	local straddledMask = 0
	local sideSlack = math.huge
	local farSlack = math.huge
	local minExitSlack = math.huge
	local planeBit = 1

	-- The far plane is the pair at i == 9. Callers may append extra planes
	-- past it (the occluder prefilter closes the frustum behind the camera
	-- with a sixth), and those report like side planes.
	for i = 1, #frustumPlanes, 2 do
		if bit32.band(planeMask, planeBit) ~= 0 then
			local planePos, planeNormal = frustumPlanes[i], frustumPlanes[i + 1]

			local dist = vectorDot(center - planePos, planeNormal)
			local slack = nil

			if dist > sphereRadius + EPSILON then
				return false, 0, dist - sphereRadius - EPSILON, 0, 0, 0, i == 9
			elseif dist > -sphereRadius then
				-- The sphere straddles, so fall back to the box's exact projection
				-- radius. Dotting the non-negative extents against the normal's
				-- absolute value sums the three projection terms in two vector ops.
				local radius = vectorDot(extents, vectorAbs(planeNormal))

				if dist > radius + EPSILON then
					return false, 0, dist - radius - EPSILON, 0, 0, 0, i == 9
				end

				-- The box straddles this plane, so volumes within it must keep
				-- testing it, and the exit clearance bounds when the plane could
				-- sweep fully past.
				if dist + radius > EPSILON then
					straddledMask = bit32.bor(straddledMask, planeBit)
					local exitSlack = radius + EPSILON - dist
					if exitSlack < minExitSlack then
						minExitSlack = exitSlack
					end
				else
					slack = -(dist + radius)
				end
			else
				-- The sphere is fully inside, and its slack lower-bounds the box's.
				slack = -dist - sphereRadius
			end

			if slack then
				if i == 9 then
					farSlack = slack
				elseif slack < sideSlack then
					sideSlack = slack
				end
			end
		end
		-- The bit advances even for masked-out planes to stay aligned with the index.
		planeBit *= 2
	end

	local minSlack = if farSlack < sideSlack then farSlack else sideSlack
	return true, straddledMask, minSlack, minExitSlack, sideSlack, farSlack, false
end

-- classifyBucket reaches the core through this upvalue, so a counting shim on
-- the module table only sees direct isBoxInFrustum callers.
local isBoxInFrustum = Frustum.isBoxInFrustum

--[[
	Runs the full five-plane frustum test on one coarse bucket's unclipped box
	and also reports the proof numbers the bucket verdict cache stores. It's a
	thin wrapper rearranging the shared core's outputs into (state,
	straddledMask, sideSlack, farSlack, margin, rejectedByFar). For
	BUCKET_STRADDLING, the box straddles the frustum boundary, and
	straddledMask plus the min slacks of the planes it is inside of describe
	the partial proof the subdivision search continues from. For BUCKET_CULLED,
	margin is the clearance to the rejecting plane, and rejectedByFar says
	whether that plane was the far plane (the only one that moves when the
	render distance changes). For BUCKET_INSIDE, sideSlack and farSlack are the
	min clearances to the side planes and to the far plane, kept separate so
	render distance changes only spend the far clearance.
]]
function Frustum.classifyBucket(
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (number, number, number, number, number, boolean)
	local intersects, straddledMask, slack, _exitSlack, sideSlack, farSlack, rejectedByFar =
		isBoxInFrustum(frustumPlanes, 0b11111, x0, y0, z0, x1, y1, z1)

	if not intersects then
		return BUCKET_CULLED, 0, 0, 0, slack, rejectedByFar
	end
	if straddledMask ~= 0 then
		return BUCKET_STRADDLING, straddledMask, sideSlack, farSlack, 0, false
	end
	return BUCKET_INSIDE, 0, sideSlack, farSlack, 0, false
end

return Frustum
