--!strict
--!optimize 2
--!native

--[[
	This module owns occlusion culling. Consumers tag big opaque box parts with
	the CullThrottleOccluder tag, and each frame this module scores the tagged
	set, picks the most promising few, and builds their umbra volumes, the
	regions the camera cannot see because the occluder blocks every
	sightline into them. The visibility search tests coarse buckets and search
	volumes against those umbrae and skips whatever sits fully inside one.

	Each umbra is the intersection of half-spaces stored as unit normals with
	precomputed scalar offsets, so a signed distance is one dot and one
	subtract. Cap planes (one world-fixed plane per camera-facing face, so
	nothing between the camera and the occluder can be culled) are laid out
	ahead of the silhouette planes (through the camera and each edge where a
	camera-facing face meets a back face), because the prune path breaks on the
	first fully-outside plane and the cap is what rejects the common box
	sitting in front of the occluder. A per-umbra AABB covering everything the
	umbra can reach within the search's range gates each test in six
	comparisons before any plane math runs.

	Every umbra is built from the occluder's box eroded inward by a pad, which
	is the uniform floor under every cached occlusion proof's translation
	allowance. When a sightline from the camera passes through the eroded box,
	any camera within pad of that position still has its sightline into the
	same point blocked by the full box. On top of that floor, a verdict deep
	inside (or well clear of) an umbra earns a depth-scaled allowance from the
	pivot bound, using the box's measured plane margins together with the
	umbra's shape margin and its minimum camera-to-edge distance. MATH.md
	section 13 derives both bounds. Occlusion depends only on where the camera
	is, never which way it faces, so cached occlusion proofs charge only the
	translation accumulator and survive any amount of rotation, FOV change, or
	render distance change.

	Verdicts cache in both directions with separate guards. Hidden proofs are
	witnessed by one occluder and store the occluder generation, which bumps on
	any occluder mutation. The clear side quantifies over every umbra built in
	a frame, so those proofs store the clear generation, which additionally
	bumps when the frame's selection admits an occluder that the previous
	frame's didn't. It comes in two strengths. The clear verdict proper says
	the box is fully outside every umbra, whose margins inherit downward to
	everything the box contains, so buckets and whole search volumes carry it.
	The not-occluded verdict says only that no umbra fully contains the box,
	witnessed by a single support point poking out of one plane per umbra,
	which inherits nothing and so belongs solely to leaf cells, the boundary
	huggers the strong form can't cover. Both are measured in ungated passes
	over every umbra's planes, paid once per stamp rather than once per frame.

	The pad also lets a built umbra set outlive its frame. Selection still
	runs every frame (it's the cheap part, and it's what notices an occluder
	entering the view or winning a slot), and its fresh pose reads double as
	the change poll that bumps the generation the same frame an occluder moves
	or resizes, ahead of the reuse gate and every proof consult, without
	waiting on deferred property signals. While the selected set matches
	the built one, no occluder has mutated, no cache flush intervened, and the
	translation odometer has moved less than the tightest built pad since the
	build, the plane sets, anchors, and AABBs are reused as they stand. Every
	allowance handed out on a reuse frame is debited by that drift, so a
	stored proof still bounds total motion from the build anchor. A stale AABB
	or plane set can only misjudge toward visible, so reuse never costs
	soundness, only culling reach, and the pad crossing rebuilds before the
	reach loss can grow past the pad.

	Stamps are also gated by worth. A proof whose allowance is smaller than
	the translation the camera just did in one frame would expire before it
	could ever be trusted, so the measuring passes bail to zero as soon as
	any umbra's ceiling (its shape allowance) can't clear that floor, and
	callers skip writing stamps that fall under it. At a still camera the
	floor is zero and every stamp survives, including zero-allowance ones,
	which keeps the still-camera fast paths exactly as they were.

	Erring falsely visible is the rule throughout. A box that straddles an
	umbra boundary stays visible, a degenerate umbra is skipped entirely, the
	erosion pad only ever shrinks the umbra, and every allowance substitution
	rounds down.

	Two kinds of code share this file, the occluder registry (tag watching,
	qualification, and the cached poses) and the umbra geometry. They stay
	together because the soundness invariant behind every hidden proof, that
	any occluder mutation bumps the generation, is enforced from both halves,
	by the watchers when a part disqualifies and by the build's pose poll and
	camera-entry transitions. If occluder qualification ever grows past
	simple parts, the registry section is the seam to split along.
]]

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local Frustum = require(script.Parent.Frustum)
local CameraMotion = require(script.Parent.CameraMotion)
local VisibilityCache = require(script.Parent.VisibilityCache)
local CameraCache = require(script.Parent.Utilities.CameraCache)

local vectorDot = (vector.dot :: any) :: (Vector3 | vector, Vector3 | vector) -> number
local vectorMagnitude = (vector.magnitude :: any) :: (Vector3 | vector) -> number
local vectorAbs = (vector.abs :: any) :: (Vector3 | vector) -> Vector3
local tableClear = table.clear
local tableSort = table.sort
local tableCreate = table.create
local tableMove = table.move

-- This is the CollectionService tag that marks a part as an occluder.
local OCCLUDER_TAG = "CullThrottleOccluder"

-- This is the guard band for the umbra plane comparisons, in voxel-space
-- units, matching the frustum tests. Occlusion only counts when the box is
-- inside every plane by more than this, so float noise errs toward visible.
local EPSILON = 1e-4

-- This gets shaved off every stored translation allowance so the f32 packing
-- of the cached proof can only make it expire sooner, never later. It matches
-- the SLACK_SAFETY the search shaves off its frustum proofs.
local SLACK_SAFETY = 1e-2

-- The umbra is built from the occluder eroded inward by this fraction of its
-- smallest half extent (capped at one voxel), and that pad becomes the floor
-- under the cached proofs' translation allowances. Eroding by at most half
-- the smallest half extent keeps every eroded extent positive.
local EROSION_FRACTION = 0.5

-- A silhouette plane is skipped (taking the whole occluder with it) when the
-- camera is this close to collinear with the edge, measured as the sine of
-- the angle between the camera-to-endpoint vectors.
local COLLINEAR_EPSILON = 1e-6

-- A silhouette plane whose orienting face center sits within this many studs
-- of the plane has no trustworthy inside, so the occluder is skipped.
local ORIENTATION_EPSILON = 1e-6

-- Cached proofs pack their generation into an f32 component, which is only
-- exact up to 2^24, so each counter wraps (and the proofs flush) before then.
local GENERATION_LIMIT = 2 ^ 24

-- These describe the box's 12 edges. Faces are indexed +X, -X, +Y, -Y, +Z,
-- -Z, and corners are indexed 1 through 8 with the sign bits of (x, y, z)
-- mapping to 4, 2, and 1 (so corner 1 is (-, -, -) and corner 8 is
-- (+, +, +)). An edge is a silhouette edge when exactly one of its two
-- adjacent faces is camera facing.
local EDGE_FACE_A = { 1, 1, 2, 2, 1, 1, 2, 2, 3, 3, 4, 4 }
local EDGE_FACE_B = { 3, 4, 3, 4, 5, 6, 5, 6, 5, 6, 5, 6 }
local EDGE_CORNER_A = { 7, 5, 3, 1, 6, 5, 2, 1, 4, 3, 2, 1 }
local EDGE_CORNER_B = { 8, 6, 4, 2, 8, 7, 4, 3, 8, 7, 6, 5 }

