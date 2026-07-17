local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))

local TestHelpers = require(script.Parent.TestHelpers)
-- The straddling fixture's planes all cut through the box around the camera
-- apex. The roomy fixture's far plane sits 100 voxels out so boxes can be
-- fully inside.
local straddlingFrustumPlanes = TestHelpers.straddlingFrustumPlanes
local roomyFrustumPlanes = TestHelpers.roomyFrustumPlanes

--[[
	Returns the box's true clearance to one plane (how far inside of it the
	farthest-out corner sits), measured corner by corner so the assertions
	below don't reuse the implementation's sphere shortcut.
]]
local function trueClearanceToPlane(
	planePos: Vector3,
	planeNormal: Vector3,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	local maxDist = -math.huge
	for _, x in { x0, x1 } do
		for _, y in { y0, y1 } do
			for _, z in { z0, z1 } do
				local dist = (Vector3.new(x, y, z) - planePos):Dot(planeNormal)
				if dist > maxDist then
					maxDist = dist
				end
			end
		end
	end
	return -maxDist
end

--[[
	Returns how far the plane must sweep before it passes the box entirely (the
	depth of the box's deepest-inside corner), measured corner by corner so the
	assertions below don't reuse the implementation's projection interval
	shortcut.
]]
local function trueExitClearanceToPlane(
	planePos: Vector3,
	planeNormal: Vector3,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	local minDist = math.huge
	for _, x in { x0, x1 } do
		for _, y in { y0, y1 } do
			for _, z in { z0, z1 } do
				local dist = (Vector3.new(x, y, z) - planePos):Dot(planeNormal)
				if dist < minDist then
					minDist = dist
				end
			end
		end
	end
	return -minDist
end

--[[
	Returns how far past the plane the box's closest corner sits. When the box
	is fully outside the plane, the plane must sweep at least this far before
	it can touch the box, so no sound rejection margin can exceed it. It reads
	the exit-clearance oracle from the outside, which is just a sign flip.
]]
local function trueMarginPastPlane(
	planePos: Vector3,
	planeNormal: Vector3,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	return -trueExitClearanceToPlane(planePos, planeNormal, x0, y0, z0, x1, y1, z1)
end

describe("Frustum", function()
	describe("isBoxInFrustum", function()
		it("flags exactly the straddled planes for a box wrapping the camera apex", function()
			local inside, straddledMask = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 0, 0, 0, 1, 1, 1)

			expect(inside).toBe(true)
			-- The box wraps the camera apex and extends toward +X and +Z, so it
			-- pokes through exactly the two side planes whose normals lean that
			-- way. The -X and -Z planes and the far plane only touch its faces
			-- from the inside, so their bits must stay clear.
			expect(straddledMask).toBe(0b00101)
		end)

		it("rejects a box past a side plane with a sound margin to that plane", function()
			-- The box sits far out the +X side and well short of the roomy far
			-- plane, so the +X side plane is the only plane that can reject it.
			-- The whole circumscribing sphere sits past that plane, so the cheap
			-- sphere check alone proves the rejection.
			local inside, straddledMask, margin, _, _, _, rejectedByFar =
				Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 8, 8, 8, 10, 10, 10)

			expect(inside).toBe(false)
			expect(straddledMask).toBe(0)
			expect(rejectedByFar).toBe(false)

			-- The margin is a conservative motion bound with a ceiling and a
			-- floor. Overstating the closest corner's distance past the plane
			-- would keep the box counted as culled after camera motion could
			-- already bring it back, while any sound estimate still clears the
			-- circumscribing sphere's margin.
			local closestCornerDist =
				trueMarginPastPlane(roomyFrustumPlanes[5], roomyFrustumPlanes[6], 8, 8, 8, 10, 10, 10)
			local boxCenter = Vector3.new(9, 9, 9)
			local sphereRadius = (Vector3.new(10, 10, 10) - boxCenter).Magnitude
			local centerDist = (boxCenter - roomyFrustumPlanes[5]):Dot(roomyFrustumPlanes[6])
			local sphereMargin = centerDist - sphereRadius - 1e-4
			expect(margin > 0).toBe(true)
			expect(margin <= closestCornerDist).toBe(true)
			expect(margin >= sphereMargin - 1e-3).toBe(true)
		end)

		it("rejects a far box through the sphere check with a sound margin past the far plane", function()
			-- This unit box sits straight up the view axis three voxels past the
			-- far plane and fully inside every side plane, so the far plane is the
			-- only possible rejector and the cheap sphere check alone proves it.
			local inside, straddledMask, margin, _, _, _, rejectedByFar =
				Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 0, 4, 0, 1, 5, 1)

			expect(inside).toBe(false)
			expect(straddledMask).toBe(0)
			-- The rejection must flag the far plane, since render distance
			-- changes are the one motion that can expire a far-plane rejection.
			expect(rejectedByFar).toBe(true)

			-- The margin follows the same ceiling and floor as any rejection.
			-- It can never overstate the closest corner's distance past the far
			-- plane, and any sound estimate still clears the circumscribing
			-- sphere's margin.
			local closestCornerDist =
				trueMarginPastPlane(straddlingFrustumPlanes[9], straddlingFrustumPlanes[10], 0, 4, 0, 1, 5, 1)
			local boxCenter = Vector3.new(0.5, 4.5, 0.5)
			local sphereRadius = (Vector3.new(1, 5, 1) - boxCenter).Magnitude
			local centerDist = (boxCenter - straddlingFrustumPlanes[9]):Dot(straddlingFrustumPlanes[10])
			local sphereMargin = centerDist - sphereRadius - 1e-4
			expect(margin > 0).toBe(true)
			expect(margin <= closestCornerDist).toBe(true)
			expect(margin >= sphereMargin - 1e-3).toBe(true)
		end)

		it("rejects a box fully behind the camera", function()
			-- There is no near plane, so behind-camera culling has to emerge
			-- from the four side planes converging at the apex. This box sits
			-- centered on the view axis at negative view-axis coordinates, the
			-- way a box the camera just flew past would.
			local inside, straddledMask, margin, _, _, _, rejectedByFar =
				Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, -0.5, -5, -0.5, 0.5, -4, 0.5)

			expect(inside).toBe(false)
			expect(straddledMask).toBe(0)
			-- A side plane rejects it, never the far plane, which faces away
			-- from the back half-space.
			expect(rejectedByFar).toBe(false)

			-- Behind the apex the box sits fully outside several side planes at
			-- once, and no single-plane proof can beat the closest corner
			-- distance of the most generous rejecting plane, so that is the
			-- soundness ceiling for the margin.
			local bestCornerMargin = 0
			for i = 1, 9, 2 do
				local cornerMargin = trueMarginPastPlane(
					straddlingFrustumPlanes[i],
					straddlingFrustumPlanes[i + 1],
					-0.5,
					-5,
					-0.5,
					0.5,
					-4,
					0.5
				)
				bestCornerMargin = math.max(bestCornerMargin, cornerMargin)
			end
			expect(margin > 0).toBe(true)
			expect(margin <= bestCornerMargin).toBe(true)
		end)

		it("returns a conservative positive slack for a fully-inside box", function()
			-- A unit box 40 voxels up the +Y view axis sits well inside the side
			-- planes and short of the far plane 100 voxels out.
			local inside, straddledMask, slack, exitSlack =
				Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 0, 40, 0, 1, 41, 1)

			expect(inside).toBe(true)
			expect(straddledMask).toBe(0)
			-- With no straddled plane there is no exit clearance to report.
			expect(exitSlack).toBe(math.huge)

			-- The slack is a conservative motion bound. It must never overstate
			-- the true corner-measured clearance to the nearest plane, and the
			-- sphere shortcut may understate it by at most the circumscribing
			-- sphere's radius.
			local worstClearance = math.huge
			for i = 1, 9, 2 do
				local clearance =
					trueClearanceToPlane(roomyFrustumPlanes[i], roomyFrustumPlanes[i + 1], 0, 40, 0, 1, 41, 1)
				worstClearance = math.min(worstClearance, clearance)
			end
			local sphereRadius = (Vector3.new(1, 41, 1) - Vector3.new(0, 40, 0)).Magnitude / 2
			expect(slack > 0).toBe(true)
			expect(slack <= worstClearance).toBe(true)
			expect(slack >= worstClearance - sphereRadius).toBe(true)
		end)

		it("proves a box inside with the exact corner clearance when the sphere cannot", function()
			-- This unit box hugs the +X side plane from the inside. Its
			-- circumscribing sphere pokes past that plane, so only the exact
			-- projection interval can prove the box inside, and that branch yields
			-- the tightest proof there is, the true corner clearance.
			local inside, straddledMask, slack =
				Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 26.9, 40, 0, 27.9, 41, 1)

			expect(inside).toBe(true)
			expect(straddledMask).toBe(0)

			local worstClearance = math.huge
			for i = 1, 9, 2 do
				local clearance =
					trueClearanceToPlane(roomyFrustumPlanes[i], roomyFrustumPlanes[i + 1], 26.9, 40, 0, 27.9, 41, 1)
				worstClearance = math.min(worstClearance, clearance)
			end
			expect(slack > 0).toBe(true)
			expect(slack).toBeCloseTo(worstClearance, 4)
		end)

		it("rejects a box the sphere check cannot decide using the exact projection", function()
			-- The box pokes just past the far plane one voxel out. At center
			-- distance 0.6 its circumscribing sphere (radius ~0.87) straddles the
			-- plane, so only the exact projection interval (radius 0.5) can prove
			-- the rejection, and the margin is the leftover past that interval.
			local inside, straddledMask, margin, _, _, _, rejectedByFar =
				Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 0, 1.1, 0, 1, 2.1, 1)

			expect(inside).toBe(false)
			expect(straddledMask).toBe(0)
			expect(margin).toBeCloseTo(0.1, 3)
			expect(rejectedByFar).toBe(true)
		end)

		it("reports how far the straddled plane must sweep before the box can exit", function()
			-- This box pokes through the +X side plane only, so the exit slack is
			-- that one plane's clearance to the box's deepest-inside corner.
			local inside, straddledMask, _, exitSlack =
				Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 12, 18, 0, 16, 22, 4)

			expect(inside).toBe(true)
			expect(straddledMask).toBe(0b00100)

			-- The box keeps intersecting until the plane sweeps past its
			-- deepest corner, so the exit slack must cover that corner depth
			-- without overstating it beyond the comparison guard band.
			local cornerDepth =
				trueExitClearanceToPlane(roomyFrustumPlanes[5], roomyFrustumPlanes[6], 12, 18, 0, 16, 22, 4)
			expect(exitSlack >= cornerDepth).toBe(true)
			expect(exitSlack).toBeCloseTo(cornerDepth, 3)
		end)

		it("keeps the smallest exit clearance when the box straddles two planes", function()
			-- This box near the frustum's +X +Z corner pokes through both of those
			-- side planes at meaningfully different depths.
			local inside, straddledMask, _, exitSlack =
				Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 13, 18, 26.5, 17, 22, 30.5)

			expect(inside).toBe(true)
			expect(straddledMask).toBe(0b00101)

			-- The box stops intersecting as soon as the shallower plane
			-- can sweep past it, so the reported exit slack must be the smaller of
			-- the two corner depths. Reporting the deeper one would overstate how
			-- long a cached intersection verdict stays provable.
			local depthZ =
				trueExitClearanceToPlane(roomyFrustumPlanes[1], roomyFrustumPlanes[2], 13, 18, 26.5, 17, 22, 30.5)
			local depthX =
				trueExitClearanceToPlane(roomyFrustumPlanes[5], roomyFrustumPlanes[6], 13, 18, 26.5, 17, 22, 30.5)
			expect(math.abs(depthX - depthZ) > 1).toBe(true)
			expect(exitSlack).toBeCloseTo(math.min(depthX, depthZ), 3)
		end)

		it("reports only the far-plane straddle bit for a box crossing the far plane", function()
			-- This thin box rides the view axis and crosses the far plane one
			-- voxel out while staying fully inside every side plane, so the far
			-- bit must be the only straddle bit.
			local inside, straddledMask, _, exitSlack, sideSlack, farSlack =
				Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, -0.1, 0.5, -0.1, 0.1, 1.5, 0.1)

			expect(inside).toBe(true)
			expect(straddledMask).toBe(0b10000)

			-- A straddled plane records no slack, so the far slack keeps its
			-- untouched default of math.huge while the side planes still report
			-- a finite clearance.
			expect(farSlack).toBe(math.huge)
			expect(sideSlack > 0).toBe(true)
			expect(sideSlack < math.huge).toBe(true)

			-- The exit clearance comes from the far plane, so it must cover that
			-- plane's deepest-inside corner without overstating it beyond the
			-- comparison guard band.
			local cornerDepth = trueExitClearanceToPlane(
				straddlingFrustumPlanes[9],
				straddlingFrustumPlanes[10],
				-0.1,
				0.5,
				-0.1,
				0.1,
				1.5,
				0.1
			)
			expect(exitSlack >= cornerDepth).toBe(true)
			expect(exitSlack).toBeCloseTo(cornerDepth, 3)
		end)

		it("ignores a rejecting plane that the mask excludes", function()
			-- The box sits past the far plane only. With the far plane masked
			-- out, no tested plane can reject it, so it reports intersecting.
			local insideFull = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 0, 8, 0, 1, 9, 1)
			local insideMasked = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b01111, 0, 8, 0, 1, 9, 1)

			expect(insideFull).toBe(false)
			expect(insideMasked).toBe(true)
		end)

		it("keeps straddle bits aligned to absolute planes under a partial mask", function()
			-- This box straddles only the third plane pair. Masking out the
			-- first plane must not shift the reported bit, since child volumes
			-- carry these masks across subdivision levels.
			local _, fullMask = Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 12, 18, 0, 16, 22, 4)
			local _, partialMask = Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11110, 12, 18, 0, 16, 22, 4)

			expect(fullMask).toBe(0b00100)
			expect(partialMask).toBe(fullMask)
		end)

		it("reports a rejection by an appended sixth plane like a side plane", function()
			-- Callers may append planes past the standard five, the way the
			-- occluder prefilter closes the frustum behind the camera. This
			-- sixth plane caps the frustum 50 voxels up the view axis, so it
			-- alone rejects a box the five real planes prove fully inside, and
			-- the rejection must not read as a far-plane one, since only the
			-- real far plane moves with the render distance.
			local planes = table.clone(roomyFrustumPlanes)
			table.insert(planes, Vector3.new(0, 50, 0))
			table.insert(planes, Vector3.new(0, -1, 0))

			local insideWithoutCap = Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 0, 40, 0, 1, 41, 1)
			local inside, straddledMask, margin, _, _, _, rejectedByFar =
				Frustum.isBoxInFrustum(planes, 0b111111, 0, 40, 0, 1, 41, 1)

			expect(insideWithoutCap).toBe(true)
			expect(inside).toBe(false)
			expect(straddledMask).toBe(0)
			expect(margin > 0).toBe(true)
			expect(rejectedByFar).toBe(false)
		end)
	end)

	describe("classifyBucket", function()
		-- Both functions feed the motion-proof caches, so each test here pins
		-- classifyBucket's proof numbers against isBoxInFrustum's on the same box.
		-- If the two ever disagree, bucket verdicts and voxel proofs would expire
		-- at different motion thresholds for the same geometry.

		it("culls a box past a side plane with isBoxInFrustum's rejection margin", function()
			local state, straddledMask, sideSlack, farSlack, margin, rejectedByFar =
				Frustum.classifyBucket(straddlingFrustumPlanes, 8, 8, 8, 10, 10, 10)
			local inside, _, boxMargin = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 8, 8, 8, 10, 10, 10)

			expect(inside).toBe(false)
			expect(state).toBe(Frustum.BUCKET_CULLED)
			expect(straddledMask).toBe(0)
			expect(sideSlack).toBe(0)
			expect(farSlack).toBe(0)
			expect(margin).toBe(boxMargin)
			-- A side plane rejects this box, so render distance changes can never
			-- bring it back into view.
			expect(rejectedByFar).toBe(false)
		end)

		it("reports a far-plane rejection so render distance changes can expire it", function()
			-- This box sits straight up the view axis past the far plane one voxel
			-- out, well inside every side plane.
			local state, _, _, _, margin, rejectedByFar =
				Frustum.classifyBucket(straddlingFrustumPlanes, 0, 8, 0, 1, 9, 1)
			local inside, _, boxMargin = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 0, 8, 0, 1, 9, 1)

			expect(inside).toBe(false)
			expect(state).toBe(Frustum.BUCKET_CULLED)
			expect(margin).toBe(boxMargin)
			expect(rejectedByFar).toBe(true)
		end)

		it("splits a fully-inside box's clearance between the side planes and the far plane", function()
			local state, straddledMask, sideSlack, farSlack, margin, rejectedByFar =
				Frustum.classifyBucket(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			local inside, _, boxSlack = Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 0, 40, 0, 4, 44, 4)

			expect(inside).toBe(true)
			expect(state).toBe(Frustum.BUCKET_INSIDE)
			expect(straddledMask).toBe(0)

			-- The clearances are conservative motion bounds, so each must be
			-- positive yet never exceed the true corner-measured clearance to its
			-- governing plane. Overstating either would let a cached verdict
			-- outlive the camera motion that can flip it.
			local worstSideClearance = math.huge
			for i = 1, 7, 2 do
				local clearance =
					trueClearanceToPlane(roomyFrustumPlanes[i], roomyFrustumPlanes[i + 1], 0, 40, 0, 4, 44, 4)
				worstSideClearance = math.min(worstSideClearance, clearance)
			end
			local farClearance = trueClearanceToPlane(roomyFrustumPlanes[9], roomyFrustumPlanes[10], 0, 40, 0, 4, 44, 4)
			expect(sideSlack > 0).toBe(true)
			expect(sideSlack <= worstSideClearance).toBe(true)
			expect(farSlack > 0).toBe(true)
			expect(farSlack <= farClearance).toBe(true)

			expect(math.min(sideSlack, farSlack)).toBe(boxSlack)
			expect(margin).toBe(0)
			expect(rejectedByFar).toBe(false)
		end)

		it("hands a straddling box the partial proof the subdivision continues from", function()
			-- This box pokes through the right side plane only, so the verdict is
			-- straddling with that one plane in the mask, and the clearances to the
			-- planes it is fully inside of survive as the partial proof.
			local state, straddledMask, sideSlack, farSlack, margin, rejectedByFar =
				Frustum.classifyBucket(roomyFrustumPlanes, 12, 18, 0, 16, 22, 4)
			local inside, boxStraddledMask, boxSlack =
				Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 12, 18, 0, 16, 22, 4)

			expect(inside).toBe(true)
			expect(state).toBe(Frustum.BUCKET_STRADDLING)
			expect(straddledMask).never.toBe(0)
			expect(straddledMask).toBe(boxStraddledMask)

			-- The surviving clearances cover only the planes the box is fully
			-- inside of (the straddled right plane contributes nothing). Each is
			-- a conservative bound, positive but no more than the true
			-- corner-measured clearance to its plane.
			local worstInsideSideClearance = math.huge
			for i = 1, 7, 2 do
				local clearance =
					trueClearanceToPlane(roomyFrustumPlanes[i], roomyFrustumPlanes[i + 1], 12, 18, 0, 16, 22, 4)
				if clearance > 0 then
					worstInsideSideClearance = math.min(worstInsideSideClearance, clearance)
				end
			end
			local farClearance =
				trueClearanceToPlane(roomyFrustumPlanes[9], roomyFrustumPlanes[10], 12, 18, 0, 16, 22, 4)
			expect(sideSlack > 0).toBe(true)
			expect(sideSlack <= worstInsideSideClearance).toBe(true)
			expect(farSlack > 0).toBe(true)
			expect(farSlack <= farClearance).toBe(true)

			expect(math.min(sideSlack, farSlack)).toBe(boxSlack)
			expect(margin).toBe(0)
			expect(rejectedByFar).toBe(false)
		end)

		it("leaves a far-straddling bucket's far slack at math.huge", function()
			-- This thin box crosses only the far plane, so the straddle carries
			-- no far clearance at all and the math.huge default must survive to
			-- the returned partial proof, leaving render distance changes free.
			local state, straddledMask, sideSlack, farSlack, margin, rejectedByFar =
				Frustum.classifyBucket(straddlingFrustumPlanes, -0.1, 0.5, -0.1, 0.1, 1.5, 0.1)
			local inside, boxStraddledMask, _, _, boxSideSlack, boxFarSlack =
				Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, -0.1, 0.5, -0.1, 0.1, 1.5, 0.1)

			expect(inside).toBe(true)
			expect(state).toBe(Frustum.BUCKET_STRADDLING)
			expect(straddledMask).toBe(0b10000)
			expect(straddledMask).toBe(boxStraddledMask)
			expect(sideSlack).toBe(boxSideSlack)
			expect(sideSlack < math.huge).toBe(true)
			expect(farSlack).toBe(math.huge)
			expect(farSlack).toBe(boxFarSlack)
			expect(margin).toBe(0)
			expect(rejectedByFar).toBe(false)
		end)
	end)
end)
