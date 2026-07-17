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

	Above all three layers sits a whole-frame replay. The pass is a
	deterministic function of the frustum, the occupied voxel set, the built
	umbrae, and the proof caches, so when every one of those stands
	exactly where the last complete pass left it (no charged camera motion of
	any kind, no cache flush, no occupancy change, no umbra rebuild, and both
	occlusion generations unmoved), run hands back that pass's output instead
	of re-deriving it. Any charged motion at all re-runs the search, so the
	replay is a parked-camera fast path rather than an approximation.

	Occlusion culling threads through the same layers when umbrae exist (see
	OcclusionCulling). Seeding checks each bucket's cached occlusion proof
	before any umbra work, where a hidden proof skips the bucket and a clear
	proof sends it down the pure frustum path, and umbra-tests survivors. A
	fully occluded bucket is skipped with a fresh hidden proof cached, a
	bucket that prunes every umbra caches a clear proof, and a bucket that
	an umbra merely straddles sends its keys to the subdivision search
	carrying the mask of umbrae still in play, whether or not the frustum
	straddles it too (negated when the box arrives unclipped, so the root
	volume inherits the seeding test's verdict instead of repeating it). A
	contested volume either proves itself fully occluded (stamping a hidden
	proof on every voxel in its slice), proves itself fully clear the same
	way (stamping not-occluded proofs slice-wide when its test prunes the
	last umbra), or takes the same proof walk as everything else, where a
	still-valid hidden proof settles a cell as hidden the way a frustum
	proof settles one as culled, and a still-valid not-occluded proof hands
	the cell back to its frustum proof alone. Whatever the walk can't settle
	splits, the same way frustum straddling drives splitting, until children
	either leave every umbra or land on single voxels that get their own
	leaf test and stamp of whichever verdict the test proves. Occlusion runs
	under the same search time budget as the frustum work, since every
	umbra test that lands retires voxels the search would otherwise have to
	resolve, and when the budget expires the leftover volumes take the
	usual cached-verdict fallback, which errs toward visible.
]]

local types = require(script.Parent.types)
local Config = require(script.Parent.Config)
local Frustum = require(script.Parent.Frustum)
local VoxelGrid = require(script.Parent.VoxelGrid)
local CameraMotion = require(script.Parent.CameraMotion)
local OcclusionCulling = require(script.Parent.OcclusionCulling)
local VisibilityCache = require(script.Parent.VisibilityCache)
local CameraCache = require(script.Parent.Utilities.CameraCache)
local Gizmo = if _G.__DEV__ then require(script.Parent.Utilities.Gizmo) else nil :: any

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local vectorAbs = (vector.abs :: any) :: (Vector3 | vector) -> Vector3
local tableCreate = table.create
local tableMove = table.move
local tableClear = table.clear

-- Dotting a componentwise absolute value against this sums its three lanes,
-- which is how the voxel sort gets a manhattan distance in two vector ops.
local VECTOR_ONE = Vector3.one

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

-- This is how far past the frustum's AABB the search can seed a testable box,
-- in voxels. Testable boxes come from coarse buckets overlapping that AABB,
-- and a bucket-aligned box reaches at most one bucket span beyond it. The
-- search owns this value because its seeding geometry decides it, and the
-- facade hands it to OcclusionCulling so the umbra AABBs cover every box the
-- search can ever test.
VisibilitySearch.TESTABLE_REACH_EXPANSION = COARSE_VOXEL_SIZE

-- The slack cap and shave are documented spec (docs/MATH.md section 10), so
-- they're exported for the tests that pin the documented values and the
-- float-safety relationship between the shave and the odometer flush limits.
VisibilitySearch.SLACK_CAP = SLACK_CAP
VisibilitySearch.SLACK_SAFETY = SLACK_SAFETY