-- This maps a face index to its axis (1 for X, 2 for Y, 3 for Z), used to
-- read the eroded half extent that separates a face's center from an
-- adjacent edge line.
local FACE_AXIS = { 1, 1, 2, 2, 3, 3 }

local OcclusionCulling = {}
OcclusionCulling.__index = OcclusionCulling

OcclusionCulling.OCCLUDER_TAG = OCCLUDER_TAG

type OcclusionCullingProto = {
	_config: Config.Config,
	_visibilityCache: VisibilityCache.VisibilityCache,
	_motion: CameraMotion.CameraMotion,
	-- This is how far past the frustum's AABB the search can seed a testable
	-- box, in voxels. The search owns the value (its seeding geometry decides
	-- it) and the facade passes it in, so the umbra AABBs' reach stays
	-- correct if the seeding ever widens.
	_searchReachExpansion: number,

	-- The occluder generation versions the occluder set for hidden proofs.
	-- Any mutation of a registered occluder bumps it, and every cached hidden
	-- proof stores the generation it was proven under, so a mismatch
	-- invalidates the proof in one comparison with no cache walk. Merely
	-- rotating which occluders get selected each frame does not bump it,
	-- because a hidden proof anchored to an unchanged occluder stays true
	-- whether or not that occluder is selected right now.
	_generation: number,
	-- The clear generation versions the umbra set for clear proofs, which
	-- quantify over every umbra built in a frame. It bumps whenever the
	-- occluder generation bumps, and whenever a frame's built selection
	-- contains an occluder the previous frame's didn't, since that new
	-- umbra is one no cached clear proof was tested against. A selection
	-- that only shrinks doesn't bump it, because losing an umbra can't put
	-- a box inside one.
	_clearGeneration: number,

	_occluders: { Part },
	_occluderIndices: { [Part]: number },
	-- Every tagged Part keeps a watcher set (anchored, shape, ancestry) for
	-- its whole tagged lifetime, so a part that qualifies later registers the
	-- moment it does and one that stops qualifying drops out the same way.
	_watchedParts: { [Part]: { RBXScriptConnection } },
	_tagConnections: { RBXScriptConnection },
	-- These cache each registered occluder's pose as of the last build's
	-- poll, the comparison anchor that catches a moved or resized occluder
	-- the same frame without waiting on deferred property signals.
	_occluderCFrames: { [Part]: CFrame },
	_occluderHalfSizes: { [Part]: Vector3 },
	-- This marks occluders the camera currently sits inside of, so the entry
	-- transition bumps the generation exactly once rather than every frame
	-- the camera stays embedded.
	_cameraInsideOccluder: { [Part]: true? },
	-- This is the selection prefilter's scratch copy of the frustum planes,
	-- so the closing plane it appends never mutates the camera cache's table.
	_frustumPlanesScratch: { Vector3 },

	-- These hold the umbrae built this frame, indexed by umbra slot. Each
	-- plane is a unit normal plus a scalar offset (the dot of a point on the
	-- plane with the normal), all in voxel coordinates, with caps laid out
	-- ahead of silhouette planes and the counts alongside (the arrays are
	-- reused across frames, so slots past the count are stale). The
	-- allowance is the pad floor, the shape allowance bounds how far the
	-- camera can move before the plane set changes shape (a face flips its
	-- classification or an orienting face center crosses its plane), and the
	-- edge distance is the camera's minimum distance to a silhouette edge
	-- line, all in voxels. The bounds box every point the umbra can reach
	-- within the search's range, for the six-comparison gate.
	_umbraPlaneNormals: { { Vector3 } },
	_umbraPlaneOffsets: { { number } },
	_umbraPlaneCounts: { number },
	_umbraCapCounts: { number },
	_umbraAllowances: { number },
	_umbraShapeAllowances: { number },
	_umbraEdgeDistances: { number },
	_umbraBoundsMin: { Vector3 },
	_umbraBoundsMax: { Vector3 },
	_umbraCount: number,
	-- This is the bitmask with one bit set per built umbra, what a search
	-- volume starts from before any pruning.
	_fullUmbraMask: number,
	-- This is the camera position in voxel coordinates as of this frame's
	-- build, read by the depth-scaled allowance math in the box test.
	_cameraPosVoxels: Vector3,

	-- These track which occluders built umbrae last frame, so the clear
	-- generation can bump exactly when the selection admits a new member.
	_lastSelection: { [Part]: boolean },
	_lastSelectionCount: number,

	-- These anchor the built umbra set for reuse. The build records the
	-- translation odometer, the flush count, the occluder generation, the
	-- pre-degeneracy top scorers it selected, and two minima over what it
	-- built, the tightest pad allowance (the drift budget reuse must stay
	-- under) and the tightest shape allowance (the ceiling no measuring pass
	-- can beat). A frame that matches all of it skips construction and keeps
	-- the plane sets as they stand.
	_buildAccumT: number,
	_buildFlushCount: number,
	_buildGeneration: number,
	_reusePadBudget: number,
	_minShapeAllowance: number,
	_builtTentativeSet: { [Part]: true },
	_builtTentativeCount: number,
	-- This counts every frame whose umbra set may differ from the frame
	-- before it, meaning any actual reconstruction plus the teardown of
	-- planes a previous build left standing. Frames that reuse the built
	-- planes leave it alone, so the search's whole-frame replay can trust an
	-- unchanged count to mean geometrically identical umbrae.
	_buildCount: number,

	-- These are the frame's stamp-gate values, set by buildUmbrae on every
	-- path. The debit is the odometer drift since the build anchor, charged
	-- against every allowance handed out this frame. The motion floor is the
	-- translation the last processed frame added, the least a stamp must
	-- outlive to ever be trusted. The bail threshold folds floor, debit, and
	-- the safety shave into the raw value a measuring pass must reach before
	-- its result can matter, and the useful flag is the whole-frame verdict
	-- from the shape-allowance ceiling, letting callers skip the measuring
	-- passes outright on frames where nothing they stamp could survive.
	_allowanceDebit: number,
	_motionFloor: number,
	_measureBailThreshold: number,
	_measuresUseful: boolean,

	-- These are per-frame scratch buffers for candidate scoring, selection
	-- tracking, and umbra construction, reused to avoid allocation churn.
	_builtOccluders: { Part },
	_candidateIndices: { number },
	_candidateScores: { [number]: number },
	-- The comparator closes over the persistent score table once, so the
	-- per-frame selection sort allocates nothing.
	_candidateComparator: (number, number) -> boolean,
	_faceVisible: { boolean },
	_corners: { Vector3 },
	_faceCenters: { Vector3 },
	_faceNormals: { Vector3 },
	_faceHalfExtents: { number },
}

export type OcclusionCulling = typeof(setmetatable({} :: OcclusionCullingProto, OcclusionCulling))

