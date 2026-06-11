--!strict

--[[
    We use this singleton to cache the properties we're interested in.
	This way, we can avoid reading from the DataModel every frame,
	which is especially valuable for the properties that don't update often.
]]

local Gizmo = if _G.__DEV__ then require(script.Parent.Gizmo) else nil :: any

local CameraCache = {
	_connections = {} :: { [string]: RBXScriptConnection },
	Object = workspace.CurrentCamera,
	-- This gets bumped whenever the camera or its projection changes shape
	-- (camera replaced, FOV, viewport/aspect). Rigid motion (CFrame changes)
	-- does not bump it. Consumers holding state derived from the frustum planes
	-- must discard that state when they observe a new generation, because no
	-- motion bound relates planes across a projection change.
	Generation = 0,
	CFrame = CFrame.identity,
	Position = Vector3.zero,
	HalfHorizontalFOV = 0,
	HalfVerticalFOV = 0,
	SinHalfHorizontalFOV = 0,
	CosHalfHorizontalFOV = 1,
	SinHalfVerticalFOV = 0,
	CosHalfVerticalFOV = 1,
	TanHalfVertFOV = 0,
	ViewportSize = Vector2.zero,
	AspectRatio = 0,
}

export type CameraCache = typeof(CameraCache)

--[[
	Points the cache at a (possibly new) camera. It refreshes every cached
	property, bumps the generation, and rewires the property change listeners.
]]
function CameraCache.init(camera: Camera?)
	CameraCache.cleanup()
	CameraCache.Generation += 1
	CameraCache.Object = camera

	if not camera then
		-- The CurrentCamera change handler will re-init once one exists.
		return
	end

	CameraCache.cframeChanged()
	CameraCache.viewportSizeChanged()
	CameraCache.fovChanged()

	CameraCache._connections.CFrameChanged =
		camera:GetPropertyChangedSignal("CFrame"):Connect(CameraCache.cframeChanged)
	CameraCache._connections.ViewportSizeChanged =
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(CameraCache.viewportSizeChanged)
	CameraCache._connections.FieldOfViewChanged =
		camera:GetPropertyChangedSignal("MaxAxisFieldOfView"):Connect(CameraCache.fovChanged)
end

--[[
	Disconnects every property change listener on the current camera.
]]
function CameraCache.cleanup()
	for _, connection in CameraCache._connections do
		connection:Disconnect()
	end
	CameraCache._connections = {}
end

--[[
	Refreshes the cached CFrame and Position from the camera. This is rigid
	motion only, so the generation is not bumped. It only runs while a camera
	is wired up, so the cast is safe.
]]
function CameraCache.cframeChanged()
	CameraCache.CFrame = CameraCache.Object.CFrame
	CameraCache.Position = CameraCache.CFrame.Position
end

--[[
	Refreshes the cached viewport size and aspect ratio, then recomputes the
	FOV terms (which depend on the aspect ratio). It only runs while a camera
	is wired up, so the cast is safe.
]]
function CameraCache.viewportSizeChanged()
	CameraCache.ViewportSize = CameraCache.Object.ViewportSize
	CameraCache.AspectRatio = CameraCache.computeAspectRatio(CameraCache.ViewportSize)
	CameraCache.fovChanged()
end

--[[
	Recomputes every cached FOV-derived term and bumps the generation, since a
	projection change invalidates any state derived from the frustum planes.
	It only runs while a camera is wired up, so the cast is safe.
]]
function CameraCache.fovChanged()
	CameraCache.Generation += 1
	CameraCache.TanHalfVertFOV = CameraCache.computeTanHalfVerticalFOV(
		(CameraCache.Object :: Camera).MaxAxisFieldOfView,
		CameraCache.AspectRatio
	)

	CameraCache.HalfVerticalFOV = math.atan(CameraCache.TanHalfVertFOV)
	CameraCache.HalfHorizontalFOV = math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
	CameraCache.SinHalfVerticalFOV = math.sin(CameraCache.HalfVerticalFOV)
	CameraCache.CosHalfVerticalFOV = math.cos(CameraCache.HalfVerticalFOV)
	CameraCache.SinHalfHorizontalFOV = math.sin(CameraCache.HalfHorizontalFOV)
	CameraCache.CosHalfHorizontalFOV = math.cos(CameraCache.HalfHorizontalFOV)
end

--[[
	Computes the viewport's aspect ratio. A zero-height viewport would make
	X/Y inf or NaN and poison the frustum bounds, so fall back to a zero
	aspect ratio instead of dividing by zero.
]]
function CameraCache.computeAspectRatio(viewportSize: Vector2): number
	if viewportSize.Y <= 0 then
		return 0
	end
	return viewportSize.X / viewportSize.Y
end

--[[
	Derives tan(halfVerticalFOV) from MaxAxisFieldOfView, which measures the
	larger viewport axis. On a wide viewport that axis is horizontal, so the
	vertical FOV shrinks by the aspect ratio.
]]
function CameraCache.computeTanHalfVerticalFOV(maxAxisFieldOfView: number, aspectRatio: number): number
	return math.tan(math.rad(maxAxisFieldOfView / 2)) / math.max(aspectRatio, 1)