type VisibilitySearchProto = {
	_config: Config.Config,
	_grid: VoxelGrid.VoxelGrid,
	_motion: CameraMotion.CameraMotion,
	_visibilityCache: VisibilityCache.VisibilityCache,
	_occlusion: OcclusionCulling.OcclusionCulling,
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
	-- This is the counting sort's tally scratch, reused across frames.
	_voxelDistanceCounts: { number },

	-- These record the state the last complete pass ran against, so run can
	-- hand back that pass's output while every watched input is bit-identical.
	-- The count is how many pending keys the pass accumulated, which still sit
	-- untouched in their slots (only the search writes them, and the buffer
	-- rebuild preserves every occupied slot). A pass the budget truncated
	-- leaned on the stale-verdict fallback, so it never arms the replay.
	_replayReady: boolean,
	_replayAccumT: number,
	_replayAccumR: number,
	_replayAccumF: number,
	_replayFlushCount: number,
	_replayOccupancyGeneration: number,
	_replayBuildCount: number,
	-- The two occlusion generations overlap with the build count today (every
	-- path that bumps either also moves a watched counter), but each is
	-- watched independently so replay soundness assumes nothing about
	-- OcclusionCulling's internal call graph.
	_replayGeneration: number,
	_replayClearGeneration: number,
	-- The occluder cap is watched by value because flipping it re-decides
	-- whether cached occlusion proofs are honored at all, which can change the
	-- output even on frames with zero built umbrae (a proof outlives its
	-- occluder's stay in the frustum).
	_replayMaxOccluders: number,
	_replayVisibleVoxelCount: number,
	_replayOccludedVoxelCount: number,
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
	occlusion: OcclusionCulling.OcclusionCulling,
	perfMetrics: types.PerfMetrics
): VisibilitySearch
	local self = setmetatable({
		_config = config,
		_grid = grid,
		_motion = motion,
		_visibilityCache = visibilityCache,
		_occlusion = occlusion,
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
		_voxelDistanceCounts = {},
		_replayReady = false,
		_replayAccumT = 0,
		_replayAccumR = 0,
		_replayAccumF = 0,
		_replayFlushCount = 0,
		_replayOccupancyGeneration = 0,
		_replayBuildCount = 0,
		_replayGeneration = 0,
		_replayClearGeneration = 0,
		_replayMaxOccluders = 0,
		_replayVisibleVoxelCount = 0,
		_replayOccludedVoxelCount = 0,
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
	sortVisibleVoxelKeys orders the whole batch closest-first once the search finishes.

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
	Resets the visible-voxel accumulator for a fresh frame. Resetting the
	count is enough because the search overwrites slots 1..count from the
	start each frame, so any stale trailing entries in the reused buffers are
	never read.
]]
function VisibilitySearch.clearVisibleVoxels(self: VisibilitySearch)
	self._visibleVoxelCount = 0
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
	the min slack its ancestors proved against the planes masked out (so
	stamps written inside this volume stay bounded by every plane, tested or
	not), and the mask of umbrae that could still occlude it, which arrives
	negated when the seeding already umbra-tested this exact box this frame.
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
	inheritedSlack: number,
	umbraMask: number
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
	volumesToCheck[base + 11] = umbraMask
	self._volumesToCheckSize = base + 11
end

--[[
	Copies the bucket's keys that fall inside the half-open query box into the
	seed buffer and pushes the bucket's root search volume owning that slice,
	clipped to the query bounds (the clipped box still bounds every seeded key,
	and a tighter box subdivides less). Returns the new seeded-key count.
	interior says the bucket already sits entirely inside the query box, the
	caller-computed fact that licenses the unfiltered bulk copy. A bucket
	whose keys all fall outside the box pushes nothing. A nonzero umbraMask is
	the survivor set from this frame's umbra test of the bucket's unclipped
	box, and when the bucket is interior the pushed volume is that exact box,
	so the mask is negated as the signal for searchVolume to inherit the
	verdict (re-testing an identical box against an identical mask in the
	same frame could only repeat it).
]]
function VisibilitySearch.seedBucketVolume(
	self: VisibilitySearch,
	bucket: { types.VoxelKey },
	count: number,
	interior: boolean,
	bx0: number,
	by0: number,
	bz0: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	planeMask: number,
	inheritedSlack: number,
	umbraMask: number
): number
	local searchVoxelKeys = self._searchVoxelKeys
	local lo = count + 1

	if interior then
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
		self:pushVolume(
			math.max(bx0, x0),
			math.max(by0, y0),
			math.max(bz0, z0),
			math.min(bx0 + COARSE_VOXEL_SIZE, x1),
			math.min(by0 + COARSE_VOXEL_SIZE, y1),
			math.min(bz0 + COARSE_VOXEL_SIZE, z1),
			lo,
			count,
			planeMask,
			inheritedSlack,
			if interior and umbraMask ~= 0 then -umbraMask else umbraMask
		)
	end

	return count
end

--[[
	Packs one hidden occlusion proof, valid until the translation odometer
	passes the current reading plus the given allowance, anchored to the live
	occluder generation. Buckets and voxels share this encoding, since
	occlusion charges translation flat with no arm (it depends only on where
	the camera is). The Z component of -1 marks the clear verdict this record
	doesn't carry, and that sentinel is load-bearing: it's what keeps a
	hidden record from satisfying a clear check when the two generations
	happen to collide numerically, since a -1 expiry fails every accumT
	comparison. The decode side is inlined at three hot sites that must all
	read this layout identically: the bucket seeding loop, the leaf test in
	searchSingleVoxel, and the volume proof walk.
]]
function VisibilitySearch.packOccludedProof(self: VisibilitySearch, allowance: number): Vector3
	return Vector3.new(self._motion._accumT + allowance, self._occlusion._generation, -1)
end

--[[
	Packs one clear-side occlusion proof, anchored to the live clear
	generation (which also bumps when the occluder selection gains a member,
	the one event that could falsify a clear-side verdict without touching
	any occluder). The X component of -1 marks the hidden verdict this record
	doesn't carry. Buckets store the strong form (outside every
	umbra built this frame), and voxel records store either that form,
	inherited slice-wide from a volume that pruned its last umbra, or the
	weak not-occluded form measured at the leaf. All three share this
	encoding and guard. The X component of -1 carries the same anti-collision
	duty as packOccludedProof's Z, and the same three inlined decode sites
	read this layout, so any change here must visit all of them.
]]
function VisibilitySearch.packClearProof(self: VisibilitySearch, allowance: number): Vector3
	return Vector3.new(-1, self._occlusion._clearGeneration, self._motion._accumT + allowance)
end