--[[
	Builds the module with an empty occluder set, then captures the occluder
	tag so already-tagged parts register immediately and later tag changes
	track automatically.
]]
function OcclusionCulling.new(
	config: Config.Config,
	visibilityCache: VisibilityCache.VisibilityCache,
	motion: CameraMotion.CameraMotion,
	searchReachExpansion: number
): OcclusionCulling
	-- The comparator closes over the persistent score table once, so the
	-- per-frame selection sort allocates nothing.
	local candidateScores: { [number]: number } = {}
	local self = setmetatable({
		_config = config,
		_visibilityCache = visibilityCache,
		_motion = motion,
		_searchReachExpansion = searchReachExpansion,
		_generation = 0,
		_clearGeneration = 0,
		_occluders = {},
		_occluderIndices = {},
		_watchedParts = {},
		_tagConnections = {},
		_occluderCFrames = {},
		_occluderHalfSizes = {},
		_cameraInsideOccluder = {},
		_frustumPlanesScratch = tableCreate(12, Vector3.zero),
		_umbraPlaneNormals = {},
		_umbraPlaneOffsets = {},
		_umbraPlaneCounts = {},
		_umbraCapCounts = {},
		_umbraAllowances = {},
		_umbraShapeAllowances = {},
		_umbraEdgeDistances = {},
		_umbraBoundsMin = {},
		_umbraBoundsMax = {},
		_umbraCount = 0,
		_fullUmbraMask = 0,
		_cameraPosVoxels = Vector3.zero,
		_lastSelection = {},
		_lastSelectionCount = 0,
		_buildAccumT = 0,
		_buildFlushCount = 0,
		_buildGeneration = 0,
		_reusePadBudget = 0,
		_minShapeAllowance = 0,
		_builtTentativeSet = {},
		_builtTentativeCount = 0,
		_buildCount = 0,
		-- The gate defaults describe a still camera with a fresh build, so
		-- allowances pass through undebited and every stamp is worth writing.
		_allowanceDebit = 0,
		_motionFloor = 0,
		_measureBailThreshold = SLACK_SAFETY,
		_measuresUseful = true,
		_builtOccluders = {},
		_candidateIndices = {},
		_candidateScores = candidateScores,
		_candidateComparator = function(a: number, b: number)
			return candidateScores[a] > candidateScores[b]
		end,
		_faceVisible = tableCreate(6, false),
		_corners = tableCreate(8, Vector3.zero),
		_faceCenters = tableCreate(6, Vector3.zero),
		_faceNormals = tableCreate(6, Vector3.zero),
		_faceHalfExtents = tableCreate(3, 0),
	}, OcclusionCulling)

	self._tagConnections = {
		CollectionService:GetInstanceAddedSignal(OCCLUDER_TAG):Connect(function(instance: Instance)
			self:_watchOccluder(instance)
		end),
		CollectionService:GetInstanceRemovedSignal(OCCLUDER_TAG):Connect(function(instance: Instance)
			self:_unwatchOccluder(instance)
		end),
	}
	for _, instance in CollectionService:GetTagged(OCCLUDER_TAG) do
		self:_watchOccluder(instance)
	end

	return self
end

--[[
	Advances one generation counter, wrapping (and flushing every cached
	occlusion proof) before the counter outgrows the exact range of the f32
	component the proofs pack it into, since a wrapped counter could otherwise
	falsely match an ancient proof.
]]
local function advanceGeneration(self: OcclusionCulling, counter: number): number
	local advanced = counter + 1
	if advanced < GENERATION_LIMIT then
		return advanced
	end
	self._visibilityCache:clearOcclusionProofs()
	return 0
end

--[[
	Advances the clear generation, which versions the umbra set for the clear
	proofs.
]]
function OcclusionCulling._bumpClearGeneration(self: OcclusionCulling)
	self._clearGeneration = advanceGeneration(self, self._clearGeneration)
end

--[[
	Advances the occluder generation and bumps the clear generation alongside,
	since any occluder mutation can reshape an umbra a clear proof was tested
	against.
]]
function OcclusionCulling._bumpGeneration(self: OcclusionCulling)
	self._generation = advanceGeneration(self, self._generation)
	self:_bumpClearGeneration()
end

--[[
	Registers one occluder and seeds its cached pose for the build's change
	poll. Qualification is the watcher layer's job, so this only guards
	against double registration. Registering doesn't bump either generation.
	Existing hidden proofs stay true because more occlusion can't falsify
	them, and clear proofs stay true until the newcomer actually wins a
	selection slot, which the selection tracking in buildUmbrae catches.
]]
function OcclusionCulling._registerOccluder(self: OcclusionCulling, part: Part)
	if self._occluderIndices[part] then
		return
	end

	local count = #self._occluders + 1
	self._occluders[count] = part
	self._occluderIndices[part] = count
	self._occluderCFrames[part] = part.CFrame
	self._occluderHalfSizes[part] = part.Size * 0.5
end

--[[
	Unregisters one occluder with an unordered swap-remove and bumps the
	generation, since proofs it anchored are no longer backed by anything.
]]
function OcclusionCulling._unregisterOccluder(self: OcclusionCulling, part: Part)
	local index = self._occluderIndices[part]
	if not index then
		return
	end

	self._occluderIndices[part] = nil
	self._occluderCFrames[part] = nil
	self._occluderHalfSizes[part] = nil
	self._cameraInsideOccluder[part] = nil

	local occluders = self._occluders
	local lastIndex = #occluders
	if index ~= lastIndex then
		local swapped = occluders[lastIndex]
		occluders[index] = swapped
		self._occluderIndices[swapped] = index
	end
	occluders[lastIndex] = nil

	self:_bumpGeneration()
end

--[[
	Re-evaluates one watched part against the full occluder qualification and
	registers or unregisters it to match. Only anchored box-shaped Parts
	sitting under the workspace qualify. A wedge or mesh doesn't fill its
	bounding box, so treating it as a box could cull things that peek through
	the missing volume. An unanchored part moves through physics without any
	change the build's pose poll is scheduled to catch. And a part parked
	outside the workspace (a stored template, a swapped-out map) no longer
	renders, so leaving it registered would cull everything behind its stored
	pose indefinitely.
]]
function OcclusionCulling._evaluateOccluder(self: OcclusionCulling, part: Part)
	if part.Anchored and part.Shape == Enum.PartType.Block and part:IsDescendantOf(workspace) then
		self:_registerOccluder(part)
	else
		self:_unregisterOccluder(part)
	end
end

--[[
	Starts watching one tagged instance for the rest of its tagged lifetime,
	then evaluates it. The watcher set keeps qualification live, so tag and
	property changes can arrive in any order and the registry still converges
	on the tagged parts that currently qualify. Instances that aren't Parts
	are warned about and skipped rather than erroring, matching how tag
	capture tolerates un-addable instances, and the class can never change so
	they get no watchers. Disqualified Parts get a warn at tag time for the
	likely mistakes (shape and anchoring), while a part merely stored outside
	the workspace stays quiet, since parking templates is routine and the
	watcher registers them the moment they land in the workspace.
]]
function OcclusionCulling._watchOccluder(self: OcclusionCulling, instance: Instance)
	if not instance:IsA("Part") then
		warn(`[CullThrottle] Skipping tagged occluder {instance:GetFullName()}: occluders must be box shaped Parts`)
		return
	end
	local part = instance :: Part
	if self._watchedParts[part] then
		return
	end

	self._watchedParts[part] = {
		part:GetPropertyChangedSignal("Anchored"):Connect(function()
			self:_evaluateOccluder(part)
		end),
		part:GetPropertyChangedSignal("Shape"):Connect(function()
			self:_evaluateOccluder(part)
		end),
		part.AncestryChanged:Connect(function()
			self:_evaluateOccluder(part)
		end),
	}

	if part.Shape ~= Enum.PartType.Block then
		warn(`[CullThrottle] Skipping tagged occluder {part:GetFullName()}: occluders must be box shaped Parts`)
	elseif not part.Anchored then
		warn(`[CullThrottle] Skipping tagged occluder {part:GetFullName()}: occluders must be anchored`)
	end
	self:_evaluateOccluder(part)
