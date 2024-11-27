------------------------------------------------------------------------------------------------------------------------
-- Name:		gizmo.lua
-- Version:		1.1 (1/29/2021)
-- Author:		Brad Sharp
--
-- Repository:	https://github.com/BradSharp/Roblox-Miscellaneous/tree/master/Gizmo
-- License:		MIT
--
-- Copyright (c) 2021 Brad Sharp
------------------------------------------------------------------------------------------------------------------------

local gizmo = {}

------------------------------------------------------------------------------------------------------------------------
-- Variables
------------------------------------------------------------------------------------------------------------------------

local POINT_SCALE = 5

local RunService = game:GetService("RunService")
local Event = RunService:IsServer() and RunService.Heartbeat or RunService.RenderStepped
local Gizmos = Instance.new("Folder", workspace)

local thickness = 2
local globalScale = 1
local globalOrigin = CFrame.new(0, 0, 0)
local onRender = nil
local cache = {}
local queue = {}
local textQueue = {}
local wedgeQueue = {}

local properties = {
	Adornee = workspace.Terrain,
	AlwaysOnTop = false,
	AdornCullingMode = Enum.AdornCullingMode.Automatic,
	Color3 = Color3.new(0, 1, 0),
	Visible = false,
	Transparency = 0,
	ZIndex = 1,
}

Gizmos.Name = "Gizmos"
Gizmos.Archivable = false

------------------------------------------------------------------------------------------------------------------------
-- Utility
------------------------------------------------------------------------------------------------------------------------

local function style(adornment)
	if adornment:IsA("WedgePart") then
		adornment.Material = Enum.Material.SmoothPlastic
		adornment.Anchored = true
		adornment.TopSurface = Enum.SurfaceType.Smooth
		adornment.BottomSurface = Enum.SurfaceType.Smooth
		adornment.CanCollide = false
		adornment.CanTouch = false
		adornment.CanQuery = false
		adornment.Color = properties.Color3
		adornment.Transparency = properties.Transparency
	else
		for property, value in pairs(properties) do
			adornment[property] = value
		end
	end
end

local function get(class)
	local classCache = cache[class]
	if not classCache then
		classCache = {}
		cache[class] = classCache
	end
	return table.remove(classCache) or Instance.new(class, Gizmos)
end

local function release(instance)
	local class = instance.ClassName
	local classCache = cache[class]
	if not classCache then
		classCache = {}
		cache[class] = classCache
	end
	table.insert(classCache, instance)
end

local function empty()
	-- at some point I'll switch each method out with empty so there's no overhead when gizmos are disabled
end

------------------------------------------------------------------------------------------------------------------------
-- Exports
------------------------------------------------------------------------------------------------------------------------

-- Sets the color of drawn gizmos
function gizmo.setColor(color)
	properties.Color3 = BrickColor.new(color).Color
end

-- Sets the color of drawn gizmos
function gizmo.setColor3(color3)
	properties.Color3 = color3
end

function gizmo.setOrigin(origin)
	globalOrigin = origin
end

-- Sets the transparency of drawn gizmos
function gizmo.setTransparency(transparency)
	properties.Transparency = transparency
end

-- Sets the ZIndex of drawn gizmos
function gizmo.setLayer(index)
	properties.ZIndex = index
end

function gizmo.setScale(scale)
	globalScale = scale
end

-- Resets all custom styling to default values
function gizmo.reset()
	properties.Transparency = 0
	properties.ZIndex = 1
	properties.Color3 = Color3.new(0, 1, 0)
	thickness = 2
	globalScale = 1
	globalOrigin = CFrame.new(0, 0, 0)
end

-- Draws a box at a coordine frame with a given size
function gizmo.drawBox(orientation, size)
	local adornment = get("BoxHandleAdornment")
	style(adornment)
	adornment.Size = size
	adornment.CFrame = globalOrigin * orientation
	table.insert(queue, adornment)
end

