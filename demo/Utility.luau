local Utility = {}

local HEATMAP_COLOR: ColorSequence = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(8, 6, 17)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(92, 27, 79)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(166, 35, 91)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(192, 27, 44)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(253, 136, 104)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 236, 210)),
})

function Utility.evalColorSequence(sequence: ColorSequence, time: number)
	-- If time is 0 or 1, return the first or last value respectively
	if time <= 0 then
		return sequence.Keypoints[1].Value
	elseif time >= 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	-- Otherwise, step through each sequential pair of keypoints
	for i = 1, #sequence.Keypoints - 1 do
		local thisKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]

		if time >= thisKeypoint.Time and time < nextKeypoint.Time then
			-- Calculate how far alpha lies between the points
			local alpha = (time - thisKeypoint.Time) / (nextKeypoint.Time - thisKeypoint.Time)

			-- Evaluate the real value between the points using alpha
			return Color3.new(
				(nextKeypoint.Value.R - thisKeypoint.Value.R) * alpha + thisKeypoint.Value.R,
				(nextKeypoint.Value.G - thisKeypoint.Value.G) * alpha + thisKeypoint.Value.G,
				(nextKeypoint.Value.B - thisKeypoint.Value.B) * alpha + thisKeypoint.Value.B
			)
		end
	end

	return sequence.Keypoints[#sequence.Keypoints].Value
end

function Utility.getHeatmapColor(alpha: number)
	return Utility.evalColorSequence(HEATMAP_COLOR, alpha)
end

function Utility.applyHeatmapColor(object: Instance, alpha: number)
	local color = Utility.getHeatmapColor(alpha)
	if object:IsA("BasePart") then
		object.Color = object.Color:Lerp(color, 0.2)
	elseif object:IsA("TextLabel") then
		object.TextColor3 = color
	elseif object:IsA("GuiObject") then
		object.BackgroundColor3 = color
	end
end

return Utility