end

--[[
	Tears down one instance's watcher set and unregisters it, for when the
	tag comes off or the instance leaves the DataModel.
]]
function OcclusionCulling._unwatchOccluder(self: OcclusionCulling, instance: Instance)
	local connections = self._watchedParts[instance :: Part]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	self._watchedParts[instance :: Part] = nil
	self:_unregisterOccluder(instance :: Part)
end

--[[
	Returns whether cached occlusion proofs are honored this frame, which is
	whenever the occluder cap allows occlusion and at least one occluder is
	registered. Proofs anchored to an unchanged occluder stay true even on
	frames where their occluder didn't make the top-K cut. With zero
	registered occluders no proof can validly match anyway (unregistering the
	last occluder bumped the generation), so the search skips its per-bucket
	lookups outright and a place that never tags an occluder pays nothing for
	the layer.
]]
function OcclusionCulling.isHonoringProofs(self: OcclusionCulling): boolean
	return self._config.maxOccluders > 0 and #self._occluders > 0
end

--[[
	Refreshes the frame's stamp-gate values from the given odometer drift
	since the build anchor (zero when the build is fresh or there's nothing
	built). The debit charges that drift against every allowance handed out
	this frame, the bail threshold folds floor, debit, and the safety shave
	into the raw value a measuring pass must reach, and the useful flag is the
	whole-frame verdict from the shape-allowance ceiling. Callers keep
	_umbraCount and _minShapeAllowance current before calling, since a frame
	with no built umbrae has nothing worth stamping.
]]
function OcclusionCulling._refreshStampGate(self: OcclusionCulling, drift: number)
	local motionFloor = self._motionFloor
	self._allowanceDebit = drift
	self._measureBailThreshold = motionFloor + drift + SLACK_SAFETY
	self._measuresUseful = self._umbraCount > 0 and self._minShapeAllowance - drift - SLACK_SAFETY >= motionFloor
end

--[[
	Builds one occluder's umbra into the given slot, in voxel coordinates.
	farRadius is the farthest reach of any box the search can test, in voxels,
	for the AABB gate. Returns false without building when the umbra would be
	degenerate (the camera inside the part, collinear with a silhouette edge,
	or coplanar with an orienting face), which errs toward visible.

	The construction classifies the eroded box's six faces as camera facing or
	not, takes the edges where the two classifications differ as the
	silhouette, and emits one world-fixed cap plane per camera-facing face
	followed by one plane through the camera per silhouette edge. Normals
	point out of the umbra, matching the frustum convention where a positive
	plane distance means outside, and each silhouette normal is oriented by
	its adjacent camera-facing face's center, which sits inside.

	Alongside the planes, the build measures everything the depth-scaled
	allowance needs (MATH.md section 13). The shape allowance is the smaller
	of the topology margin (how far the camera can move before any face flips
	its classification) and each silhouette plane's orientation stability (the
	orienting face center's own pivot bound, its plane distance scaled by its
	edge distance over its distance to the edge line). The edge distance is
	the camera's minimum distance to a silhouette edge line, which the
	collinearity cross products give almost for free. And the AABB covers the
	eroded corners plus their images scaled about the camera to farRadius over
	the camera's distance to the eroded box, a hull that contains
	every umbra point within farRadius (MATH.md section 12).
]]
function OcclusionCulling._buildUmbra(
	self: OcclusionCulling,
	part: Part,
	umbraIndex: number,
	farRadius: number
): boolean
	local voxelSize = self._config.voxelSize
	local cframe = part.CFrame
	local halfSize = part.Size * 0.5
	local minHalf = math.min(halfSize.X, halfSize.Y, halfSize.Z)
	local pad = math.min(minHalf * EROSION_FRACTION, voxelSize)
	local hx, hy, hz = halfSize.X - pad, halfSize.Y - pad, halfSize.Z - pad

	local cameraPos = CameraCache.Position
	local localCamera = cframe:PointToObjectSpace(cameraPos)
	local absLocalX, absLocalY, absLocalZ = math.abs(localCamera.X), math.abs(localCamera.Y), math.abs(localCamera.Z)
	if absLocalX <= halfSize.X and absLocalY <= halfSize.Y and absLocalZ <= halfSize.Z then
		-- The camera is inside the part itself, where the renderer draws
		-- backfaces transparent and the player sees straight through it, so
		-- no shadow it casts can be trusted. This also covers the camera
		-- inside the eroded box, where no face is classified visible and no
		-- stable shadow exists geometrically either. The selection loop runs
		-- this same full-box test to exclude candidates and bump the
		-- generation on entry, so the two must stay in lockstep.
		return false
	end

	local faceVisible = self._faceVisible
	faceVisible[1] = localCamera.X > hx
	faceVisible[2] = localCamera.X < -hx
	faceVisible[3] = localCamera.Y > hy
	faceVisible[4] = localCamera.Y < -hy
	faceVisible[5] = localCamera.Z > hz
	faceVisible[6] = localCamera.Z < -hz

	-- The topology term of the shape margin, in studs. Each face's
	-- classification compares a local camera coordinate against an eroded
	-- half extent, and a translation of magnitude t moves each local
	-- coordinate by at most t, so this is how far the camera can go before
	-- any face flips.
	local shapeMargin = math.min(math.abs(absLocalX - hx), math.abs(absLocalY - hy), math.abs(absLocalZ - hz))

	local position = cframe.Position
	local worldX = cframe.XVector * hx
	local worldY = cframe.YVector * hy
	local worldZ = cframe.ZVector * hz

	local corners = self._corners
	corners[1] = position - worldX - worldY - worldZ
	corners[2] = position - worldX - worldY + worldZ
	corners[3] = position - worldX + worldY - worldZ
	corners[4] = position - worldX + worldY + worldZ
	corners[5] = position + worldX - worldY - worldZ
	corners[6] = position + worldX - worldY + worldZ
	corners[7] = position + worldX + worldY - worldZ
	corners[8] = position + worldX + worldY + worldZ

	local faceCenters = self._faceCenters
	faceCenters[1] = position + worldX
	faceCenters[2] = position - worldX
	faceCenters[3] = position + worldY
	faceCenters[4] = position - worldY
	faceCenters[5] = position + worldZ
	faceCenters[6] = position - worldZ

	local faceNormals = self._faceNormals
	faceNormals[1] = cframe.XVector
	faceNormals[2] = -cframe.XVector
	faceNormals[3] = cframe.YVector
	faceNormals[4] = -cframe.YVector
	faceNormals[5] = cframe.ZVector
	faceNormals[6] = -cframe.ZVector

	local faceHalfExtents = self._faceHalfExtents
	faceHalfExtents[1] = hx
	faceHalfExtents[2] = hy
	faceHalfExtents[3] = hz

	local normals = self._umbraPlaneNormals[umbraIndex]
	local offsets = self._umbraPlaneOffsets[umbraIndex]
	if not normals then
		normals = {}
		offsets = {}
		self._umbraPlaneNormals[umbraIndex] = normals
		self._umbraPlaneOffsets[umbraIndex] = offsets
	end

	-- Caps go first so the prune path can reject boxes in front of the
	-- occluder on its first plane.
	local planeCount = 0
	for face = 1, 6 do
		if faceVisible[face] then
			planeCount += 1
			local normal = faceNormals[face]
			normals[planeCount] = normal
			offsets[planeCount] = vectorDot(faceCenters[face], normal) / voxelSize
		end
	end
	local capCount = planeCount

	local cameraPosVoxels = cameraPos / voxelSize
	local minEdgeDistance = math.huge

	for edge = 1, 12 do
		local faceA, faceB = EDGE_FACE_A[edge], EDGE_FACE_B[edge]
		local visibleA = faceVisible[faceA]
		if visibleA ~= faceVisible[faceB] then
			local toCornerA = corners[EDGE_CORNER_A[edge]] - cameraPos
			local toCornerB = corners[EDGE_CORNER_B[edge]] - cameraPos
			local normal = toCornerA:Cross(toCornerB)
			local magnitude = vectorMagnitude(normal)
			if magnitude <= COLLINEAR_EPSILON * vectorMagnitude(toCornerA) * vectorMagnitude(toCornerB) then
				-- The camera is in line with this edge, so the plane has no
				-- stable orientation. Skip the whole occluder rather than
				-- build a leaky umbra.
				return false
			end
			normal = normal / magnitude

			local visibleFace = if visibleA then faceA else faceB
			local hiddenFace = if visibleA then faceB else faceA
			local side = vectorDot(faceCenters[visibleFace] - cameraPos, normal)
			local sideMagnitude
			if side > ORIENTATION_EPSILON then
				normal = -normal
				sideMagnitude = side
			elseif side < -ORIENTATION_EPSILON then
				sideMagnitude = -side
			else
				-- The orienting face center lies on the plane, so inside and
				-- outside are indistinguishable here.
				return false
			end

			planeCount += 1
			normals[planeCount] = normal
			offsets[planeCount] = vectorDot(cameraPosVoxels, normal)

			-- The cross magnitude over the edge length is the camera's
			-- distance to this edge's line, the pivot radius of its plane.
			local edgeDistance = magnitude / vectorMagnitude(toCornerA - toCornerB)
			if edgeDistance < minEdgeDistance then
				minEdgeDistance = edgeDistance
			end

			-- The orienting face center must keep its side as the plane
			-- pivots, so its own pivot bound joins the shape margin. Its
			-- distance to the edge line is exactly the eroded half extent
			-- along the hidden face's axis.
			local orientationBound = sideMagnitude * edgeDistance / faceHalfExtents[FACE_AXIS[hiddenFace]]
			if orientationBound < shapeMargin then
				shapeMargin = orientationBound
			end
		end
	end

	-- The AABB covers the eroded corners and their images scaled about the
	-- camera, a hull containing every umbra point within farRadius of the
	-- camera. The scale never drops below one so the corners' own span
	-- always survives.
	local excessX = math.max(absLocalX - hx, 0)
	local excessY = math.max(absLocalY - hy, 0)
	local excessZ = math.max(absLocalZ - hz, 0)
	local cameraDistance = math.sqrt(excessX * excessX + excessY * excessY + excessZ * excessZ) / voxelSize
	local scale = math.max(farRadius / cameraDistance, 1)
	local boundsMin = Vector3.one * math.huge
	local boundsMax = -boundsMin
	for i = 1, 8 do
		local corner = corners[i] / voxelSize
		local scaled = cameraPosVoxels + (corner - cameraPosVoxels) * scale
		boundsMin = boundsMin:Min(corner):Min(scaled)
		boundsMax = boundsMax:Max(corner):Max(scaled)
	end

	self._umbraPlaneCounts[umbraIndex] = planeCount
	self._umbraCapCounts[umbraIndex] = capCount
	self._umbraAllowances[umbraIndex] = math.max(pad / voxelSize - SLACK_SAFETY, 0)
	self._umbraShapeAllowances[umbraIndex] = shapeMargin / voxelSize
	self._umbraEdgeDistances[umbraIndex] = minEdgeDistance / voxelSize
	self._umbraBoundsMin[umbraIndex] = boundsMin
	self._umbraBoundsMax[umbraIndex] = boundsMax
	return true