-- Draws a wire-box at a coordine frame with a given size
function gizmo.drawWireBox(orientation, size)
	-- If anyone has a better way to do this which is just as performant please let me know
	local x, y, z = size.X / 2, size.Y / 2, size.Z / 2
	local lineWidth = thickness * globalScale
	local sizeX = Vector3.new(size.X + lineWidth, lineWidth, lineWidth)
	local sizeY = Vector3.new(lineWidth, size.Y + lineWidth, lineWidth)
	local sizeZ = Vector3.new(lineWidth, lineWidth, size.Z + lineWidth)
	local relativeOrientation = globalOrigin * orientation
	local adornmentX1 = get("BoxHandleAdornment")
	local adornmentX2 = get("BoxHandleAdornment")
	local adornmentX3 = get("BoxHandleAdornment")
	local adornmentX4 = get("BoxHandleAdornment")
	local adornmentY1 = get("BoxHandleAdornment")
	local adornmentY2 = get("BoxHandleAdornment")
	local adornmentY3 = get("BoxHandleAdornment")
	local adornmentY4 = get("BoxHandleAdornment")
	local adornmentZ1 = get("BoxHandleAdornment")
	local adornmentZ2 = get("BoxHandleAdornment")
	local adornmentZ3 = get("BoxHandleAdornment")
	local adornmentZ4 = get("BoxHandleAdornment")
	style(adornmentX1)
	style(adornmentX2)
	style(adornmentX3)
	style(adornmentX4)
	adornmentX1.Size = sizeX
	adornmentX1.CFrame = relativeOrientation * CFrame.new(0, y, z)
	adornmentX2.Size = sizeX
	adornmentX2.CFrame = relativeOrientation * CFrame.new(0, -y, z)
	adornmentX3.Size = sizeX
	adornmentX3.CFrame = relativeOrientation * CFrame.new(0, y, -z)
	adornmentX4.Size = sizeX
	adornmentX4.CFrame = relativeOrientation * CFrame.new(0, -y, -z)
	style(adornmentY1)
	style(adornmentY2)
	style(adornmentY3)
	style(adornmentY4)
	adornmentY1.Size = sizeY
	adornmentY1.CFrame = relativeOrientation * CFrame.new(x, 0, z)
	adornmentY2.Size = sizeY
	adornmentY2.CFrame = relativeOrientation * CFrame.new(-x, 0, z)
	adornmentY3.Size = sizeY
	adornmentY3.CFrame = relativeOrientation * CFrame.new(x, 0, -z)
	adornmentY4.Size = sizeY
	adornmentY4.CFrame = relativeOrientation * CFrame.new(-x, 0, -z)
	style(adornmentZ1)
	style(adornmentZ2)
	style(adornmentZ3)
	style(adornmentZ4)
	adornmentZ1.Size = sizeZ
	adornmentZ1.CFrame = relativeOrientation * CFrame.new(x, y, 0)
	adornmentZ2.Size = sizeZ
	adornmentZ2.CFrame = relativeOrientation * CFrame.new(-x, y, 0)
	adornmentZ3.Size = sizeZ
	adornmentZ3.CFrame = relativeOrientation * CFrame.new(x, -y, 0)
	adornmentZ4.Size = sizeZ
	adornmentZ4.CFrame = relativeOrientation * CFrame.new(-x, -y, 0)
	table.insert(queue, adornmentX1)
	table.insert(queue, adornmentX2)
	table.insert(queue, adornmentX3)
	table.insert(queue, adornmentX4)
	table.insert(queue, adornmentY1)
	table.insert(queue, adornmentY2)
	table.insert(queue, adornmentY3)
	table.insert(queue, adornmentY4)
	table.insert(queue, adornmentZ1)
	table.insert(queue, adornmentZ2)
	table.insert(queue, adornmentZ3)
	table.insert(queue, adornmentZ4)
end

-- Draws a sphere at a position with a given radius
function gizmo.drawSphere(orientation, radius)
	local adornment = get("SphereHandleAdornment")
	style(adornment)
	adornment.Radius = radius
	adornment.CFrame = globalOrigin * orientation
	table.insert(queue, adornment)
end

-- Draws a wire-sphere at a position with a given radius
function gizmo.drawWireSphere(orientation, radius)
	local offset = globalScale * thickness * 0.5
	local outerRadius, innerRadius = radius + offset, radius - offset
	local relativeOrientation = globalOrigin * orientation
	local adornmentX = get("CylinderHandleAdornment")
	local adornmentY = get("CylinderHandleAdornment")
	local adornmentZ = get("CylinderHandleAdornment")
	style(adornmentX)
	adornmentX.Radius = outerRadius
	adornmentX.InnerRadius = innerRadius
	adornmentX.Height = thickness
	adornmentX.CFrame = relativeOrientation
	style(adornmentY)
	adornmentY.Radius = outerRadius
	adornmentY.InnerRadius = innerRadius
	adornmentY.Height = thickness
	adornmentY.CFrame = relativeOrientation * CFrame.Angles(math.pi * 0.5, 0, 0)
	style(adornmentZ)
	adornmentZ.Radius = outerRadius
	adornmentZ.InnerRadius = innerRadius
	adornmentZ.Height = thickness
	adornmentZ.CFrame = relativeOrientation * CFrame.Angles(0, math.pi * 0.5, 0)
	table.insert(queue, adornmentX)
	table.insert(queue, adornmentY)
	table.insert(queue, adornmentZ)