--[[
	Resolves what occlusion can settle about one bucket that is otherwise
	headed into the visible set or the subdivision search. Its unclipped box
	is tested against every umbra built this frame (unclipped so the cached
	proof stays true as the query bounds move with the camera). Returns
	whether the bucket is fully occluded, plus the mask of umbrae still
	contesting it. A fully occluded bucket caches a hidden bucket proof, and
	the caller skips it. A contested bucket comes back with the nonzero
	survivor mask for the caller to seed into the subdivision search. A
	bucket every umbra got pruned from returns a zero mask, since occlusion
	has nothing more to say about it, but it first caches a clear bucket
	proof when a second, margin-measuring pass earns one, so later frames
	can take the pure frustum path without re-testing.
]]
function VisibilitySearch.resolveBucketOcclusion(
	self: VisibilitySearch,
	bucket: { types.VoxelKey },
	coarseKey: types.CoarseVoxelKey,
	bx0: number,
	by0: number,
	bz0: number
): (boolean, number)
	local occlusion = self._occlusion
	local occluded, allowance, prunedMask = occlusion:testBoxOcclusion(
		occlusion._fullUmbraMask,
		bx0,
		by0,
		bz0,
		bx0 + COARSE_VOXEL_SIZE,
		by0 + COARSE_VOXEL_SIZE,
		bz0 + COARSE_VOXEL_SIZE
	)
	if occluded then
		-- A stamp is only worth its write if it can outlive the translation
		-- the camera just did in one frame, so dead-on-arrival proofs are
		-- skipped and the bucket just re-tests next frame. At a still camera
		-- the floor is zero and every stamp qualifies.
		if allowance >= occlusion._motionFloor then
			self._visibilityCache._bucketOcclusionProofs[coarseKey] = self:packOccludedProof(allowance)
		end
		self._perfMetrics._occludedVoxelCount += #bucket
		if _G.__DEV__ then
			self:drawBox(
				Color3.new(1, 0, 0),
				0.5,
				bx0,
				by0,
				bz0,
				bx0 + COARSE_VOXEL_SIZE,
				by0 + COARSE_VOXEL_SIZE,
				bz0 + COARSE_VOXEL_SIZE
			)
		end
		return true, 0
	end
	if prunedMask ~= 0 then
		return false, prunedMask
	end
	-- Every umbra pruned, so the bucket may earn a clear proof. The margins
	-- get measured in a second, ungated pass, paid once per stamp rather
	-- than once per frame, and skipped entirely on frames where the shape
	-- allowance ceiling says no measurement could outlive the motion floor.
	if occlusion._measuresUseful then
		local clearAllowance = occlusion:measureClearAllowance(
			occlusion._fullUmbraMask,
			bx0,
			by0,
			bz0,
			bx0 + COARSE_VOXEL_SIZE,
			by0 + COARSE_VOXEL_SIZE,
			bz0 + COARSE_VOXEL_SIZE
		)
		if clearAllowance > 0 then
			self._visibilityCache._bucketOcclusionProofs[coarseKey] = self:packClearProof(clearAllowance)
		end
	end
	return false, 0
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

	Occlusion resolves before everything else. A bucket with a still-valid
	occlusion proof (the occluder generation matches and the translation
	odometer sits at or under the expiry) skips outright in two comparisons.
	Otherwise any bucket about to contribute voxels is tested against this
	frame's umbrae. A fully occluded bucket caches a proof and skips, and a
	bucket that an umbra merely straddles seeds its keys for the subdivision
	search with the surviving umbra mask, even when it sits fully inside the
	frustum. Such a volume carries an empty frustum plane mask plus a sound
	inherited slack, this frame's measured clearance for a freshly classified
	bucket or the verdict's remaining expiry margin for a cached one.

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
	local bucketVerdicts = self._visibilityCache._bucketVerdicts
	local accumT, accumR, accumF = motion._accumT, motion._accumR, motion._accumF
	-- The side plane positions are the camera position in voxel coordinates.
	local cameraPosVoxels = frustumPlanes[1]
	local count = 0

	local bucketOcclusionProofs = self._visibilityCache._bucketOcclusionProofs
	local umbraCount = self._occlusion._umbraCount
	local occlusionGeneration = self._occlusion._generation
	local clearGeneration = self._occlusion._clearGeneration
	-- When proofs aren't honored (isHonoringProofs explains the policy), the
	-- per-bucket lookup would be a guaranteed miss and gets skipped, keeping
	-- this loop free for places that never tag an occluder.
	local occlusionEnabled = self._occlusion:isHonoringProofs()
	local perfMetrics = self._perfMetrics

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
				-- The bucket sits entirely inside the query box when all three
				-- axes are interior. The bulk key copy and the umbra-mask
				-- inheritance both hang off this one fact, so it's computed
				-- once here and passed down to keep the two in lockstep.
				local interior = interiorXY and bz0 >= z0 and bz0 + COARSE_VOXEL_SIZE <= z1

				-- Occlusion contests this bucket unless a still-valid clear
				-- proof says every umbra misses it.
				local bucketContested = umbraCount > 0

				if occlusionEnabled then
					-- A still-valid occlusion proof settles the bucket before
					-- any umbra work. Occlusion only depends on where the
					-- camera is, so either verdict charges just the
					-- translation odometer, and the generation match
					-- guarantees what the proof was tested against hasn't
					-- changed.
					local occlusionProof = bucketOcclusionProofs[coarseKey]
					if occlusionProof then
						if occlusionProof.Y == occlusionGeneration and accumT <= occlusionProof.X then
							perfMetrics._occludedVoxelCount += #bucket
							if _G.__DEV__ then
								self:drawBox(
									Color3.new(1, 0, 0),
									0.5,
									bx0,
									by0,
									bz0,
									bx0 + COARSE_VOXEL_SIZE,
									by0 + COARSE_VOXEL_SIZE,
									bz0 + COARSE_VOXEL_SIZE
								)
							end
							continue
						elseif occlusionProof.Y == clearGeneration and accumT <= occlusionProof.Z then
							-- The bucket is outside every umbra, so
							-- it takes the pure frustum path, exactly what a
							-- fresh umbra test would conclude.
							bucketContested = false
						end
					end
				end

				local verdict = bucketVerdicts[coarseKey]
				if verdict then
					-- Trust the cached verdict while the camera motion since its
					-- proof stays within the clearance the proof established. The
					-- check is inclusive, like the voxel proofs, so a zero-clearance
					-- verdict still holds while the camera is perfectly still.
					local m = accumT + accumR * verdict.armFactor
					if m <= verdict.sideExpiry and m + accumF <= verdict.farExpiry then
						if verdict.state == BUCKET_INSIDE then
							local survivingMask = 0
							if bucketContested then
								local occludedBucket
								occludedBucket, survivingMask =
									self:resolveBucketOcclusion(bucket, coarseKey, bx0, by0, bz0)
								if occludedBucket then
									continue
								end
							end
							if survivingMask ~= 0 then
								-- Every frustum plane is already proven, so the
								-- contested volume seeded here carries an empty
								-- plane mask, and the verdict's remaining expiry
								-- margin is a sound slack for stamps written
								-- inside it. The stored expiry understates the
								-- proof-time clearance and the charge since then
								-- overstates the plane sweep, so the margin
								-- between them can only understate the clearance
								-- that remains right now.
								count = self:seedBucketVolume(
									bucket,
									count,
									interior,
									bx0,
									by0,
									bz0,
									x0,
									y0,
									z0,
									x1,
									y1,
									z1,
									0,
									math.min(verdict.sideExpiry - m, verdict.farExpiry - m - accumF),
									survivingMask
								)
								continue
							end
							self:appendWholeBucketToVisible(bucket, bx0, by0, bz0)
						end
						-- BUCKET_CULLED reaches here with nothing to do. The
						-- bucket is still outside, so nothing is seeded.
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

						-- The frustum verdict still gets cached below either
						-- way, since it stays true independent of occlusion
						-- and outlives any one occluder. A contested volume
						-- seeded here carries an empty plane mask and this
						-- frame's measured clearance as the inherited slack.
						local appendBucket = true
						if bucketContested then
							local occludedBucket, survivingMask =
								self:resolveBucketOcclusion(bucket, coarseKey, bx0, by0, bz0)
							if occludedBucket then
								appendBucket = false
							elseif survivingMask ~= 0 then
								appendBucket = false
								count = self:seedBucketVolume(
									bucket,
									count,
									interior,
									bx0,
									by0,
									bz0,
									x0,
									y0,
									z0,
									x1,
									y1,
									z1,
									0,
									math.min(sideSlack, farSlack),
									survivingMask
								)
							end
						end
						if appendBucket then
							self:appendWholeBucketToVisible(bucket, bx0, by0, bz0)
						end
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

				-- A straddling bucket seeds either way. Occlusion may still
				-- settle it outright or attach the surviving umbra mask to
				-- the root volume it seeds.
				local survivingMask = 0
				if bucketContested then
					local occludedBucket
					occludedBucket, survivingMask = self:resolveBucketOcclusion(bucket, coarseKey, bx0, by0, bz0)
					if occludedBucket then
						continue
					end
				end

				-- The root volume continues from the classification's partial
				-- proof. Only the straddled planes need re-testing, and the min
				-- slack of the planes the box is already inside of travels with
				-- it.
				count = self:seedBucketVolume(
					bucket,
					count,
					interior,
					bx0,
					by0,
					bz0,
					x0,
					y0,
					z0,
					x1,
					y1,
					z1,
					straddledMask,
					math.min(sideSlack, farSlack),
					survivingMask
				)
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
	Packs one visible frustum voxel proof. X holds the visible expiry, the Y
	component of -1 marks the culled verdict the record doesn't carry, and Z
	holds the arm factor rotation charges at. The decode side is inlined at
	the proof checks in searchSingleVoxel and the volume proof walk, plus the
	budget fallback's visible re-mark, which must all read this layout
	identically alongside the culled form below.
]]
local function packVisibleVoxelProof(expiry: number, armFactor: number): Vector3
	return Vector3.new(expiry, -1, armFactor)