end

--[[
	Runs one frame's candidate selection over the registered occluders,
	filling _candidateIndices (sorted best first) and _candidateScores, and
	returning how many candidates survived. An occluder whose box sits fully
	outside the view frustum is dropped before scoring, because an umbra
	lives entirely along rays from the camera through its occluder, so it
	can't contain anything the frustum shows (MATH.md section 12 has the
	argument). Survivors are scored by a projected-size heuristic (radius
	squared over distance squared). The loop's fresh pose reads double as the
	synchronous change poll that keeps the generation current, and a camera
	sitting inside an occluder excludes it from candidacy, both explained at
	their lines below.
]]
function OcclusionCulling._selectCandidates(
	self: OcclusionCulling,
	cameraPos: Vector3,
	cameraPosVoxels: Vector3,
	frustumPlanes: { Vector3 },
	voxelSize: number
): number
	-- A sixth plane closes the frustum behind the camera. The four side
	-- planes all meet at the camera, so a box straddling the region directly
	-- behind it isn't fully outside any one of them, and this plane is the
	-- one that rejects it. The extra plane lives in this module's own scratch
	-- copy, since the camera cache owns the returned table and every other
	-- consumer sizes its plane loop from that table's length.
	local selectionPlanes = self._frustumPlanesScratch
	tableMove(frustumPlanes, 1, 10, 1, selectionPlanes)
	selectionPlanes[11] = cameraPosVoxels
	selectionPlanes[12] = -CameraCache.CFrame.LookVector

	local occluders = self._occluders
	local occluderCFrames = self._occluderCFrames
	local occluderHalfSizes = self._occluderHalfSizes
	local candidates = self._candidateIndices
	local scores = self._candidateScores
	local candidateCount = 0
	for i = 1, #occluders do
		local part = occluders[i]
		local cframe = part.CFrame
		local halfSize = part.Size * 0.5
		-- Reading the pose fresh every frame doubles as a synchronous change
		-- poll. Property signals arrive deferred, so leaning on them would let
		-- this frame reuse umbrae and honor proofs anchored to a pose the part
		-- no longer holds, while this compare catches the change before the
		-- reuse gate or any proof consult runs.
		if cframe ~= occluderCFrames[part] or halfSize ~= occluderHalfSizes[part] then
			occluderCFrames[part] = cframe
			occluderHalfSizes[part] = halfSize
			self:_bumpGeneration()
		end
		local hx, hy, hz = halfSize.X, halfSize.Y, halfSize.Z
		local xVector, yVector, zVector = cframe.XVector, cframe.YVector, cframe.ZVector
		-- These are the world-aligned bounding half extents of the oriented
		-- box, so the frustum test sees a box containing the occluder and a
		-- rejection can only drop an occluder that truly can't help.
		local extents = vectorAbs(xVector) * hx + vectorAbs(yVector) * hy + vectorAbs(zVector) * hz
		local ex, ey, ez = extents.X, extents.Y, extents.Z
		local position = cframe.Position
		local intersects = Frustum.isBoxInFrustum(
			selectionPlanes,
			0b111111,
			(position.X - ex) / voxelSize,
			(position.Y - ey) / voxelSize,
			(position.Z - ez) / voxelSize,
			(position.X + ex) / voxelSize,
			(position.Y + ey) / voxelSize,
			(position.Z + ez) / voxelSize
		)
		if not intersects then
			continue
		end
		-- A camera inside the part itself sees through it, because the
		-- renderer draws backfaces transparent, so its umbra must not cull
		-- anything. Skipping the candidate keeps it out of the tentative
		-- selection (tearing down a reused umbra on entry), and the entry
		-- bump expires the hidden proofs it anchored, whose sightline
		-- argument outlives the pad but not the see-through rendering.
		-- The same full-box test guards _buildUmbra directly, and the two
		-- must stay in lockstep.
		local localCamera = cframe:PointToObjectSpace(cameraPos)
		if math.abs(localCamera.X) <= hx and math.abs(localCamera.Y) <= hy and math.abs(localCamera.Z) <= hz then
			if not self._cameraInsideOccluder[part] then
				self._cameraInsideOccluder[part] = true
				self:_bumpGeneration()
			end
			continue
		elseif self._cameraInsideOccluder[part] then
			self._cameraInsideOccluder[part] = nil
		end
		local radius = vectorMagnitude(halfSize)
		local distance = vectorMagnitude(position - cameraPos)
		candidateCount += 1
		candidates[candidateCount] = i
		scores[i] = (radius * radius) / math.max(distance * distance, 1)
	end
	for i = #candidates, candidateCount + 1, -1 do
		candidates[i] = nil
	end

	if candidateCount > 1 then
		tableSort(candidates, self._candidateComparator)
	end

	return candidateCount
