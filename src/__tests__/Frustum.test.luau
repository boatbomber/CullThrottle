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

describe("Frustum", function()
	describe("isBoxInFrustum", function()
		it("should detect box intersecting the frustum", function()
			local inside, straddledMask = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 0, 0, 0, 1, 1, 1)

			expect(inside).toBe(true)
			-- The box wraps the camera apex, so it straddles planes rather than
			-- sitting completely inside (a zero straddled mask).
			expect(straddledMask).never.toBe(0)
		end)

		it("should detect box outside frustum", function()
			local inside, straddledMask = Frustum.isBoxInFrustum(straddlingFrustumPlanes, 0b11111, 8, 8, 8, 10, 10, 10)

			expect(inside).toBe(false)
			expect(straddledMask).toBe(0)
		end)

		it("returns a positive slack for a fully-inside box", function()
			-- A unit box 40 voxels up the +Y view axis sits well inside the side
			-- planes and short of the far plane 100 voxels out.
			local inside, straddledMask, slack = Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 0, 40, 0, 1, 41, 1)

			expect(inside).toBe(true)
			expect(straddledMask).toBe(0)
			expect(slack > 0).toBe(true)
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
			-- This box's center is 42 voxels up the view axis with a circumscribing
			-- sphere of radius 2*sqrt(3), so the far plane 100 voxels out leaves
			-- 58 minus that radius of far clearance, and the right side plane
			-- (the nearest one) governs the side clearance.
			local state, straddledMask, sideSlack, farSlack, margin, rejectedByFar =
				Frustum.classifyBucket(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			local inside, _, boxSlack = Frustum.isBoxInFrustum(roomyFrustumPlanes, 0b11111, 0, 40, 0, 4, 44, 4)

			expect(inside).toBe(true)
			expect(state).toBe(Frustum.BUCKET_INSIDE)
			expect(straddledMask).toBe(0)
			expect(sideSlack).toBeCloseTo(42 * 0.573576391 - 2 * 0.819152057 - 2 * math.sqrt(3), 4)
			expect(farSlack).toBeCloseTo(58 - 2 * math.sqrt(3), 4)
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
			expect(sideSlack).toBeCloseTo(20 * 0.779599547 - 2 * 0.626278222 - 2 * math.sqrt(3), 4)
			expect(farSlack).toBeCloseTo(80 - 2 * math.sqrt(3), 4)
			expect(math.min(sideSlack, farSlack)).toBe(boxSlack)
			expect(margin).toBe(0)
			expect(rejectedByFar).toBe(false)
		end)
	end)
end)