end

-- Draws a point at a position
function gizmo.drawPoint(position)
	local adornment = get("SphereHandleAdornment")
	style(adornment)
	adornment.Radius = globalScale * thickness * POINT_SCALE * 0.5
	adornment.CFrame = globalOrigin * CFrame.new(position)
	table.insert(queue, adornment)
end

-- Draws a line between two positions
function gizmo.drawLine(from, to)
	local distance = (to - from).magnitude
	local adornment = get("CylinderHandleAdornment")
	style(adornment)
	adornment.Radius = globalScale * thickness * 0.5
	adornment.InnerRadius = 0
	adornment.Height = distance
	adornment.CFrame = globalOrigin * CFrame.lookAt(from, to) * CFrame.new(0, 0, -distance * 0.5)
	table.insert(queue, adornment)
end

-- Draws an arrow between two positions
function gizmo.drawArrow(from, to)
	local coneHeight = thickness * POINT_SCALE * globalScale
	local distance = math.abs((to - from).magnitude - coneHeight)
	local orientation = globalOrigin * CFrame.lookAt(from, to)
	local adornmentLine = get("CylinderHandleAdornment")
	local adornmentCone = get("ConeHandleAdornment")
	style(adornmentLine)
	adornmentLine.Radius = globalScale * thickness * 0.5
	adornmentLine.InnerRadius = 0
	adornmentLine.Height = distance
	adornmentLine.CFrame = orientation * CFrame.new(0, 0, -distance * 0.5)
	style(adornmentCone)
	adornmentCone.Height = coneHeight
	adornmentCone.Radius = coneHeight * 0.5
	adornmentCone.CFrame = orientation * CFrame.new(0, 0, -distance)
	table.insert(queue, adornmentLine)
	table.insert(queue, adornmentCone)
end

-- Draws an arrow at a position in a given direction
function gizmo.drawRay(from, direction)
	gizmo.drawArrow(from, from + direction)
end

-- Draws text on the screen at the given location
function gizmo.drawText(position, text, ...)
	local safeText = tostring(text):format(...)
	local billboard = get("BillboardGui")
	local label = get("TextLabel")
	local textScale = globalScale * 0.25
	billboard.AlwaysOnTop = true
	billboard.StudsOffsetWorldSpace = position
	billboard.Size = UDim2.fromScale(safeText:len() * 0.5 * textScale, textScale)
	billboard.LightInfluence = 0
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.RobotoMono
	label.TextColor3 = properties.Color3
	label.TextTransparency = properties.Transparency
	label.TextScaled = true
	label.Text = safeText
	label.Parent = billboard
	table.insert(queue, label)
	table.insert(textQueue, billboard)
end

function gizmo.drawTriangle(a, b, c)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)

	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end

	ab, ac, bc = b - a, c - a, c - b

	local right = ac:Cross(ab).unit
	local up = bc:Cross(right).unit
	local back = bc.unit

	local height = math.abs(ab:Dot(up))

	local w1 = get("WedgePart")
	style(w1)
	w1.Size = Vector3.new(0, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	table.insert(wedgeQueue, w1)

	local w2 = get("WedgePart")
	style(w2)
	w2.Size = Vector3.new(0, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
	table.insert(wedgeQueue, w2)
end

-- Clears all gizmos that are currently being rendered
function gizmo.clear()
	for _, adornment in ipairs(queue) do
		adornment.Visible = false
		release(adornment)
	end
	queue = {}
end

------------------------------------------------------------------------------------------------------------------------
-- Render
------------------------------------------------------------------------------------------------------------------------

local function enableGizmos()
	if onRender then
		return
	end
	onRender = Event:Connect(function()
		local frame, textFrame, wedgeFrame = queue, textQueue, wedgeQueue
		queue, textQueue, wedgeQueue = {}, {}, {}
		for _, adornment in ipairs(frame) do
			adornment.Visible = true
		end
		for _, adornment in ipairs(textFrame) do
			adornment.Enabled = true
		end
		Event:Wait()
		for _, adornment in ipairs(frame) do
			adornment.Visible = false
			release(adornment)
		end
		for _, adornment in ipairs(textFrame) do
			adornment.Enabled = false
			release(adornment)
		end
		for _, adornment in ipairs(wedgeFrame) do
			adornment.Transparency = 1
			release(adornment)
		end
	end)
end

local function disableGizmos()
	if onRender then
		onRender:Disconnect()
		onRender = nil
	end
end

gizmo.enableGizmos = enableGizmos
gizmo.disableGizmos = disableGizmos

disableGizmos()

------------------------------------------------------------------------------------------------------------------------

return gizmo
