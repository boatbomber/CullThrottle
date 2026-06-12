--!strict
--!optimize 2
--!native

--[[
	This is the per-frame visibility search. It finds every occupied voxel
	intersecting the view frustum, doing as little fresh work as the
	motion-proof caches allow.

	The search runs in three layers, cheapest proof first. seedSearchVolumes
	scans the coarse buckets the frustum's AABB overlaps. A bucket with a
	still-valid cached verdict resolves in two comparisons, and otherwise its
	full box is classified and a provable verdict (culled or fully inside) is
	cached. Only straddling buckets push root search volumes onto the stack.
	searchVolume then subdivides each straddling volume. Before splitting, it
	walks the slice's voxel proofs so a mostly-proven slice costs a few
	comparisons per voxel, while a mostly-cold slice bails to the box test,
	which proves whole boxes at a fraction of a test per voxel. Finally,
	searchSingleVoxel resolves one cell. It trusts a still-valid proof, and
	otherwise frustum-tests the cell and stamps a fresh proof.

	A proof's expiry is the clearance its frustum test measured (how far the
	verdict sits from flipping, in voxel units) converted into a reading of the
	camera-motion accumulators. Translation and render distance change charge at
	full weight, and rotation charges at the proof's arm (the cell's distance
	from the camera, inflated by the stored slack since translation can carry
	the camera farther while the proof lives). See CameraMotion for the
	accumulators.
]]

local types = require(script.Parent.types)
local Config = require(script.Parent.Config)
local Frustum = require(script.Parent.Frustum)
local VoxelGrid = require(script.Parent.VoxelGrid)
local CameraMotion = require(script.Parent.CameraMotion)
local VisibilityCache = require(script.Parent.VisibilityCache)
local CameraCache = require(script.Parent.Utilities.CameraCache)
local Gizmo = if _G.__DEV__ then require(script.Parent.Utilities.Gizmo) else nil :: any

local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local tableCreate = table.create
local tableMove = table.move
local tableClear = table.clear

-- This caps the slack any one voxel proof may store, in voxels. A proof's arm is
-- inflated by its own slack (translation can carry the camera that much closer
-- or farther while the proof lives), so the cap bounds that inflation, and
-- with it how stale any single proof is allowed to grow.
local SLACK_CAP = 8
-- This gets shaved off every stored slack and margin so float32 plane math noise
-- and the small-angle bound gap can only make a proof expire sooner, never later.
-- The error direction is always "re-check sooner than strictly necessary".
local SLACK_SAFETY = 1e-2
-- Each voxel proof charges its rotation debit at the cell's own arm, which is
-- the cell center's distance from the camera plus this half diagonal, covering
-- every point of the cell.
local VOXEL_HALF_DIAGONAL = math.sqrt(3) / 2
-- Bucket verdicts charge rotation the same way at the bucket's own arm. A
-- coarse bucket spans COARSE_VOXEL_SIZE voxels per axis, so the half diagonal
-- covering every point of its box is correspondingly larger.
local BUCKET_HALF_DIAGONAL = VoxelGrid.COARSE_VOXEL_SIZE * math.sqrt(3) / 2
-- Recenters an integer voxel key onto its cell center.
local VOXEL_CENTER_OFFSET = Vector3.new(0.5, 0.5, 0.5)
-- The proof walk over a volume's voxels re-tests expired voxels cell by cell
-- while they stay rare, so scattered expiries cost a few cell tests instead of
-- re-subdividing the volume. Once unproven voxels outnumber proven ones by
-- this margin, the slice is mostly cold and box subdivision amortizes better
-- (it proves whole boxes at a fraction of a test per voxel), so the walk bails
-- after at most margin + 1 misses on a fully cold slice.
local UNPROVEN_WALK_BAIL_MARGIN = 4

-- os.clock costs about 30ns, so the search loop consults its time budget once per
-- batch of volumes instead of after every volume. The worst-case budget overrun
-- is one batch's worth of work (a few microseconds).
local SEARCH_CLOCK_CHECK_VOLUME_INTERVAL = 4

-- These select which voxel-key component partitionVoxelKeys compares when a
-- splitting volume divides its key slice, picked as the volume's longest axis.
local AXIS_X = 1
local AXIS_Y = 2
local AXIS_Z = 3

-- These are hoisted from Frustum and VoxelGrid so the hot loops read upvalues
-- instead of module table fields.
local BUCKET_STRADDLING = Frustum.BUCKET_STRADDLING
local BUCKET_CULLED = Frustum.BUCKET_CULLED
local BUCKET_INSIDE = Frustum.BUCKET_INSIDE
local COARSE_VOXEL_SIZE = VoxelGrid.COARSE_VOXEL_SIZE

local VisibilitySearch = {}
VisibilitySearch.__index = VisibilitySearch

type VisibilitySearchProto = {
	_config: Config.Config,
	_grid: VoxelGrid.VoxelGrid,
	_motion: CameraMotion.CameraMotion,
	_visibilityCache: VisibilityCache.VisibilityCache,
	_perfMetrics: types.PerfMetrics,

	_searchVoxelKeys: { types.VoxelKey },
	-- This is a scratch list for the proof walk's expired voxels. It's only
	-- ever read within the searchVolume call that filled it.
	_unprovenVoxelKeys: { types.VoxelKey },
	_volumesToCheck: { number },
	_volumesToCheckSize: number,
	_volumeRotationCounter: number,
	_visibleVoxelKeys: { types.VoxelKey },
	_visibleVoxelCount: number,
	_pendingVoxelKeys: { types.VoxelKey },
	_pendingVoxelDistances: { number },
}