end

--[[
	Records the freshly built umbra set as the reuse anchor. The pad budget
	is the tightest built pad allowance (the drift under which every built
	plane set stays sound), and the shape minimum is the ceiling no measuring
	pass against the full mask can beat, which decides whole frames of
	measuring up front. The tentative set is the pre-degeneracy top scorers,
	the cheapest stable identity the selection has.
]]
function OcclusionCulling._anchorBuild(self: OcclusionCulling, tentativeCount: number)
	local reusePadBudget = math.huge
	local minShapeAllowance = math.huge
	local umbraAllowances = self._umbraAllowances
	local umbraShapeAllowances = self._umbraShapeAllowances
	for i = 1, self._umbraCount do
		if umbraAllowances[i] < reusePadBudget then
			reusePadBudget = umbraAllowances[i]
		end
		if umbraShapeAllowances[i] < minShapeAllowance then
			minShapeAllowance = umbraShapeAllowances[i]
		end
	end

	local motion = self._motion
	self._buildAccumT = motion._accumT
	self._buildFlushCount = motion._flushCount
	self._buildGeneration = self._generation
	self._reusePadBudget = reusePadBudget
	self._minShapeAllowance = minShapeAllowance

	local builtTentativeSet = self._builtTentativeSet
	tableClear(builtTentativeSet)
	local occluders = self._occluders
	local candidates = self._candidateIndices
	for c = 1, tentativeCount do
		builtTentativeSet[occluders[candidates[c]]] = true
	end
	self._builtTentativeCount = tentativeCount
end

--[[
	Runs one frame's occluder selection and umbra construction. An occluder
	whose box sits fully outside the view frustum is dropped before scoring,
	because an umbra lives entirely along rays from the camera through its
	occluder, so it can't contain anything the frustum shows (MATH.md section
	12 has the argument). Survivors are scored by a projected-size heuristic
	(radius squared over distance squared) and the top maxOccluders build
	umbrae, skipping degenerates and pulling in the next candidate, so the
	occluder cap is only ever spent on occluders that can contribute. With no
	tagged occluders or a zero occluder cap, this leaves zero umbrae and the
	search runs exactly as if occlusion didn't exist.

	The build also compares this frame's selection against last frame's and
	bumps the clear generation when a new member arrives, since cached clear
	proofs were never tested against the newcomer's umbra. A selection that
	only shrinks leaves the counter alone, because losing an umbra can't
	falsify a clear verdict.

	Construction itself is skipped when the last build still holds. The
	candidates are filtered and scored every frame regardless, because the
	scoring is cheap and it's what notices an occluder entering the view or
	winning a slot, but when the top scorers match the built set, no occluder
	mutated, no cache flush re-anchored the odometer, and the camera has
	translated less than the tightest built pad since the build, the built
	planes stay sound as they stand (any sightline through an eroded box is
	still blocked by the full box for every camera within the pad). The frame
	then just refreshes the gate values, with the drift since the build
	debited from every allowance handed out. The umbra AABBs and the anchor
	the depth-scaled math measures from stay at their build values too, which
	can only misjudge toward visible until the pad crossing rebuilds them.

	Whatever the path, the build leaves the frame's stamp-gate values behind.
	The motion floor is how much translation the last processed frame added,
	and a stamp whose allowance can't clear it would expire before it was
	ever trusted, so the measuring passes and stamp writers skip that work.

	Every path that can leave different umbrae than the frame before, a
	rebuild that built anything or a teardown of planes that existed, also
	bumps the build count, which is how the search's whole-frame replay knows
	the umbra inputs held still.
]]
function OcclusionCulling.buildUmbrae(self: OcclusionCulling)
	local motion = self._motion
	self._motionFloor = motion._lastTranslationDelta

	local config = self._config
	local occluders = self._occluders
	local occluderCount = #occluders
	local maxOccluders = config.maxOccluders
	if occluderCount == 0 or maxOccluders <= 0 then
		-- Tearing down umbrae a previous build left standing changes what the
		-- search tests against, so it counts as a build, while a bare frame
		-- following a bare frame doesn't and keeps the replay gate open.
		if self._umbraCount ~= 0 then
			self._buildCount += 1
		end
		self._umbraCount = 0
		self._fullUmbraMask = 0
		self:_refreshStampGate(0)
		return
	end

	debug.profilebegin("buildUmbrae")
	local cameraPos = CameraCache.Position
	local voxelSize = config.voxelSize
	local frustumPlanes, minBound, maxBound = CameraCache.getPlanesAndBounds(config.renderDistance, voxelSize)
	local cameraPosVoxels = cameraPos / voxelSize

	-- This is the farthest reach of any box the search can test, in voxels.
	-- The search declares how far past the frustum's AABB its seeding can
	-- reach, so expanding the AABB by that much covers every point of every
	-- testable box, and the umbra AABBs only need to extend that far.
	local reach = self._searchReachExpansion
	local expandedMin = minBound - Vector3.one * reach
	local expandedMax = maxBound + Vector3.one * (reach + 1)
	local farRadius =
		vectorMagnitude(vectorAbs(cameraPosVoxels - expandedMin):Max(vectorAbs(expandedMax - cameraPosVoxels)))

	local candidateCount = self:_selectCandidates(cameraPos, cameraPosVoxels, frustumPlanes, voxelSize)
	local candidates = self._candidateIndices

	-- The tentative selection is the top scorers before any degeneracy
	-- skips, which is the cheapest stable identity the selection has. When
	-- it matches the built one and every other reuse condition holds, the
	-- built umbrae are kept as they stand and only the gate values refresh.
	-- Comparing pre-degeneracy sets means a build that skipped a degenerate
	-- and pulled in a replacement keeps reusing even if the degeneracy would
	-- resolve at the current camera, which forgoes that one umbra until the
	-- pad crossing rebuilds, erring toward visible.
	local tentativeCount = math.min(maxOccluders, candidateCount)
	if
		self._umbraCount > 0
		and motion._flushCount == self._buildFlushCount
		and self._generation == self._buildGeneration
		and tentativeCount == self._builtTentativeCount
	then
		local drift = motion._accumT - self._buildAccumT
		if drift < self._reusePadBudget then
			local builtTentativeSet = self._builtTentativeSet
			local sameSelection = true
			for c = 1, tentativeCount do
				if not builtTentativeSet[occluders[candidates[c]]] then
					sameSelection = false
					break
				end
			end
			if sameSelection then
				self:_refreshStampGate(drift)
				debug.profileend()
				return
			end
		end
	end

	self._cameraPosVoxels = cameraPosVoxels

	local builtOccluders = self._builtOccluders
	local built = 0
	for c = 1, candidateCount do
		if built >= maxOccluders then
			break
		end
		local part = occluders[candidates[c]]
		if self:_buildUmbra(part, built + 1, farRadius) then
			built += 1
			builtOccluders[built] = part
		end
	end
	-- A rebuild that produced planes, or one that tore down planes a previous
	-- build left standing, may leave different umbrae than the frame before,
	-- so the build count moves. A rebuild from nothing to nothing doesn't,
	-- keeping the replay gate open while every candidate stays degenerate.
	if built > 0 or self._umbraCount > 0 then
		self._buildCount += 1
	end
	self._umbraCount = built
	self._fullUmbraMask = 2 ^ built - 1

	-- Bump the clear generation when the selection gained a member, then
	-- keep the tracked set current either way.
	local lastSelection = self._lastSelection
	local changed = false
	for i = 1, built do
		if not lastSelection[builtOccluders[i]] then
			changed = true
			break
		end
	end
	if changed then
		self:_bumpClearGeneration()
	end
	if changed or built ~= self._lastSelectionCount then
		tableClear(lastSelection)
		for i = 1, built do
			lastSelection[builtOccluders[i]] = true
		end
		self._lastSelectionCount = built
	end
	tableClear(builtOccluders)

	self:_anchorBuild(tentativeCount)
	self:_refreshStampGate(0)
	debug.profileend()
