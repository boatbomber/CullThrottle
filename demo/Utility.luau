local Utility = {}

local HEATMAP_COLOR: ColorSequence = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(8, 6, 17)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(92, 27, 79)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(166, 35, 91)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(192, 27, 44)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(253, 136, 104)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 236, 210)),
})

--[[
	Samples a ColorSequence at the given time (0 to 1), interpolating between
	the keypoints that bracket it.
]]
function Utility.evalColorSequence(sequence: ColorSequence, time: number)
	if time <= 0 then
		return sequence.Keypoints[1].Value
	elseif time >= 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	for i = 1, #sequence.Keypoints - 1 do
		local thisKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]

		if time >= thisKeypoint.Time and time < nextKeypoint.Time then
			local alpha = (time - thisKeypoint.Time) / (nextKeypoint.Time - thisKeypoint.Time)

			return Color3.new(
				(nextKeypoint.Value.R - thisKeypoint.Value.R) * alpha + thisKeypoint.Value.R,
				(nextKeypoint.Value.G - thisKeypoint.Value.G) * alpha + thisKeypoint.Value.G,
				(nextKeypoint.Value.B - thisKeypoint.Value.B) * alpha + thisKeypoint.Value.B
			)
		end
	end

	return sequence.Keypoints[#sequence.Keypoints].Value
end

--[[
	Returns the heatmap color for an alpha from 0 (cold) to 1 (hot).
]]
function Utility.getHeatmapColor(alpha: number)
	return Utility.evalColorSequence(HEATMAP_COLOR, alpha)
end

--[[
	Applies the heatmap color for the given alpha to the object. A part's color
	lerps toward it for a smoother fade, while a text label's text color or any
	other gui object's background color is set to it outright.
]]
function Utility.applyHeatmapColor(object: Instance, alpha: number)
	local color = Utility.getHeatmapColor(alpha)
	if object:IsA("BasePart") then
		object.Color = object.Color:Lerp(color, 0.1)
	elseif object:IsA("TextLabel") then
		object.TextColor3 = color
	elseif object:IsA("GuiObject") then
		object.BackgroundColor3 = color
	end
end

return Utility
