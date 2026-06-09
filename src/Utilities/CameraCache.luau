--[[
    We use this singleton to cache the properties we're interested in.
	This way, we can avoid reading from the DataModel every frame,
	especially valuable for the properties that don't update often.
--]]

local Gizmo = if _G.__DEV__ then require(script.Parent.Gizmo) else nil :: any

local CameraCache = {
	_connections = {} :: { [string]: RBXScriptConnection },
	Object = nil :: Camera?,
	CFrame = CFrame.identity,
	Position = Vector3.zero,
	HalfHorizontalFOV = 0,
	HalfVerticalFOV = 0,
	TanHalfVertFOV = 0,
	ViewportSize = Vector2.zero,
	AspectRatio = 0,
}

export type CameraCache = typeof(CameraCache)

function CameraCache.init(camera: Camera?)
	CameraCache.cleanup()

	CameraCache.Object = camera
	if not camera then
		-- The CurrentCamera change handler will re-init once one exists
		return
	end

	CameraCache.cframeChanged()
	CameraCache.viewportSizeChanged()
	CameraCache.fovChanged()

	CameraCache._connections.CFrameChanged =
		CameraCache.Object:GetPropertyChangedSignal("CFrame"):Connect(CameraCache.cframeChanged)
	CameraCache._connections.ViewportSizeChanged =
		CameraCache.Object:GetPropertyChangedSignal("ViewportSize"):Connect(CameraCache.viewportSizeChanged)
	CameraCache._connections.FieldOfViewChanged =
		CameraCache.Object:GetPropertyChangedSignal("MaxAxisFieldOfView"):Connect(CameraCache.fovChanged)
end

function CameraCache.cleanup()
	for _, connection in CameraCache._connections do
		connection:Disconnect()
	end
	CameraCache._connections = {}
end

function CameraCache.cframeChanged()
	CameraCache.CFrame = CameraCache.Object.CFrame
	CameraCache.Position = CameraCache.CFrame.Position
end

function CameraCache.viewportSizeChanged()
	CameraCache.ViewportSize = CameraCache.Object.ViewportSize
	CameraCache.AspectRatio = CameraCache.computeAspectRatio(CameraCache.ViewportSize)
	CameraCache.fovChanged()
end

function CameraCache.fovChanged()
	CameraCache.TanHalfVertFOV =
		CameraCache.computeTanHalfVerticalFOV(CameraCache.Object.MaxAxisFieldOfView, CameraCache.AspectRatio)

	CameraCache.HalfVerticalFOV = math.atan(CameraCache.TanHalfVertFOV)
	CameraCache.HalfHorizontalFOV = math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
end

function CameraCache.computeAspectRatio(viewportSize: Vector2): number
	-- A zero-height viewport would make X/Y inf or NaN and poison the frustum
	-- bounds, so fall back to a zero aspect ratio instead of dividing by zero.
	if viewportSize.Y <= 0 then
		return 0
	end
	return viewportSize.X / viewportSize.Y
end

function CameraCache.computeTanHalfVerticalFOV(maxAxisFieldOfView: number, aspectRatio: number): number
	return math.tan(math.rad(maxAxisFieldOfView / 2)) / math.max(aspectRatio, 1)
end

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

	local rightNormal = upVec:Cross(cameraPos - farPlaneBottomRight).Unit
	local leftNormal = upVec:Cross(farPlaneBottomLeft - cameraPos).Unit
	local topNormal = rightVec:Cross(farPlaneTopRight - cameraPos).Unit
	local bottomNormal = rightVec:Cross(cameraPos - farPlaneBottomRight).Unit

	local frustumPlanes: { Vector3 } = {
		cameraPos,
		leftNormal,
		cameraPos,
		rightNormal,
		cameraPos,
		topNormal,
		cameraPos,
		bottomNormal,
		farPlaneCFrame.Position,
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