export type VisibilitySearch = typeof(setmetatable({} :: VisibilitySearchProto, VisibilitySearch))

--[[
	Builds the search with empty buffers over the given grid, motion tracker,
	and caches.
]]
function VisibilitySearch.new(
	config: Config.Config,
	grid: VoxelGrid.VoxelGrid,
	motion: CameraMotion.CameraMotion,
	visibilityCache: VisibilityCache.VisibilityCache,
	perfMetrics: types.PerfMetrics
): VisibilitySearch
	local self = setmetatable({
		_config = config,
		_grid = grid,
		_motion = motion,
		_visibilityCache = visibilityCache,
		_perfMetrics = perfMetrics,
		_searchVoxelKeys = {},
		_unprovenVoxelKeys = {},
		_volumesToCheck = tableCreate(64),
		_volumesToCheckSize = 0,
		_volumeRotationCounter = 0,
		_visibleVoxelKeys = {},
		_visibleVoxelCount = 0,
		_pendingVoxelKeys = {},
		_pendingVoxelDistances = {},
	}, VisibilitySearch)

	return self
end

if _G.__DEV__ then
	--[[
		This is a dev-only gizmo that draws the wireframe of a voxel-space box
		in world space when _G.__VISUALIZE__ is on. Release builds strip this
		function and every call site.
	]]
	function VisibilitySearch.drawBox(
		self: VisibilitySearch,
		color: Color3,
		transparency: number,
		x0: number,
		y0: number,
		z0: number,
		x1: number,
		y1: number,
		z1: number
	)
		if not _G.__VISUALIZE__ then
			return
		end
		local voxelSize = self._config.voxelSize
		local x0World, y0World, z0World = x0 * voxelSize, y0 * voxelSize, z0 * voxelSize
		local x1World, y1World, z1World = x1 * voxelSize, y1 * voxelSize, z1 * voxelSize

		local cf = CFrame.new((x0World + x1World) / 2, (y0World + y1World) / 2, (z0World + z1World) / 2)
		local size = Vector3.new(math.abs(x0World - x1World), math.abs(y0World - y1World), math.abs(z0World - z1World))
			- (Vector3.one * 2)

		Gizmo.setColor3(color)
		Gizmo.setTransparency(transparency)
		Gizmo.drawWireBox(cf, size)
	end
end

--[[
	Accumulates visible voxels unsorted (an O(1) append).
	Ingest:sortVisibleVoxelKeys orders the whole batch closest-first once the search finishes.

	We don't dedupe because the search volumes partition space, so a voxel is only
	ever added once per frame, and any object that spans several voxels is deduped
	downstream by objectData.lastCheckClock during ingest.
]]
function VisibilitySearch.addVoxelKeyToVisible(self: VisibilitySearch, voxelKey: types.VoxelKey)
	local count = self._visibleVoxelCount + 1
	self._visibleVoxelCount = count
	self._pendingVoxelKeys[count] = voxelKey
end

