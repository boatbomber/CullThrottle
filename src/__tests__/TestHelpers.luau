--[[
	This module holds the shared fixtures for the CullThrottle test files. It has
	the mock instance factories, shortcuts that stage internal state the way the
	real passes record it, a module-function patch registry, and the shared
	frustum fixtures.
]]

--[[
	Creates an anchored (unless told otherwise) part parented to workspace.
]]
local function createMockPart(position: Vector3?, size: Vector3?, anchored: boolean?)
	local part = Instance.new("Part")
	part.Position = position or Vector3.new(0, 0, 0)
	part.Size = size or Vector3.new(4, 4, 4)
	part.Anchored = if anchored ~= nil then anchored else true
	part.Parent = workspace
	return part
end

--[[
	Creates a workspace model whose PrimaryPart is a fresh mock part.
]]
local function createMockModel(position: Vector3?, size: Vector3?)
	local model = Instance.new("Model")
	local primaryPart = createMockPart(position, size)
	primaryPart.Parent = model
	model.PrimaryPart = primaryPart
	model.Parent = workspace
	return model
end

--[[
	Stages the given tracked objects as one visible voxel (a synthetic cell far
	from any real voxel, removed afterwards) and runs the given ingest pass over it.
]]
local function runPassOverSyntheticVoxel(ct, objects: { Instance }, pass: () -> ())
	local syntheticKey = Vector3.new(1e9, 1e9, 1e9)
	local voxel = table.create(#objects)
	for i, object in objects do
		voxel[i] = ct._lifecycle._objects[object]
	end
	ct._grid._voxels[syntheticKey] = voxel
	ct._search._visibleVoxelKeys = { syntheticKey }
	ct._search._visibleVoxelCount = 1
	pass()
	ct._grid._voxels[syntheticKey] = nil
	ct._search._visibleVoxelCount = 0
end

--[[
	Runs the precise ingest pass over the given tracked objects.
]]
local function ingestObjects(ct, now: number, objects: { Instance })
	runPassOverSyntheticVoxel(ct, objects, function()
		ct._ingest:ingestVisibleVoxels(now)
	end)
end

--[[
	Runs the fast approximate ingest pass over the given tracked objects,
	staged the same way ingestObjects stages them.
]]
local function fastIngestObjects(ct, now: number, objects: { Instance })
	runPassOverSyntheticVoxel(ct, objects, function()
		ct._ingest:fastApproxIngestRemainingVoxels(now, 1)
	end)
end

--[[
	Marks an already-added object as in view as of the given clock, through the
	same markVisible path the ingest passes use.
]]
local function markInView(ct, object: Instance, clock: number)
	ct._signals:markVisible(ct._lifecycle._objects[object], clock)
end

--[[
	VoxelGrid:insertToVoxel and removeFromVoxel treat voxel entries purely by
	identity, so the voxel bookkeeping tests can use a stub in place of a full
	ObjectData.
]]
local function stubObjectData(object: Instance): any
	return { object = object }
end

--[[
	Packs a visible voxel proof the way the search stamps one. The X component
	is the expiry of the visible verdict, Y is -1 because the proof carries no
	culled verdict, and Z is the arm the rotation accumulator is charged at.
	The proof is trusted while (accumT + accumF) + accumR * Z stays at or under
	the stored expiry.
]]
local function visibleVoxelProof(expiry: number, arm: number): Vector3
	return Vector3.new(expiry, -1, arm)
end

--[[
	Packs a culled voxel proof, the mirror of visibleVoxelProof with the culled
	verdict's expiry in Y and -1 in X.
]]
local function culledVoxelProof(expiry: number, arm: number): Vector3
	return Vector3.new(-1, expiry, arm)
end

--[[
	Pops the top volume off a search's flat stack, the way the search's run
	loop reads one. Each volume spans ten consecutive slots holding its box
	bounds, its [lo, hi] slice of the seed buffer, its plane mask, and its
	inherited slack, and this returns them as named fields so tests never
	hand-copy the slot layout.
]]
local function popVolume(search: any): { [string]: number }
	local volumesToCheck = search._volumesToCheck
	local n = search._volumesToCheckSize
	local volume = {
		x0 = volumesToCheck[n - 9],
		y0 = volumesToCheck[n - 8],
		z0 = volumesToCheck[n - 7],
		x1 = volumesToCheck[n - 6],
		y1 = volumesToCheck[n - 5],
		z1 = volumesToCheck[n - 4],
		lo = volumesToCheck[n - 3],
		hi = volumesToCheck[n - 2],
		planeMask = volumesToCheck[n - 1],
		inheritedSlack = volumesToCheck[n],
	}
	search._volumesToCheckSize = n - 10
	return volume
end

--[[
	Drains a search's volume stack the way run does, popping each volume and
	resolving it through searchVolume with the given accumulators and no time
	budget, so the stack always empties.
]]
local function drainVolumeStack(search: any, accumTF: number, accumR: number, frustumPlanes: { Vector3 })
	while search._volumesToCheckSize > 0 do
		local volume = popVolume(search)
		search:searchVolume(
			accumTF,
			accumR,
			frustumPlanes,
			volume.x0,
			volume.y0,
			volume.z0,
			volume.x1,
			volume.y1,
			volume.z1,
			volume.lo,
			volume.hi,
			volume.planeMask,
			volume.inheritedSlack
		)
	end
end

-- Module-table patches are shared state across tests (unlike patches on a
-- per-test instance, which die with it), so every patch is registered here and
-- restorePatches is wired into afterEach by the suites that patch.
local activePatches: { { moduleTable: { [string]: any }, name: string, original: any } } = {}

--[[
	Replaces moduleTable[name] with wrapper, records the original in the patch
	registry, and returns the original for the wrapper to delegate to.
]]
local function patchFunction(moduleTable: { [string]: any }, name: string, wrapper: any): any
	local original = moduleTable[name]
	table.insert(activePatches, { moduleTable = moduleTable, name = name, original = original })
	moduleTable[name] = wrapper
	return original
end

--[[
	Restores every patched module function, newest first so nested patches of
	the same function unwind cleanly.
]]
local function restorePatches()
	for i = #activePatches, 1, -1 do
		local patch = activePatches[i]
		patch.moduleTable[patch.name] = patch.original
	end
	table.clear(activePatches)
end

-- This is a voxel-space frustum (a 70 FoV camera at the origin facing +Y, with
-- the far plane one voxel out) whose planes all cut through the first coarse
-- bucket's box, so seeding against it classifies that bucket as straddling and
-- its keys are seeded for subdivision rather than resolved by a cached bucket
-- verdict.
local straddlingFrustumPlanes: { Vector3 } = {
	Vector3.new(0, 0, 0),
	Vector3.new(-0, -0.779599547, 0.626278222),
	Vector3.new(0, 0, 0),
	Vector3.new(0, -0.779599547, -0.626278222),
	Vector3.new(0, 0, 0),
	Vector3.new(0.819152057, -0.573576391, 0),
	Vector3.new(0, 0, 0),
	Vector3.new(-0.819152057, -0.573576391, -0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, 1, 0),
}

-- This is the same camera with the far plane 100 voxels out, roomy enough that
-- bucket and voxel boxes can sit fully inside it.
local roomyFrustumPlanes: { Vector3 } = {
	Vector3.new(0, 0, 0),
	Vector3.new(-0, -0.779599547, 0.626278222),
	Vector3.new(0, 0, 0),
	Vector3.new(0, -0.779599547, -0.626278222),
	Vector3.new(0, 0, 0),
	Vector3.new(0.819152057, -0.573576391, 0),
	Vector3.new(0, 0, 0),
	Vector3.new(-0.819152057, -0.573576391, -0),
	Vector3.new(0, 100, 0),
	Vector3.new(0, 1, 0),
}

return {
	createMockPart = createMockPart,
	createMockModel = createMockModel,
	ingestObjects = ingestObjects,
	fastIngestObjects = fastIngestObjects,
	markInView = markInView,
	stubObjectData = stubObjectData,
	visibleVoxelProof = visibleVoxelProof,
	culledVoxelProof = culledVoxelProof,
	popVolume = popVolume,
	drainVolumeStack = drainVolumeStack,
	patchFunction = patchFunction,
	restorePatches = restorePatches,
	straddlingFrustumPlanes = straddlingFrustumPlanes,
	roomyFrustumPlanes = roomyFrustumPlanes,
}