end

--[[
	Packs one culled frustum voxel proof, the mirror of packVisibleVoxelProof
	with the X component of -1 marking the visible verdict the record doesn't
	carry and Y holding the culled expiry. Overwriting a record with this form
	also drops any stale visible expiry, so the budget fallback can't
	resurrect it.
]]
local function packCulledVoxelProof(expiry: number, armFactor: number): Vector3
	return Vector3.new(-1, expiry, armFactor)
end

--[[
	Resolves one voxel's visibility. It trusts a still-valid proof of either
	verdict, and otherwise frustum-tests its cell and stamps the fresh proof.
	Split children that land on a single voxel come here directly instead of
	taking a stack round-trip through searchVolume. voxelKey is the cell's own
	key, so its components equal (x0, y0, z0). Callers pass both because each
	already has both forms on hand.

	A nonzero umbraMask means occlusion still contests this cell. A still-valid
	occlusion proof settles that side first, hidden skipping the cell outright
	and not-occluded handing it to the frustum work alone. Otherwise the cell
	gets a leaf umbra test against the caller's mask. An occluded cell stamps
	a hidden proof (so the proof walk settles it next frame) and is skipped,
	leaving its frustum proof intact for whenever the occlusion lifts. A cell
	the test can't prove hidden stamps a not-occluded proof instead, measured
	against every built umbra rather than just the caller's mask (an umbra an
	ancestor pruned was pruned without a measured margin, so the stamp
	re-derives its own), which is what lets the walk settle boundary cells
	from cache instead of re-testing them every frame. Either stamp is only
	written when its allowance clears the frame's motion floor, since one
	that can't would expire before it was ever trusted. At a still camera
	the floor is zero and expiries compare inclusively, so even a
	zero-allowance verdict is written and stays alive without re-testing,
	matching the frustum proofs' zero-clearance semantics.
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
	voxelKey: types.VoxelKey,
	umbraMask: number
)
	if umbraMask ~= 0 then
		local occlusion = self._occlusion
		local accumT = self._motion._accumT
		local voxelOcclusionProofs = self._visibilityCache._voxelOcclusionProofs
		local occlusionProof = voxelOcclusionProofs[voxelKey]
		local notOccluded = false
		if occlusionProof then
			local proofGeneration = occlusionProof.Y
			if proofGeneration == occlusion._generation and accumT <= occlusionProof.X then
				-- The cell is still hidden behind its occluder.
				self._perfMetrics._occludedVoxelCount += 1
				return
			elseif proofGeneration == occlusion._clearGeneration and accumT <= occlusionProof.Z then
				-- The cell is not inside any umbra, so only the
				-- frustum work below is left.
				notOccluded = true
			end
		end
		if not notOccluded then
			local occluded, allowance = occlusion:testBoxOcclusion(umbraMask, x0, y0, z0, x0 + 1, y0 + 1, z0 + 1)
			if occluded then
				if allowance >= occlusion._motionFloor then
					voxelOcclusionProofs[voxelKey] = self:packOccludedProof(allowance)
				end
				self._perfMetrics._occludedVoxelCount += 1
				if _G.__DEV__ then
					self:drawBox(Color3.new(1, 0, 0), 0.5, x0, y0, z0, x0 + 1, y0 + 1, z0 + 1)
				end
				return
			end
			-- The measuring pass is skipped on frames where the shape
			-- allowance ceiling says nothing it stamps could outlive the
			-- motion floor, and a stamp is only written when its allowance
			-- clears that floor. At a still camera the floor is zero, so the
			-- zero-allowance stamp survives and keeps settling the cell from
			-- cache without re-testing, which is the semantics the frustum
			-- proofs' zero-clearance stamps share.
			local notOccludedAllowance = if occlusion._measuresUseful
				then occlusion:measureNotOccludedAllowance(occlusion._fullUmbraMask, x0, y0, z0, x0 + 1, y0 + 1, z0 + 1)
				else 0
			if notOccludedAllowance >= occlusion._motionFloor then
				voxelOcclusionProofs[voxelKey] = self:packClearProof(notOccludedAllowance)
			end
		end
	end

	local voxelProofs = self._visibilityCache._voxelProofs

	local proof = voxelProofs[voxelKey]
	local needsProof = true
	if proof then
		local m = accumTF + accumR * proof.Z
		if m <= proof.Y then
			-- The cell is still outside the frustum.
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
			-- Stamp the culled proof with the rejection margin.
			local shaved = shaveProofSlack(boxSlack)
			local armFactor = armBase + shaved
			voxelProofs[voxelKey] = packCulledVoxelProof(accumTF + accumR * armFactor + shaved, armFactor)
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
		voxelProofs[voxelKey] = packVisibleVoxelProof(accumTF + accumR * armFactor + shaved, armFactor)
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

	Occlusion goes first, before the proof walk, because an occluded volume is
	dead no matter what its frustum proofs say. A fully occluded volume stamps
	a hidden proof on every voxel in its slice and returns with no splits
	and no appends, leaving the frustum proofs intact for whenever the
	occlusion lifts, and a volume whose test prunes its last umbra stamps a
	not-occluded proof across its slice the same way before continuing as
	pure frustum work. A root volume seeded from an unclipped bucket arrives
	with its mask negated, meaning the seeding already ran this exact test,
	so the surviving mask is inherited instead of re-derived. A volume whose
	mask stays live takes the shared proof walk, where a valid hidden proof
	settles a cell as skipped, a valid culled frustum proof still settles a
	cell as culled, and a valid visible frustum proof settles a cell only
	alongside a valid not-occluded proof (alone it can't say whether an
	occluder hides the cell), so cells without one resolve through the leaf
	umbra test. A walk that bails splits the same way a frustum straddle
	does, children inherit the pruned mask, and children that leave every
	umbra resume pure frustum work.
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
	inheritedSlack: number,
	umbraMask: number
)
	if hi < lo then
		return
	end

	local searchVoxelKeys = self._searchVoxelKeys

	-- A negative mask says the seeding already umbra-tested this exact box
	-- this frame, so its surviving umbrae are inherited rather than
	-- re-derived (an identical box against an identical mask in the same
	-- frame can only repeat the verdict).
	local preTested = false
	if umbraMask < 0 then
		umbraMask = -umbraMask
		preTested = true
	end

	-- This is the special case for a single-voxel volume (a bucket clipped
	-- down to one cell). The leaf owns its own proof checks, umbra test,
	-- and stamps, so the volume-level machinery below would only duplicate
	-- its work.
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
			searchVoxelKeys[lo],
			umbraMask
		)
		return
	end

	if umbraMask ~= 0 and not preTested then
		local occlusion = self._occlusion
		local occluded, allowance, prunedMask = occlusion:testBoxOcclusion(umbraMask, x0, y0, z0, x1, y1, z1)
		if occluded then
			-- Every voxel here sits inside the occluding umbra, so each gets
			-- the umbra's occlusion proof stamped, one shared Vector3 since
			-- the allowance and generation are the umbra's, not the cell's.
			-- Frustum proofs stay untouched for whenever the occlusion lifts.
			-- A stamp that can't outlive the last frame's translation is
			-- skipped, since re-proving the whole slice next frame costs one
			-- box test while the dead stamps would cost a write per cell.
			if allowance >= occlusion._motionFloor then
				debug.profilebegin("stampBoxOccluded")
				local voxelOcclusionProofs = self._visibilityCache._voxelOcclusionProofs
				local occlusionProof = self:packOccludedProof(allowance)
				for i = lo, hi do
					voxelOcclusionProofs[searchVoxelKeys[i]] = occlusionProof
				end
				debug.profileend()
			end
			self._perfMetrics._occludedVoxelCount += hi - lo + 1
			if _G.__DEV__ then
				self:drawBox(Color3.new(1, 0, 0), 0.5, x0, y0, z0, x1, y1, z1)
			end
			return
		end
		if prunedMask == 0 and occlusion._measuresUseful then
			-- The test pruned the last umbra, so this box and everything in
			-- it is outside them all. That claim inherits downward
			-- (each cell is outside by at least the box's margins), so one
			-- measuring pass against every built umbra stamps the whole
			-- slice, and the walk settles these cells from their proofs on
			-- later frames instead of re-deriving the subdivision. A zero
			-- measurement (no single separating plane, or nothing that could
			-- outlive the motion floor) suppresses the stamp, and frames
			-- whose shape allowance ceiling rules every measurement out skip
			-- the pass entirely.
			debug.profilebegin("stampBoxClear")
			local clearAllowance = occlusion:measureClearAllowance(occlusion._fullUmbraMask, x0, y0, z0, x1, y1, z1)
			if clearAllowance > 0 then
				local voxelOcclusionProofs = self._visibilityCache._voxelOcclusionProofs
				local occlusionProof = self:packClearProof(clearAllowance)
				for i = lo, hi do
					voxelOcclusionProofs[searchVoxelKeys[i]] = occlusionProof
				end
			end
			debug.profileend()
		end
		umbraMask = prunedMask
	end

	local voxelProofs = self._visibilityCache._voxelProofs

	local pendingVoxelKeys = self._pendingVoxelKeys

	-- Walk the slice's proofs, both families at once. Valid-occluded voxels
	-- are skipped as hidden, and valid-culled ones are skipped as outside
	-- (a culled cell is culled no matter what occludes it). Under a live
	-- mask a frustum proof can't say whether an occluder hides the cell, so
	-- each contested cell consults its occlusion record once. A valid hidden
	-- verdict settles it outright, a valid not-occluded verdict hands it
	-- back to its frustum proof alone (no umbra can swallow it while the
	-- proof lives, so the frustum answer is the whole answer), and a cell
	-- with neither joins the unproven scratch list to pick up a leaf umbra
	-- test below. An uncontested volume skips the occlusion lookup entirely,
	-- even for cells whose stored occlusion proofs are still valid. This
	-- loop is the hottest in the search, and paying a per-cell lookup on
	-- every uncontested walk to catch the rare proof whose occluder lost
	-- this frame's selection isn't worth it, so those cells re-earn visible
	-- through their frustum proofs until their occluder wins a slot again,
	-- which only shows more. While unproven voxels stay rare relative to
	-- proven ones, the walk keeps its partial run and re-tests just those
	-- cells directly, so a few expired proofs cost a few cell tests instead
	-- of re-subdividing the whole volume. Once unproven voxels outnumber
	-- proven ones by the bail margin (a cold or mass-expired slice), the
	-- partial run is dropped and the box test below takes over, since
	-- subdivision proves whole boxes at a fraction of a test per voxel.
	-- This relies on searchVolume running serially (it does today).
	-- Parallel volume workers would race on the shared visible set here.
	debug.profilebegin("walkVoxelProofs")
	local contested = umbraMask ~= 0
	local voxelOcclusionProofs = self._visibilityCache._voxelOcclusionProofs
	local occlusionGeneration = if contested then self._occlusion._generation else 0
	local occlusionClearGeneration = if contested then self._occlusion._clearGeneration else 0
	local accumT = if contested then self._motion._accumT else 0
	local unprovenVoxelKeys = self._unprovenVoxelKeys
	local startCount = self._visibleVoxelCount
	local visibleCount = startCount
	local occludedCount = 0
	local provenCount = 0
	local unprovenCount = 0
	local bailed = false
	for i = lo, hi do
		local voxelKey = searchVoxelKeys[i]
		local cellContested = contested
		if contested then
			local occlusionProof = voxelOcclusionProofs[voxelKey]
			if occlusionProof then
				local proofGeneration = occlusionProof.Y
				if proofGeneration == occlusionGeneration and accumT <= occlusionProof.X then
					-- The cell is still hidden behind its occluder.
					provenCount += 1
					occludedCount += 1
					continue
				elseif proofGeneration == occlusionClearGeneration and accumT <= occlusionProof.Z then
					-- The cell is not inside any umbra, so its
					-- frustum proof decides alone.
					cellContested = false
				end
			end
		end
		local proof = voxelProofs[voxelKey]
		if proof then
			local m = accumTF + accumR * proof.Z
			if not cellContested and m <= proof.X then
				visibleCount += 1
				pendingVoxelKeys[visibleCount] = voxelKey
				provenCount += 1
			elseif m <= proof.Y then
				-- It's still culled, so skip it silently.
				provenCount += 1
			else
				-- No proof settles this cell. A still-valid visible verdict
				-- lands here too while the cell stays contested, since it
				-- still needs an occlusion answer.
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
		-- Keep the walk's appends and skips and resolve the stragglers cell
		-- by cell. The volume's own plane mask, inherited slack, and umbra
		-- mask are sound for any cell it contains (the masks only skip
		-- planes and umbrae that cannot decide the cell, and the
		-- inherited slack only shrinks down the tree).
		self._visibleVoxelCount = visibleCount
		self._perfMetrics._occludedVoxelCount += occludedCount
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
				voxelKey,
				umbraMask
			)
		end
		if _G.__DEV__ and unprovenCount == 0 and occludedCount == 0 and visibleCount - startCount == hi - lo + 1 then
			self:drawBox(Color3.new(0, 1, 0), 0, x0, y0, z0, x1, y1, z1)
		end
		return
	end

	local isInside, straddledMask, boxSlack = Frustum.isBoxInFrustum(frustumPlanes, planeMask, x0, y0, z0, x1, y1, z1)

	if not isInside then
		-- Every voxel inherits the box's rejection margin (each sits at least as
		-- far outside the rejecting plane as the box does), so stamp them all
		-- culled, each charged at its own arm.
		debug.profilebegin("stampBoxCulled")
		local shaved = shaveProofSlack(boxSlack)
		local centerOffset = VOXEL_CENTER_OFFSET - frustumPlanes[1]
		for i = lo, hi do
			local voxelKey = searchVoxelKeys[i]
			local armFactor = vectorMagnitude(voxelKey + centerOffset) + VOXEL_HALF_DIAGONAL + shaved
			voxelProofs[voxelKey] = packCulledVoxelProof(accumTF + accumR * armFactor + shaved, armFactor)
		end
		debug.profileend()
		return
	end

	-- A box is bounded by its ancestors' planes as well as its own tested ones,
	-- so the slack that proofs within this box may claim is the min of both.
	local effectiveSlack = if boxSlack < inheritedSlack then boxSlack else inheritedSlack

	-- If the box straddles no plane it is entirely inside, so we know all voxels
	-- contained inside are in the frustum and we can process them now and not
	-- split further. A live umbra mask blocks this shortcut, since some of
	-- those voxels may be hidden, and the split below sorts them out.
	if straddledMask == 0 and umbraMask == 0 then
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
			voxelProofs[voxelKey] = packVisibleVoxelProof(accumTF + accumR * armFactor + shaved, armFactor)
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
	-- paying a push, a pop, and another searchVolume call for one cell. The
	-- surviving umbra mask rides along so the cell gets its leaf test.
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
			searchVoxelKeys[lo],
			umbraMask
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
			searchVoxelKeys[mid],
			umbraMask
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
			self:pushVolume(ax0, ay0, az0, ax1, ay1, az1, lo, mid - 1, straddledMask, effectiveSlack, umbraMask)
		end
		if bHasVoxels then
			self:pushVolume(bx0, by0, bz0, bx1, by1, bz1, mid, hi, straddledMask, effectiveSlack, umbraMask)
		end
	else
		if bHasVoxels then
			self:pushVolume(bx0, by0, bz0, bx1, by1, bz1, mid, hi, straddledMask, effectiveSlack, umbraMask)
		end
		if aHasVoxels then
			self:pushVolume(ax0, ay0, az0, ax1, ay1, az1, lo, mid - 1, straddledMask, effectiveSlack, umbraMask)
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
	for base = 0, self._volumesToCheckSize - 1, 11 do
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
	unsorted, and sortVisibleVoxelKeys orders it afterward.

	Before any of that, the replay gate checks whether every input the pass
	reads is bit-identical to the last complete pass. When it is, re-running
	could only reproduce that pass's output, so run restores its visible count
	instead (the pending keys still sit in their slots) and returns true, which
	tells the facade the sorted voxel order from the anchor pass still stands
	and the re-sort can be skipped too. A pass that drains its whole stack
	re-anchors the gate, and one the budget truncated disarms it, since its
	output leaned on the stale-verdict fallback rather than the watched inputs
	alone.
]]
function VisibilitySearch.run(self: VisibilitySearch, now: number): boolean
	local motion = self._motion
	local occlusion = self._occlusion
	local grid = self._grid
	local perfMetrics = self._perfMetrics

	-- A visualizing dev session draws the gizmo boxes from inside the pass,
	-- so the replay stands down to keep them on screen.
	local visualizing = false
	if _G.__DEV__ then
		visualizing = _G.__VISUALIZE__ == true
	end

	if
		self._replayReady
		and not visualizing
		and motion._accumT == self._replayAccumT
		and motion._accumR == self._replayAccumR
		and motion._accumF == self._replayAccumF
		and motion._flushCount == self._replayFlushCount
		and grid._occupancyGeneration == self._replayOccupancyGeneration
		and occlusion._buildCount == self._replayBuildCount
		and occlusion._generation == self._replayGeneration
		and occlusion._clearGeneration == self._replayClearGeneration
		and self._config.maxOccluders == self._replayMaxOccluders
	then
		-- Nothing the pass reads has changed, so the frame re-marks the
		-- previous output. The occluded count is restored alongside since the
		-- same voxels still sit hidden, and the caches are exactly as the
		-- anchor pass left them, unaged because the odometers never moved.
		self._visibleVoxelCount = self._replayVisibleVoxelCount
		perfMetrics._occludedVoxelCount = self._replayOccludedVoxelCount
		perfMetrics._searchDuration = os.clock() - now
		return true
	end

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
	local volumeCount = self._volumesToCheckSize // 11
	if volumeCount > 1 then
		local chosenBase = (self._volumeRotationCounter % volumeCount) * 11
		local topBase = (volumeCount - 1) * 11
		if chosenBase ~= topBase then
			for k = 1, 11 do
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
	local accumTF = motion._accumT + motion._accumF
	local accumR = motion._accumR
	local volumesSinceClockCheck = 0
	while self._volumesToCheckSize > 0 do
		-- Pop the top volume, which is 11 numbers covering its 6 bounds, its
		-- [lo, hi] slice, its plane mask, its inherited slack, and its umbra
		-- mask. We read everything into locals before shrinking the stack so
		-- searchVolume can reuse the just-freed slots for any child volumes it
		-- pushes.
		local n = self._volumesToCheckSize
		local x0 = volumesToCheck[n - 10]
		local y0 = volumesToCheck[n - 9]
		local z0 = volumesToCheck[n - 8]
		local x1 = volumesToCheck[n - 7]
		local y1 = volumesToCheck[n - 6]
		local z1 = volumesToCheck[n - 5]
		local lo = volumesToCheck[n - 4]
		local hi = volumesToCheck[n - 3]
		local planeMask = volumesToCheck[n - 2]
		local inheritedSlack = volumesToCheck[n - 1]
		local umbraMask = volumesToCheck[n]
		self._volumesToCheckSize = n - 11

		self:searchVolume(
			accumTF,
			accumR,
			frustumPlanes,
			x0,
			y0,
			z0,
			x1,
			y1,
			z1,
			lo,
			hi,
			planeMask,
			inheritedSlack,
			umbraMask
		)

		volumesSinceClockCheck += 1
		if volumesSinceClockCheck >= SEARCH_CLOCK_CHECK_VOLUME_INTERVAL then
			volumesSinceClockCheck = 0
			if os.clock() - now >= searchTimeBudget then
				self:reuseCachedVisibilityForRemainingVolumes()
				break
			end
		end
	end

	-- A pass that drained its whole stack produced output pinned by nothing
	-- but the watched inputs, so it anchors the replay gate. A truncated pass
	-- leaned on the stale-verdict fallback and can't.
	if self._volumesToCheckSize == 0 then
		self._replayReady = true
		self._replayAccumT = motion._accumT
		self._replayAccumR = motion._accumR
		self._replayAccumF = motion._accumF
		self._replayFlushCount = motion._flushCount
		self._replayOccupancyGeneration = grid._occupancyGeneration
		self._replayBuildCount = occlusion._buildCount
		self._replayGeneration = occlusion._generation
		self._replayClearGeneration = occlusion._clearGeneration
		self._replayMaxOccluders = config.maxOccluders
		self._replayVisibleVoxelCount = self._visibleVoxelCount
		self._replayOccludedVoxelCount = perfMetrics._occludedVoxelCount
	else
		self._replayReady = false
	end

	perfMetrics._searchDuration = os.clock() - now
	debug.profileend()
	return false
