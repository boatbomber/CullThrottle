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

CameraCache:init(workspace.CurrentCamera)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	CameraCache:init(workspace.CurrentCamera)
end)

return CameraCache