end

--[[
	Builds the five frustum planes (left, right, top, bottom, far, as
	position/normal pairs in voxel coordinates) plus the frustum's voxel-space
	AABB for the given render distance.
]]
function CameraCache.getPlanesAndBounds(renderDistance: number, voxelSize: number): ({ Vector3 }, Vector3, Vector3)
	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position

	local farPlaneHeight2 = CameraCache.TanHalfVertFOV * renderDistance
	local farPlaneWidth2 = farPlaneHeight2 * CameraCache.AspectRatio
	local farPlaneCFrame = cameraCFrame * CFrame.new(0, 0, -renderDistance)
	local farPlaneTopLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneTopRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, farPlaneHeight2, 0)
	local farPlaneBottomLeft = farPlaneCFrame * Vector3.new(-farPlaneWidth2, -farPlaneHeight2, 0)
	local farPlaneBottomRight = farPlaneCFrame * Vector3.new(farPlaneWidth2, -farPlaneHeight2, 0)

	local upVec, rightVec = cameraCFrame.UpVector, cameraCFrame.RightVector

	-- These normals point out of the frustum, matching the convention in
	-- Frustum.luau's box tests where a positive plane distance means outside.
	local rightNormal = upVec:Cross(cameraPos - farPlaneBottomRight).Unit
	local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
	local topNormal = rightVec:Cross(farPlaneTopRight - cameraPos).Unit
	local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

	-- Plane positions are divided by voxelSize so the whole plane set lives in
	-- voxel coordinates, letting the search test voxel-space boxes against the
	-- planes with no per-call unit conversion. Normals are unchanged by uniform
	-- scaling.
	local cameraPosVoxels = cameraPos / voxelSize
	local frustumPlanes: { Vector3 } = {
		cameraPosVoxels,
		leftNormal,
		cameraPosVoxels,
		rightNormal,
		cameraPosVoxels,
		topNormal,
		cameraPosVoxels,
		bottomNormal,
		farPlaneCFrame.Position / voxelSize,
		cameraCFrame.LookVector,
	}

	local minBound = Vector3.new(
		math.min(cameraPos.X, farPlaneTopLeft.X, farPlaneBottomLeft.X, farPlaneTopRight.X, farPlaneBottomRight.X)
			// voxelSize,
		math.min(cameraPos.Y, farPlaneTopLeft.Y, farPlaneBottomLeft.Y, farPlaneTopRight.Y, farPlaneBottomRight.Y)
			// voxelSize,
		math.min(cameraPos.Z, farPlaneTopLeft.Z, farPlaneBottomLeft.Z, farPlaneTopRight.Z, farPlaneBottomRight.Z)
			// voxelSize
	)
	local maxBound = Vector3.new(
		math.max(cameraPos.X, farPlaneTopLeft.X, farPlaneBottomLeft.X, farPlaneTopRight.X, farPlaneBottomRight.X)
			// voxelSize,
		math.max(cameraPos.Y, farPlaneTopLeft.Y, farPlaneBottomLeft.Y, farPlaneTopRight.Y, farPlaneBottomRight.Y)
			// voxelSize,
		math.max(cameraPos.Z, farPlaneTopLeft.Z, farPlaneBottomLeft.Z, farPlaneTopRight.Z, farPlaneBottomRight.Z)
			// voxelSize
	)

	if _G.__DEV__ and _G.__VISUALIZE__ then
		Gizmo.setColor3(Color3.fromRGB(168, 87, 219))
		Gizmo.setTransparency(0)
		Gizmo.drawLine(cameraPos, farPlaneTopLeft)
		Gizmo.drawLine(cameraPos, farPlaneTopRight)
		Gizmo.drawLine(cameraPos, farPlaneBottomLeft)
		Gizmo.drawLine(cameraPos, farPlaneBottomRight)
		Gizmo.drawLine(farPlaneTopLeft, farPlaneTopRight)
		Gizmo.drawLine(farPlaneTopRight, farPlaneBottomRight)
		Gizmo.drawLine(farPlaneBottomLeft, farPlaneBottomRight)
		Gizmo.drawLine(farPlaneTopLeft, farPlaneBottomLeft)
		Gizmo.setTransparency(0.5)
		Gizmo.drawBox(farPlaneCFrame, Vector3.new(farPlaneWidth2 * 2, farPlaneHeight2 * 2, 1))
		Gizmo.setTransparency(0.7)
		Gizmo.drawTriangle(cameraPos, farPlaneTopLeft, farPlaneBottomLeft)
		Gizmo.drawTriangle(cameraPos, farPlaneTopRight, farPlaneBottomRight)
		Gizmo.drawTriangle(cameraPos, farPlaneTopLeft, farPlaneTopRight)
		Gizmo.drawTriangle(cameraPos, farPlaneBottomLeft, farPlaneBottomRight)
	end

	return frustumPlanes, minBound, maxBound
end

CameraCache.init(workspace.CurrentCamera)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	CameraCache.init(workspace.CurrentCamera)
end)

return CameraCache