end

--[[
	Orders this frame's visible voxels closest-first by manhattan distance to
	the camera (in voxel space). The ingest passes rely on that order. Nearer
	voxels get precise ingestion, and once the budget runs out the fast
	approximate pass uses the index as a coarse priority. The ordering is only
	a soft heuristic (manhattan distance is itself an approximation).

	Distances are small non-negative integers, so a counting sort orders them
	in O(n + maxDistance) with no element shuffling, and cameraVoxelKey is
	computed just once for the whole batch.
]]
function VisibilitySearch.sortVisibleVoxelKeys(self: VisibilitySearch)
	local count = self._visibleVoxelCount
	local pendingVoxelKeys = self._pendingVoxelKeys
	local visibleVoxelKeys = self._visibleVoxelKeys

	if count == 0 then
		return
	elseif count == 1 then
		visibleVoxelKeys[1] = pendingVoxelKeys[1]
		return
	end

	local cameraVoxelKey = CameraCache.Position // self._config.voxelSize
	local distances = self._pendingVoxelDistances
	local counts = self._voxelDistanceCounts

	-- Compute the manhattan distance for every pending voxel, plus the max (the bucket range).
	local maxDistance = 0
	for i = 1, count do
		local distance = vectorDot(vectorAbs(pendingVoxelKeys[i] - cameraVoxelKey), VECTOR_ONE)
		distances[i] = distance
		if distance > maxDistance then
			maxDistance = distance
		end
	end

	-- Tally how many voxels land in each distance bucket.
	for distance = 0, maxDistance do
		counts[distance] = 0
	end
	for i = 1, count do
		local distance = distances[i]
		counts[distance] += 1
	end

	-- Turn the tallies into each bucket's starting output slot (prefix sum).
	local slot = 1
	for distance = 0, maxDistance do
		local bucketCount = counts[distance]
		counts[distance] = slot
		slot += bucketCount
	end

	-- Scatter each voxel into its sorted slot.
	-- Walking the source in order keeps voxels at equal distance in their original (stable) order.
	for i = 1, count do
		local distance = distances[i]
		local outputIndex = counts[distance]
		counts[distance] = outputIndex + 1
		visibleVoxelKeys[outputIndex] = pendingVoxelKeys[i]
	end
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
	for base = 0, volumesSize - 1, 11 do
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
	tableClear(self._voxelDistanceCounts)
	tableClear(self._volumesToCheck)
	self._volumesToCheckSize = 0
	-- The replayable output lived in the buffers just cleared.
	self._replayReady = false
end

return VisibilitySearch
