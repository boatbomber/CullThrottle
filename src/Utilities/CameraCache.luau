--[[
    We use this singleton to cache the properties we're interested in.
	This way, we can avoid reading from the DataModel every frame,
	especially valuable for the properties that don't update often.
--]]

local CameraCache = {
	_connections = {},
}

export type CameraCache = typeof(CameraCache)

function CameraCache.init(self: CameraCache, camera: Camera)
	self:cleanup()

	self.Object = camera
	self.CFrame = self.Object.CFrame
	self.Position = self.CFrame.Position
	self.FieldOfView = self.Object.FieldOfView
	self.HalfTanFOV = math.tan(math.rad(self.FieldOfView / 2))
	self.ViewportSize = self.Object.ViewportSize
	self.AspectRatio = self.ViewportSize.X / self.ViewportSize.Y

	self._connections.CFrameChanged = CameraCache.Object:GetPropertyChangedSignal("CFrame"):Connect(function()
		CameraCache.CFrame = CameraCache.Object.CFrame
		CameraCache.Position = CameraCache.CFrame.Position
	end)
	self._connections.FieldOfViewChanged = CameraCache.Object:GetPropertyChangedSignal("FieldOfView"):Connect(function()
		CameraCache.FieldOfView = CameraCache.Object.FieldOfView
		CameraCache.HalfTanFOV = math.tan(math.rad(CameraCache.FieldOfView / 2))
	end)
	self._connections.ViewportSizeChanged = CameraCache.Object
		:GetPropertyChangedSignal("ViewportSize")
		:Connect(function()
			CameraCache.ViewportSize = CameraCache.Object.ViewportSize
			CameraCache.AspectRatio = CameraCache.ViewportSize.X / CameraCache.ViewportSize.Y
		end)
end

function CameraCache.cleanup(self: CameraCache)
	for _, connection in self._connections do
		connection:Disconnect()
	end
	self._connections = {}
end

function CameraCache.getPlanesAndBounds(renderDistance: number, voxelSize: number): ({ Vector3 }, Vector3, Vector3)
	local cameraCFrame = CameraCache.CFrame
	local cameraPos = CameraCache.Position

	local farPlaneHeight2 = CameraCache.HalfTanFOV * renderDistance
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

	return frustumPlanes, minBound, maxBound
end

CameraCache:init(workspace.CurrentCamera)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	CameraCache:init(workspace.CurrentCamera)
end)

return CameraCache