end

--[[
	Tests one voxel-space box against every umbra whose bit is set in
	umbraMask, returning (occluded, allowance, prunedMask). A box fully inside
	every plane of some umbra is occluded, and the allowance is that verdict's
	translation allowance, the larger of the umbra's pad floor and the
	depth-scaled pivot bound from the box's own measured margins. A box fully
	outside an umbra can never be touched by it (nor can anything within the
	box), so its bit is pruned from the returned mask for the caller's
	children to skip, resolved by the six-comparison AABB gate when the box
	misses the umbra's reach entirely and by the first fully-outside plane
	otherwise. A box that straddles an umbra keeps the bit and stays visible,
	the conservative direction. This test measures nothing about how durable
	a prune is (measureClearAllowance below does that, and only the bucket
	layer pays for it), so the second return is meaningful only on the
	occluded verdict. Bounds arrive ordered, matching the frustum tests.
]]
function OcclusionCulling.testBoxOcclusion(
	self: OcclusionCulling,
	umbraMask: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): (boolean, number, number)
	local center = Vector3.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
	local extents = Vector3.new((x1 - x0) * 0.5, (y1 - y0) * 0.5, (z1 - z0) * 0.5)
	-- Like the frustum tests, the circumscribing sphere resolves the clear
	-- cases cheaply and the exact projection interval settles the rest.
	local sphereRadius = vectorMagnitude(extents)
	-- Every point of the box sits within this far of the camera, the
	-- conservative reach the pivot bound divides by. It costs a square root,
	-- and most tests never reach a pivot term, so it fills in lazily.
	local boxDistanceMax = -1

	local umbraPlaneNormals = self._umbraPlaneNormals
	local umbraPlaneOffsets = self._umbraPlaneOffsets
	local umbraPlaneCounts = self._umbraPlaneCounts
	local umbraCapCounts = self._umbraCapCounts
	local umbraBoundsMin = self._umbraBoundsMin
	local umbraBoundsMax = self._umbraBoundsMax
	local mask = umbraMask
	local planeBit = 1

	for i = 1, self._umbraCount do
		if bit32.band(mask, planeBit) ~= 0 then
			local boundsMin, boundsMax = umbraBoundsMin[i], umbraBoundsMax[i]
			if
				x1 < boundsMin.X
				or x0 > boundsMax.X
				or y1 < boundsMin.Y
				or y0 > boundsMax.Y
				or z1 < boundsMin.Z
				or z0 > boundsMax.Z
			then
				-- The box misses the umbra's AABB, so the umbra can never
				-- touch it and the plane loop is skipped.
				mask = bit32.band(mask, bit32.bnot(planeBit))
			else
				local normals = umbraPlaneNormals[i]
				local offsets = umbraPlaneOffsets[i]
				local planeCount = umbraPlaneCounts[i]
				local capCount = umbraCapCounts[i]
				local fullyInside = true
				local minSilhouetteMargin = math.huge
				for j = 1, planeCount do
					local planeNormal = normals[j]
					local dist = vectorDot(center, planeNormal) - offsets[j]

					if dist - sphereRadius > EPSILON then
						-- The box is fully outside this plane, so this umbra
						-- can never occlude any part of it.
						mask = bit32.band(mask, bit32.bnot(planeBit))
						fullyInside = false
						break
					elseif dist + sphereRadius > -EPSILON then
						-- The extents are componentwise non-negative, so this dot
						-- sums the three projection terms, matching the frustum test.
						local radius = vectorDot(extents, vectorAbs(planeNormal))
						if dist - radius > EPSILON then
							mask = bit32.band(mask, bit32.bnot(planeBit))
							fullyInside = false
							break
						elseif dist + radius > -EPSILON then
							-- The box straddles this plane, so this umbra can't
							-- fully occlude it. The bit stays set because children
							-- of the box may still land fully inside. The scan
							-- keeps going only to catch a fully-outside plane that
							-- would prune the bit.
							fullyInside = false
						elseif j > capCount then
							local silhouetteMargin = -dist - radius
							if silhouetteMargin < minSilhouetteMargin then
								minSilhouetteMargin = silhouetteMargin
							end
						end
					elseif j > capCount then
						-- The sphere radius overstates the projection radius,
						-- so this margin only ever understates.
						local silhouetteMargin = -dist - sphereRadius
						if silhouetteMargin < minSilhouetteMargin then
							minSilhouetteMargin = silhouetteMargin
						end
					end
				end
				if fullyInside then
					-- The hidden allowance is the larger of the pad floor and
					-- the pivot bound, the minimum silhouette margin scaled
					-- by edge distance over (box reach + edge distance) and
					-- capped by the shape allowance (MATH.md section 13). Cap
					-- margins never enter it because cap planes are world
					-- fixed, and with no silhouette margin measured (a
					-- hand-built plane set can be all caps) the shape
					-- allowance alone bounds the pivot term. Both bounds are
					-- measured from the build anchor, so on a reuse frame the
					-- drift already spent comes off the grant, keeping the
					-- stored expiry equal to the anchor reading plus the
					-- geometric bound.
					local pivotAllowance = self._umbraShapeAllowances[i]
					if minSilhouetteMargin < math.huge then
						if boxDistanceMax < 0 then
							boxDistanceMax = vectorMagnitude(center - self._cameraPosVoxels) + sphereRadius
						end
						local edgeDistance = self._umbraEdgeDistances[i]
						local sweepAllowance = minSilhouetteMargin * edgeDistance / (boxDistanceMax + edgeDistance)
						if sweepAllowance < pivotAllowance then
							pivotAllowance = sweepAllowance
						end
					end
					local allowance = math.max(self._umbraAllowances[i], pivotAllowance - SLACK_SAFETY)
						- self._allowanceDebit
					return true, if allowance > 0 then allowance else 0, umbraMask
				end
			end
		end
		if mask == 0 then
			-- Every umbra is pruned, so the verdict and the returned mask are
			-- final and the remaining slots have nothing left to test.
			break
		end
		planeBit *= 2
	end

	return false, 0, mask