--[[
	Every voxel in a fully-inside bucket is visible with no per-voxel work.
	Reading the live key list also picks up voxels added since the bucket was
	proven (the verdict is about the bucket's box, not its contents).
]]
function VisibilitySearch.appendWholeBucketToVisible(
	self: VisibilitySearch,
	bucket: { types.VoxelKey },
	bx0: number,
	by0: number,
	bz0: number
)
	local visibleCount = self._visibleVoxelCount
	local bucketSize = #bucket
	tableMove(bucket, 1, bucketSize, visibleCount + 1, self._pendingVoxelKeys)
	self._visibleVoxelCount = visibleCount + bucketSize

	if _G.__DEV__ then
		self:drawBox(
			Color3.new(0, 1, 0),
			0,
			bx0,
			by0,
			bz0,
			bx0 + COARSE_VOXEL_SIZE,
			by0 + COARSE_VOXEL_SIZE,
			bz0 + COARSE_VOXEL_SIZE
		)
	end
end

--[[
	Reorders buffer[lo..hi] in place so every key whose coordinate on the chosen
	axis is below splitCoord comes first. Returns mid, the first index of the
	high group, so buffer[lo..mid-1] are below splitCoord and buffer[mid..hi]
	are at or above it. An empty range (hi < lo) returns lo. This is a Lomuto
	partition, and the order within each group doesn't matter since the visible
	batch is sorted later.
]]
local function partitionVoxelKeys(
	buffer: { types.VoxelKey },
	lo: number,
	hi: number,
	axis: number,
	splitCoord: number
): number
	local mid = lo
	if axis == AXIS_X then
		for i = lo, hi do
			local k = buffer[i]
			if k.X < splitCoord then
				buffer[i], buffer[mid] = buffer[mid], buffer[i]
				mid += 1
			end
		end
	elseif axis == AXIS_Y then
		for i = lo, hi do
			local k = buffer[i]
			if k.Y < splitCoord then
				buffer[i], buffer[mid] = buffer[mid], buffer[i]
				mid += 1
			end
		end
	else
		for i = lo, hi do
			local k = buffer[i]
			if k.Z < splitCoord then
				buffer[i], buffer[mid] = buffer[mid], buffer[i]
				mid += 1
			end
		end
	end
	return mid
end

--[[
	Appends one volume onto the flat stack. A volume is 6 bounds, its [lo, hi]
	slice of _searchVoxelKeys, the mask of frustum planes it must still test,
	and the min slack its ancestors proved against the planes masked out (so
	stamps written inside this volume stay bounded by every plane, tested or not).
]]
function VisibilitySearch.pushVolume(
	self: VisibilitySearch,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	lo: number,
	hi: number,
	planeMask: number,
	inheritedSlack: number
)
	local volumesToCheck = self._volumesToCheck
	local base = self._volumesToCheckSize
	volumesToCheck[base + 1] = x0
	volumesToCheck[base + 2] = y0
	volumesToCheck[base + 3] = z0
	volumesToCheck[base + 4] = x1
	volumesToCheck[base + 5] = y1
	volumesToCheck[base + 6] = z1
	volumesToCheck[base + 7] = lo
	volumesToCheck[base + 8] = hi
	volumesToCheck[base + 9] = planeMask
	volumesToCheck[base + 10] = inheritedSlack
	self._volumesToCheckSize = base + 10
end

--[[
	Resolves every occupied coarse bucket the half-open box [x0,x1) x [y0,y1) x
	[z0,z1) overlaps, cheapest proof first. A bucket with a still-valid cached
	verdict costs two comparisons, where culled buckets are skipped outright
	and fully-inside buckets bulk-append their voxel keys to the visible set.
	Otherwise the bucket's full box is classified against the frustum, and a
	provable verdict (culled or fully inside) is cached with the camera-motion
	clearance that keeps it true. Only straddling buckets fill _searchVoxelKeys
	and push a root search volume owning their contiguous slice of keys, for
	the budgeted volume loop to subdivide. The scan walks just the coarse
	buckets the box overlaps, clamped to the occupied bounding box (without the
	clamp, empty-space scanning grows cubically with the render distance).
	Returns how many keys were seeded.

	The box must contain the frustum (the caller passes the frustum's own
	AABB). Fully-inside buckets append their keys with no per-key bounds
	filtering, which is sound only because inside the frustum implies inside
	the box.
]]
function VisibilitySearch.seedSearchVolumes(
	self: VisibilitySearch,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	local grid = self._grid
	local motion = self._motion
	local coarseVoxels = grid._coarseVoxels
	local searchVoxelKeys = self._searchVoxelKeys
	local bucketVerdicts = self._visibilityCache._bucketVerdicts
	local accumT, accumR, accumF = motion._accumT, motion._accumR, motion._accumF
	-- The side plane positions are the camera position in voxel coordinates.
	local cameraPosVoxels = frustumPlanes[1]
	local count = 0

	if grid._coarseBucketCount == 0 then
		return 0
	end
	if grid._coarseBoundsDirty then
		grid:recomputeCoarseBounds()
	end

	-- We use (x1 - 1) // COARSE_VOXEL_SIZE so a box ending exactly on a bucket
	-- boundary doesn't reach into the empty bucket just past its edge.
	local cx0 = math.max(x0 // COARSE_VOXEL_SIZE, grid._coarseMinX)
	local cx1 = math.min((x1 - 1) // COARSE_VOXEL_SIZE, grid._coarseMaxX)
	local cy0 = math.max(y0 // COARSE_VOXEL_SIZE, grid._coarseMinY)
	local cy1 = math.min((y1 - 1) // COARSE_VOXEL_SIZE, grid._coarseMaxY)
	local cz0 = math.max(z0 // COARSE_VOXEL_SIZE, grid._coarseMinZ)
	local cz1 = math.min((z1 - 1) // COARSE_VOXEL_SIZE, grid._coarseMaxZ)

	for cx = cx0, cx1 do
		local bx0 = cx * COARSE_VOXEL_SIZE
		local interiorX = bx0 >= x0 and bx0 + COARSE_VOXEL_SIZE <= x1
		for cy = cy0, cy1 do
			local by0 = cy * COARSE_VOXEL_SIZE
			local interiorXY = interiorX and by0 >= y0 and by0 + COARSE_VOXEL_SIZE <= y1
			for cz = cz0, cz1 do
				local coarseKey = Vector3.new(cx, cy, cz)
				local bucket = coarseVoxels[coarseKey]
				if not bucket then
					continue
				end

				local bz0 = cz * COARSE_VOXEL_SIZE

				local verdict = bucketVerdicts[coarseKey]
				if verdict then
					-- Trust the cached verdict while the camera motion since its
					-- proof stays within the clearance the proof established. The
					-- check is inclusive, like the voxel proofs, so a zero-clearance
					-- verdict still holds while the camera is perfectly still.
					local m = accumT + accumR * verdict.armFactor
					if m <= verdict.sideExpiry and m + accumF <= verdict.farExpiry then
						if verdict.state == BUCKET_INSIDE then
							self:appendWholeBucketToVisible(bucket, bx0, by0, bz0)
						end
						-- BUCKET_CULLED reaches here with nothing to do. The
						-- bucket is provably still outside, so nothing is seeded.
						continue
					end
				end

				-- There's no valid verdict, so classify the bucket's full box. It
				-- must be the unclipped box so the cached verdict stays true as
				-- the query bounds move with the camera.
				local state, straddledMask, sideSlack, farSlack, margin, rejectedByFar = Frustum.classifyBucket(
					frustumPlanes,
					bx0,
					by0,
					bz0,
					bx0 + COARSE_VOXEL_SIZE,
					by0 + COARSE_VOXEL_SIZE,
					bz0 + COARSE_VOXEL_SIZE
				)

				if state ~= BUCKET_STRADDLING then
					-- This is a provable verdict, so cache it with its clearances.
					-- The arm covers every point of the bucket's box (the center
					-- distance plus the half diagonal) and is inflated by the
					-- governing clearance so the rotation debit stays sound even
					-- as translation carries the bucket farther from the camera
					-- while the verdict lives. Bucket clearances aren't capped
					-- like voxel proof slacks. The verdicts live in f64 table
					-- fields, so there's no packing precision to guard, and a
					-- longer-lived verdict is pure win at the bucket layer.
					local arm = vectorMagnitude(
						Vector3.new(
							bx0 + COARSE_VOXEL_SIZE * 0.5,
							by0 + COARSE_VOXEL_SIZE * 0.5,
							bz0 + COARSE_VOXEL_SIZE * 0.5
						) - cameraPosVoxels
					) + BUCKET_HALF_DIAGONAL

					local armFactor, sideExpiry, farExpiry
					if state == BUCKET_CULLED then
						local shavedMargin = math.max(margin - SLACK_SAFETY, 0)
						armFactor = arm + shavedMargin
						local m0 = accumT + accumR * armFactor
						if rejectedByFar then
							-- Only render distance changes (and camera motion) can
							-- bring a far-culled bucket back inside.
							sideExpiry = math.huge
							farExpiry = m0 + accumF + shavedMargin
						else
							-- A side-culled bucket is culled at any render
							-- distance, so far-plane breathing never re-proves it.
							sideExpiry = m0 + shavedMargin
							farExpiry = math.huge
						end
					else
						local shavedSide = math.max(sideSlack - SLACK_SAFETY, 0)
						local shavedFar = math.max(farSlack - SLACK_SAFETY, 0)
						armFactor = arm + math.min(shavedSide, shavedFar)
						local m0 = accumT + accumR * armFactor
						sideExpiry = m0 + shavedSide
						farExpiry = m0 + accumF + shavedFar

						self:appendWholeBucketToVisible(bucket, bx0, by0, bz0)
					end

					if verdict then
						-- Reuse the record, so each bucket allocates at most once.
						verdict.state = state
						verdict.armFactor = armFactor
						verdict.sideExpiry = sideExpiry
						verdict.farExpiry = farExpiry
					else
						bucketVerdicts[coarseKey] = {
							state = state,
							armFactor = armFactor,
							sideExpiry = sideExpiry,
							farExpiry = farExpiry,
						}
					end
					continue
				end

				-- This bucket straddles, so there's no cacheable verdict and its
				-- keys go to the subdivision search.
				if verdict then
					bucketVerdicts[coarseKey] = nil
				end

				local lo = count + 1

				-- A bucket sitting fully inside the box needs no per-key filtering.
				if interiorXY and bz0 >= z0 and bz0 + COARSE_VOXEL_SIZE <= z1 then
					local bucketSize = #bucket
					tableMove(bucket, 1, bucketSize, count + 1, searchVoxelKeys)
					count += bucketSize
				else
					for i = 1, #bucket do
						local voxelKey = bucket[i]
						local kx, ky, kz = voxelKey.X, voxelKey.Y, voxelKey.Z
						if kx >= x0 and kx < x1 and ky >= y0 and ky < y1 and kz >= z0 and kz < z1 then
							count += 1
							searchVoxelKeys[count] = voxelKey
						end
					end
				end

				if count >= lo then
					-- The bucket box clipped to the query bounds still bounds every
					-- key in the slice, and a tighter box subdivides less. The root
					-- volume continues from the classification's partial proof.
					-- Only the straddled planes need re-testing, and the min slack
					-- of the planes the box is already inside of travels with it.
					self:pushVolume(
						math.max(bx0, x0),
						math.max(by0, y0),
						math.max(bz0, z0),
						math.min(bx0 + COARSE_VOXEL_SIZE, x1),
						math.min(by0 + COARSE_VOXEL_SIZE, y1),
						math.min(bz0 + COARSE_VOXEL_SIZE, z1),
						lo,
						count,
						straddledMask,
						math.min(sideSlack, farSlack)
					)
				end
			end
		end
	end

	return count
end

--[[
	Clamps the slack a voxel proof may store. The slack is capped at SLACK_CAP
	(bounding the proof's arm inflation and how stale it can grow), then shaved
	by SLACK_SAFETY so float noise can only expire the proof sooner, never later.
]]
local function shaveProofSlack(slack: number): number
	local shaved = math.min(slack, SLACK_CAP) - SLACK_SAFETY
	return if shaved < 0 then 0 else shaved
end

--[[
	Resolves one voxel's visibility. It trusts a still-valid proof of either
	verdict, and otherwise frustum-tests its cell and stamps the fresh proof.
	Split children that land on a single voxel come here directly instead of
	taking a stack round-trip through searchVolume. voxelKey is the cell's own
	key, so its components equal (x0, y0, z0). Callers pass both because each
	already has both forms on hand.
]]
function VisibilitySearch.searchSingleVoxel(
	self: VisibilitySearch,
	accumTF: number,
	accumR: number,
	frustumPlanes: { Vector3 },
	planeMask: number,
	inheritedSlack: number,
	x0: number,
	y0: number,
	z0: number,
	voxelKey: types.VoxelKey
)
	local voxelProofs = self._visibilityCache._voxelProofs

	local proof = voxelProofs[voxelKey]
	local needsProof = true
	if proof then
		local m = accumTF + accumR * proof.Z
		if m <= proof.Y then
			-- The cell is provably still outside the frustum.
			return
		end
		-- Landing above the visible expiry means the proof expired in both directions.
		needsProof = m > proof.X
	end

	if needsProof then
		local isInside, _straddledMask, boxSlack, exitSlack =
			Frustum.isBoxInFrustum(frustumPlanes, planeMask, x0, y0, z0, x0 + 1, y0 + 1, z0 + 1)

		-- Either verdict charges rotation at this cell's own arm, which is the
		-- center's distance from the camera plus the half diagonal that covers
		-- the cell, plus the stored slack (translation can carry the camera
		-- that much farther while the proof lives).
		local armBase = vectorMagnitude(voxelKey + VOXEL_CENTER_OFFSET - frustumPlanes[1]) + VOXEL_HALF_DIAGONAL

		if not isInside then
			-- Stamp the culled proof with the rejection margin. Overwriting the
			-- record also drops any stale visible expiry, so the budget
			-- fallback can't resurrect it.
			local shaved = shaveProofSlack(boxSlack)
			local armFactor = armBase + shaved
			voxelProofs[voxelKey] = Vector3.new(-1, accumTF + accumR * armFactor + shaved, armFactor)
			return
		end

		-- The proof holds until any plane could sweep past the cell. Tested
		-- planes the cell is inside of contribute boxSlack, masked-out planes
		-- contribute the slack inherited from the ancestors that were inside
		-- them, and straddled planes contribute their measured exit clearance.
		local slack = if boxSlack < inheritedSlack then boxSlack else inheritedSlack
		if exitSlack < slack then
			slack = exitSlack
		end
		local shaved = shaveProofSlack(slack)
		local armFactor = armBase + shaved
		voxelProofs[voxelKey] = Vector3.new(accumTF + accumR * armFactor + shaved, -1, armFactor)
	end

	-- This voxel is visible, either from a still-valid proof or fresh verification.
	local count = self._visibleVoxelCount + 1
	self._visibleVoxelCount = count
	self._pendingVoxelKeys[count] = voxelKey

	if _G.__DEV__ then
		self:drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x0 + 1, y0 + 1, z0 + 1)
	end
end

--[[
	Resolves one volume from the search stack. The volume owns the occupied
	voxel keys in _searchVoxelKeys[lo..hi]. The buffer was seeded once per
	bucket at the root and is partitioned in place as volumes split, so there
	is nothing to gather here. A volume whose slice survives the proof walk is
	done on the spot. Otherwise it's box-tested and, when straddling, split in
	two with its slice partitioned between the children.
]]
function VisibilitySearch.searchVolume(
	self: VisibilitySearch,
	accumTF: number,
	accumR: number,
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	lo: number,
	hi: number,
	planeMask: number,
	inheritedSlack: number
)
	if hi < lo then
		return
	end

	local voxelProofs = self._visibilityCache._voxelProofs
	local searchVoxelKeys = self._searchVoxelKeys

	-- This is the special case for a single-voxel volume (a bucket clipped down to one cell).
	if x1 - x0 == 1 and y1 - y0 == 1 and z1 - z0 == 1 then
		self:searchSingleVoxel(
			accumTF,
			accumR,
			frustumPlanes,
			planeMask,
			inheritedSlack,
			x0,
			y0,
			z0,
			searchVoxelKeys[lo]
		)
		return
	end

	-- Walk the slice's proofs. Valid-visible voxels accumulate into the visible
	-- set, valid-culled ones are skipped, and unproven ones collect into a
	-- scratch list. While unproven voxels stay rare relative to proven ones,
	-- the walk keeps its partial run and re-tests just those cells directly, so
	-- a few expired proofs cost a few cell tests instead of re-subdividing the
	-- whole volume. Once unproven voxels outnumber proven ones by the bail
	-- margin (a cold or mass-expired slice), the partial run is dropped and the
	-- box test below takes over, since subdivision proves whole boxes at a
	-- fraction of a test per voxel. This relies on searchVolume running
	-- serially (it does today). Parallel volume workers would race on the
	-- shared visible set here.
	debug.profilebegin("walkVoxelProofs")
	local pendingVoxelKeys = self._pendingVoxelKeys
	local unprovenVoxelKeys = self._unprovenVoxelKeys
	local startCount = self._visibleVoxelCount
	local visibleCount = startCount
	local provenCount = 0
	local unprovenCount = 0
	local bailed = false
	for i = lo, hi do
		local voxelKey = searchVoxelKeys[i]
		local proof = voxelProofs[voxelKey]
		if proof then
			local m = accumTF + accumR * proof.Z
			if m <= proof.X then
				visibleCount += 1
				pendingVoxelKeys[visibleCount] = voxelKey
				provenCount += 1
			elseif m <= proof.Y then
				-- It's provably still culled, so skip it silently.
				provenCount += 1
			else
				-- The proof expired in both directions.
				unprovenCount += 1
				if unprovenCount > provenCount + UNPROVEN_WALK_BAIL_MARGIN then
					bailed = true
					break
				end
				unprovenVoxelKeys[unprovenCount] = voxelKey
			end
		else
			unprovenCount += 1
			if unprovenCount > provenCount + UNPROVEN_WALK_BAIL_MARGIN then
				bailed = true
				break
			end
			unprovenVoxelKeys[unprovenCount] = voxelKey
		end
	end
	debug.profileend()

	if not bailed then
		-- Keep the walk's appends and resolve the stragglers cell by cell. The
		-- volume's own plane mask and inherited slack are sound for any cell it
		-- contains (the mask only skips planes that provably cannot reject, and
		-- the inherited slack only shrinks down the tree).
		self._visibleVoxelCount = visibleCount
		for i = 1, unprovenCount do
			local voxelKey = unprovenVoxelKeys[i]
			self:searchSingleVoxel(
				accumTF,
				accumR,
				frustumPlanes,
				planeMask,
				inheritedSlack,
				voxelKey.X,
				voxelKey.Y,
				voxelKey.Z,
				voxelKey
			)
		end
		if _G.__DEV__ and unprovenCount == 0 and visibleCount - startCount == hi - lo + 1 then
			self:drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		end
		return
	end

	local isInside, straddledMask, boxSlack = Frustum.isBoxInFrustum(frustumPlanes, planeMask, x0, y0, z0, x1, y1, z1)

	if not isInside then
		-- Every voxel inherits the box's rejection margin (each sits at least as
		-- far outside the rejecting plane as the box does), so stamp them all
		-- provably culled, each charged at its own arm. Overwriting the records
		-- also drops any stale visible expiries, so the budget fallback can't
		-- resurrect them.
		debug.profilebegin("stampBoxCulled")
		local shaved = shaveProofSlack(boxSlack)
		local centerOffset = VOXEL_CENTER_OFFSET - frustumPlanes[1]
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			local armFactor = vectorMagnitude(voxelKey + centerOffset) + VOXEL_HALF_DIAGONAL + shaved
			voxelProofs[voxelKey] = Vector3.new(-1, accumTF + accumR * armFactor + shaved, armFactor)
		end
		debug.profileend()
		return
	end

	-- A box is bounded by its ancestors' planes as well as its own tested ones,
	-- so the slack that proofs within this box may claim is the min of both.
	local effectiveSlack = if boxSlack < inheritedSlack then boxSlack else inheritedSlack

	-- If the box straddles no plane it is entirely inside, so we know all voxels
	-- contained inside are in the frustum and we can process them now and not split further.
	if straddledMask == 0 then
		debug.profilebegin("isCompletelyInside")
		-- Every voxel inherits the box's slack, since each is contained in the
		-- box and so sits at least as far inside every plane as the box does.
		-- The rotation debit is still charged per voxel at its own arm.
		local shaved = shaveProofSlack(effectiveSlack)
		local centerOffset = VOXEL_CENTER_OFFSET - frustumPlanes[1]
		local count = self._visibleVoxelCount
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			local armFactor = vectorMagnitude(voxelKey + centerOffset) + VOXEL_HALF_DIAGONAL + shaved
			voxelProofs[voxelKey] = Vector3.new(accumTF + accumR * armFactor + shaved, -1, armFactor)
			count += 1
			pendingVoxelKeys[count] = voxelKey
		end
		self._visibleVoxelCount = count
		debug.profileend()
		if _G.__DEV__ then
			self:drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		end
		return
	end

	local lengthX = x1 - x0
	local lengthY = y1 - y0
	local lengthZ = z1 - z0

	-- Split along the axis with the greatest length into two halves A and B.
	local axis, splitCoord
	local ax0, ay0, az0, ax1, ay1, az1
	local bx0, by0, bz0, bx1, by1, bz1
	if lengthX >= lengthY and lengthX >= lengthZ then
		axis = AXIS_X
		splitCoord = (x0 + x1) // 2
		ax0, ay0, az0, ax1, ay1, az1 = x0, y0, z0, splitCoord, y1, z1
		bx0, by0, bz0, bx1, by1, bz1 = splitCoord, y0, z0, x1, y1, z1
	elseif lengthY >= lengthX and lengthY >= lengthZ then
		axis = AXIS_Y
		splitCoord = (y0 + y1) // 2
		ax0, ay0, az0, ax1, ay1, az1 = x0, y0, z0, x1, splitCoord, z1
		bx0, by0, bz0, bx1, by1, bz1 = x0, splitCoord, z0, x1, y1, z1
	else
		axis = AXIS_Z
		splitCoord = (z0 + z1) // 2
		ax0, ay0, az0, ax1, ay1, az1 = x0, y0, z0, x1, y1, splitCoord
		bx0, by0, bz0, bx1, by1, bz1 = x0, y0, splitCoord, x1, y1, z1
	end

	-- Partition this volume's slice around the split plane. Keys below splitCoord (the
	-- low half A) move to [lo, mid-1], and the rest (the high half B) to [mid, hi]. The two
	-- child slices are disjoint and tile this one, so the search can keep partitioning
	-- each child's own range without disturbing any other volume on the stack.
	-- Children only re-test the planes this box straddled.
	local mid = partitionVoxelKeys(searchVoxelKeys, lo, hi, axis, splitCoord)
	local aHasVoxels = mid - 1 >= lo
	local bHasVoxels = hi >= mid

	-- A child that landed on a single voxel is resolved right here rather than
	-- paying a push, a pop, and another searchVolume call for one cell.
	if aHasVoxels and ax1 - ax0 == 1 and ay1 - ay0 == 1 and az1 - az0 == 1 then
		self:searchSingleVoxel(
			accumTF,
			accumR,
			frustumPlanes,
			straddledMask,
			effectiveSlack,
			ax0,
			ay0,
			az0,
			searchVoxelKeys[lo]
		)
		aHasVoxels = false
	end
	if bHasVoxels and bx1 - bx0 == 1 and by1 - by0 == 1 and bz1 - bz0 == 1 then
		self:searchSingleVoxel(
			accumTF,
			accumR,
			frustumPlanes,
			straddledMask,
			effectiveSlack,
			bx0,
			by0,
			bz0,
			searchVoxelKeys[mid]
		)
		bHasVoxels = false
	end

	-- The stack is LIFO, so the half pushed last is searched first. The rotation
	-- counter only advances once per frame (in run), so the whole frame splits in
	-- one order and the next frame flips it, giving each side its turn at the
	-- front of the budget. Empty halves hold no occupied voxels, so we skip
	-- pushing them.
	if self._volumeRotationCounter % 2 == 0 then
		if aHasVoxels then
			self:pushVolume(ax0, ay0, az0, ax1, ay1, az1, lo, mid - 1, straddledMask, effectiveSlack)
		end
		if bHasVoxels then
			self:pushVolume(bx0, by0, bz0, bx1, by1, bz1, mid, hi, straddledMask, effectiveSlack)
		end
	else
		if bHasVoxels then
			self:pushVolume(bx0, by0, bz0, bx1, by1, bz1, mid, hi, straddledMask, effectiveSlack)
		end
		if aHasVoxels then
			self:pushVolume(ax0, ay0, az0, ax1, ay1, az1, lo, mid - 1, straddledMask, effectiveSlack)
		end
	end
end

--[[
	This is the budget fallback for when search time runs out with volumes
	still on the stack. Each leftover volume still owns an intact [lo, hi]
	slice of the search buffer (a volume is only partitioned when it is popped,
	and these were never popped), so we just re-mark every key whose last proof
	found it visible. That means any proof carrying a visible expiry, even an
	expired one, because with the budget gone a stale verdict beats dropping
	the voxel for a frame.
]]
function VisibilitySearch.reuseCachedVisibilityForRemainingVolumes(self: VisibilitySearch)
	debug.profilebegin("reuseCachedVisibilityForRemainingVolumes")
	local voxelProofs = self._visibilityCache._voxelProofs
	local searchVoxelKeys = self._searchVoxelKeys

	local skipped = 0

	local volumesToCheck = self._volumesToCheck
	for base = 0, self._volumesToCheckSize - 1, 10 do
		local lo, hi = volumesToCheck[base + 7], volumesToCheck[base + 8]
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			skipped += 1
			local proof = voxelProofs[voxelKey]
			if proof and proof.X >= 0 then
				self:addVoxelKeyToVisible(voxelKey)
			end
		end
	end

	local perfMetrics = self._perfMetrics
	perfMetrics._skippedSearch[perfMetrics._skippedFramesCursor] = skipped
	debug.profileend()
end

--[[
	Runs one frame's whole search pass. It seeds root volumes from the coarse
	buckets, rotates which bucket volume gets the front of the budget, then
	subdivides within the search time budget, falling back to cached verdicts
	for whatever the budget can't reach. The visible set this accumulates is
	unsorted, and Ingest:sortVisibleVoxelKeys orders it afterward.
]]
function VisibilitySearch.run(self: VisibilitySearch, now: number)
	local config = self._config
	local searchTimeBudget = config.searchTimeBudget
	local voxelSize = config.voxelSize
	local renderDistance = config.renderDistance

	local frustumPlanes, minBound, maxBound = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

	local minX = minBound.X
	local minY = minBound.Y
	local minZ = minBound.Z
	-- The bounds arrive as inclusive voxel indices, so the max side gains one to
	-- form the half-open box that seedSearchVolumes expects.
	local maxX = maxBound.X + 1
	local maxY = maxBound.Y + 1
	local maxZ = maxBound.Z + 1

	local volumesToCheck = self._volumesToCheck
	self._volumesToCheckSize = 0

	-- Seed the search. Buckets with a valid cached verdict (or a freshly provable
	-- one) are resolved on the spot, and each remaining straddling bucket pushes
	-- one root volume owning its contiguous slice of the key buffer. The search
	-- reads and partitions this buffer in place from here on, so the sparse voxel
	-- set is never rescanned per box.
	debug.profilebegin("seedSearchVolumes")
	self:seedSearchVolumes(frustumPlanes, minX, minY, minZ, maxX, maxY, maxZ)

	-- Rotate which bucket volume sits on top (the stack is LIFO, so the top is
	-- searched first), ensuring every region gets its turn at the front of the
	-- budget when the search can't finish a whole frame.
	local volumeCount = self._volumesToCheckSize // 10
	if volumeCount > 1 then
		local chosenBase = (self._volumeRotationCounter % volumeCount) * 10
		local topBase = (volumeCount - 1) * 10
		if chosenBase ~= topBase then
			for k = 1, 10 do
				volumesToCheck[chosenBase + k], volumesToCheck[topBase + k] =
					volumesToCheck[topBase + k], volumesToCheck[chosenBase + k]
			end
		end
	end
	self._volumeRotationCounter += 1
	debug.profileend()

	debug.profilebegin("searchVolumes")
	-- These are hoisted once per frame. Every proof comparison charges translation
	-- and render distance change at full weight, and rotation at the proof's arm.
	local motion = self._motion
	local accumTF = motion._accumT + motion._accumF
	local accumR = motion._accumR
	local volumesSinceClockCheck = 0
	while self._volumesToCheckSize > 0 do
		-- Pop the top volume, which is 10 numbers covering its 6 bounds, its
		-- [lo, hi] slice, its plane mask, and its inherited slack. We read
		-- everything into locals before shrinking the stack so searchVolume can
		-- reuse the just-freed slots for any child volumes it pushes.
		local n = self._volumesToCheckSize
		local x0 = volumesToCheck[n - 9]
		local y0 = volumesToCheck[n - 8]
		local z0 = volumesToCheck[n - 7]
		local x1 = volumesToCheck[n - 6]
		local y1 = volumesToCheck[n - 5]
		local z1 = volumesToCheck[n - 4]
		local lo = volumesToCheck[n - 3]
		local hi = volumesToCheck[n - 2]
		local planeMask = volumesToCheck[n - 1]
		local inheritedSlack = volumesToCheck[n]
		self._volumesToCheckSize = n - 10

		self:searchVolume(accumTF, accumR, frustumPlanes, x0, y0, z0, x1, y1, z1, lo, hi, planeMask, inheritedSlack)

		volumesSinceClockCheck += 1
		if volumesSinceClockCheck >= SEARCH_CLOCK_CHECK_VOLUME_INTERVAL then
			volumesSinceClockCheck = 0
			if os.clock() - now >= searchTimeBudget then
				self:reuseCachedVisibilityForRemainingVolumes()
				break
			end
		end
	end
	self._perfMetrics._searchDuration = os.clock() - now
	debug.profileend()
end

--[[
	Rebuilds the cleared-without-shrinking buffers at their current occupancy
	so a one-off burst doesn't leave permanently oversized arrays behind.
]]
function VisibilitySearch.resizeBuffers(self: VisibilitySearch)
	local visibleVoxelCount = self._visibleVoxelCount

	local visibleVoxelKeys = tableCreate(visibleVoxelCount)
	tableMove(self._visibleVoxelKeys, 1, visibleVoxelCount, 1, visibleVoxelKeys)
	self._visibleVoxelKeys = visibleVoxelKeys

	local pendingVoxelKeys = tableCreate(visibleVoxelCount)
	tableMove(self._pendingVoxelKeys, 1, visibleVoxelCount, 1, pendingVoxelKeys)
	self._pendingVoxelKeys = pendingVoxelKeys

	self._pendingVoxelDistances = tableCreate(visibleVoxelCount)

	local volumesSize = self._volumesToCheckSize
	local volumesToCheck = tableCreate(volumesSize)
	tableMove(self._volumesToCheck, 1, volumesSize, 1, volumesToCheck)
	self._volumesToCheck = volumesToCheck

	-- Any volume still on the stack owns a [lo, hi] slice of the seed buffer,
	-- so the rebuild keeps every slot a surviving slice can reach. With the
	-- stack empty (the steady state between frames) this rebuilds the buffer
	-- empty, and the next seed refills it from scratch.
	local keptSeedKeys = 0
	for base = 0, volumesSize - 1, 10 do
		local hi = volumesToCheck[base + 8]
		if hi > keptSeedKeys then
			keptSeedKeys = hi
		end
	end
	local searchVoxelKeys = tableCreate(keptSeedKeys)
	tableMove(self._searchVoxelKeys, 1, keptSeedKeys, 1, searchVoxelKeys)
	self._searchVoxelKeys = searchVoxelKeys

	-- The proof walk's scratch list is only ever read within the call that
	-- filled it, so nothing in it survives the rebuild.
	self._unprovenVoxelKeys = {}
end

--[[
	Clears every search buffer so everything they referenced can be garbage
	collected.
]]
function VisibilitySearch.destroy(self: VisibilitySearch)
	tableClear(self._searchVoxelKeys)
	tableClear(self._unprovenVoxelKeys)
	tableClear(self._visibleVoxelKeys)
	self._visibleVoxelCount = 0
	tableClear(self._pendingVoxelKeys)
	tableClear(self._pendingVoxelDistances)
	tableClear(self._volumesToCheck)
	self._volumesToCheckSize = 0
end

return VisibilitySearch