end

--[[
	Shared skeleton behind the two measuring passes. Both walk the masked
	umbrae under the same shape-allowance bail and finish with the same
	debit-and-shave epilogue, differing only in what counts as one umbra's
	witness. The clear mode demands a plane the whole box sits outside of,
	while the not-occluded mode settles for one support point poking out of
	each umbra. Each mode's claim and its soundness argument live on its
	public wrapper below. The plane loops never use the AABB gate, because a
	gate prune measures no margin, and an umbra that offers no witness yields
	zero, which suppresses the stamp. The loops amortize over the proof's
	whole lifetime, and to protect that bargain the pass bails to zero the
	moment any umbra can't reach the frame's bail threshold, since a result
	under the motion floor dies before it's ever trusted. The drift debit
	comes off the result so the stored proof still bounds total motion from
	the build anchor.
]]
local function measureAllowance(
	self: OcclusionCulling,
	wholeBoxOutside: boolean,
	umbraMask: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	local center = Vector3.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
	local extents = Vector3.new((x1 - x0) * 0.5, (y1 - y0) * 0.5, (z1 - z0) * 0.5)
	local sphereRadius = vectorMagnitude(extents)
	local boxDistanceMax = vectorMagnitude(center - self._cameraPosVoxels) + sphereRadius

	local umbraPlaneNormals = self._umbraPlaneNormals
	local umbraPlaneOffsets = self._umbraPlaneOffsets
	local umbraPlaneCounts = self._umbraPlaneCounts
	local umbraCapCounts = self._umbraCapCounts
	local bailThreshold = self._measureBailThreshold
	local allowance = math.huge
	local planeBit = 1

	for i = 1, self._umbraCount do
		if bit32.band(umbraMask, planeBit) ~= 0 then
			local shapeAllowance = self._umbraShapeAllowances[i]
			if shapeAllowance < bailThreshold then
				-- Every witness this umbra can offer is capped by its shape
				-- allowance, so the result can't clear the motion floor and
				-- the whole pass is a dead stamp. Zero suppresses it.
				return 0
			end
			local normals = umbraPlaneNormals[i]
			local offsets = umbraPlaneOffsets[i]
			local planeCount = umbraPlaneCounts[i]
			local capCount = umbraCapCounts[i]
			local edgeDistance = self._umbraEdgeDistances[i]
			local witness = 0
			if wholeBoxOutside then
				for j = 1, planeCount do
					local planeNormal = normals[j]
					local dist = vectorDot(center, planeNormal) - offsets[j]
					local margin = dist - sphereRadius
					if margin <= EPSILON then
						-- The sphere straddles this plane, so try the exact
						-- projection interval before moving on.
						margin = dist - vectorDot(extents, vectorAbs(planeNormal))
						if margin <= EPSILON then
							continue
						end
					end
					witness = if j <= capCount
						then shapeAllowance
						else math.min(shapeAllowance, margin * edgeDistance / (boxDistanceMax + edgeDistance))
					break
				end
			else
				local maxPokeOut = 0
				for j = 1, planeCount do
					local planeNormal = normals[j]
					local pokeOut = vectorDot(center, planeNormal)
						- offsets[j]
						+ vectorDot(extents, vectorAbs(planeNormal))
					if pokeOut > EPSILON then
						if j <= capCount then
							witness = shapeAllowance
							break
						elseif pokeOut > maxPokeOut then
							maxPokeOut = pokeOut
						end
					end
				end
				if witness == 0 and maxPokeOut > 0 then
					witness = math.min(shapeAllowance, maxPokeOut * edgeDistance / (boxDistanceMax + edgeDistance))
				end
			end
			if witness < bailThreshold then
				return 0
			end
			if witness < allowance then
				allowance = witness
			end
		end
		planeBit *= 2
	end

	local shavedAllowance = allowance - self._allowanceDebit - SLACK_SAFETY
	return if shavedAllowance > 0 then shavedAllowance else 0
end

--[[
	Measures the translation allowance a clear proof may claim for a box that
	testBoxOcclusion already pruned every umbra from. The answer is the
	minimum over the umbrae of how far the camera can move before this box
	could stop being outside them. A prune witnessed by a world-fixed cap
	plane holds for the umbra's shape allowance, and one witnessed by a
	silhouette plane also rides that plane's pivot bound (MATH.md section 13).
	An umbra this box is outside of without being fully outside any single
	plane (possible near the corners of the umbra's reach) yields zero, which
	suppresses the stamp.
]]
function OcclusionCulling.measureClearAllowance(
	self: OcclusionCulling,
	umbraMask: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	return measureAllowance(self, true, umbraMask, x0, y0, z0, x1, y1, z1)
end

--[[
	Measures the translation allowance a not-occluded proof may claim for a
	leaf cell's box that testBoxOcclusion already found no umbra fully
	containing. The claim is weaker than the clear verdict (the box may
	straddle umbrae, it just isn't swallowed by any), so the witness is one
	point rather than the whole box. For each umbra, any plane whose maximum
	signed distance p = dist + radius is strictly positive puts the box's
	support point strictly outside it, and that point keeps its side for the
	shape allowance when the plane is a world-fixed cap, or for the pivot
	bound p * edgeDistance / (boxDistanceMax + edgeDistance) when it's a
	silhouette plane (MATH.md section 13). Caps are scanned first because a
	cap witness already achieves the shape-allowance ceiling and ends that
	umbra's scan, and the radius must be the exact projection radius, since
	the sphere overestimate would inflate p and grant unearned durability.
	Poke-out witnesses don't inherit downward (a box can poke out of an
	umbra while a cell inside it sits fully hidden), so only leaf cells,
	which have no contents, ever store this measurement. The mask must cover
	every umbra built this frame, because the stored proof quantifies over
	all of them. Returns zero when some umbra offers no witness, which
	suppresses durability and never soundness.
]]
function OcclusionCulling.measureNotOccludedAllowance(
	self: OcclusionCulling,
	umbraMask: number,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	return measureAllowance(self, false, umbraMask, x0, y0, z0, x1, y1, z1)
end

--[[
	Disconnects the tag and watcher connections and clears everything so the
	parts this module referenced can be garbage collected.
]]
function OcclusionCulling.destroy(self: OcclusionCulling)
	for _, connection in self._tagConnections do
		connection:Disconnect()
	end
	tableClear(self._tagConnections)
	for _, connections in self._watchedParts do
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	tableClear(self._watchedParts)
	tableClear(self._occluders)
	tableClear(self._occluderIndices)
	tableClear(self._occluderCFrames)
	tableClear(self._occluderHalfSizes)
	tableClear(self._cameraInsideOccluder)
	tableClear(self._umbraPlaneNormals)
	tableClear(self._umbraPlaneOffsets)
	tableClear(self._umbraPlaneCounts)
	tableClear(self._umbraCapCounts)
	tableClear(self._umbraAllowances)
	tableClear(self._umbraShapeAllowances)
	tableClear(self._umbraEdgeDistances)
	tableClear(self._umbraBoundsMin)
	tableClear(self._umbraBoundsMax)
	tableClear(self._lastSelection)
	self._lastSelectionCount = 0
	tableClear(self._builtTentativeSet)
	self._builtTentativeCount = 0
	self._umbraCount = 0
	self._fullUmbraMask = 0
end

return OcclusionCulling
