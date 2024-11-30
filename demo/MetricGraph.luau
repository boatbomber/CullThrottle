--!strict

local Utility = require(script.Parent.Utility)

local MetricGraph = {}
MetricGraph.__index = MetricGraph

type MetricGraphProto = {
	Frame: Frame,
	Min: number,
	Max: number,
	FormatStr: string,
	_data: { number },
	_lineFrames: { Frame },
	_minLabel: TextLabel,
	_maxLabel: TextLabel,
	_currentLabel: TextLabel,
	_avgLabel: TextLabel,
	_titleLabel: TextLabel,
}

export type MetricGraph = typeof(setmetatable({} :: MetricGraphProto, MetricGraph))

function MetricGraph.new(title: string, data: { number }, min: number, max: number, formatStr: string?): MetricGraph
	local self = setmetatable({
		Min = min,
		Max = max,
		FormatStr = formatStr or "%d",
		_lineFrames = {},
		_data = data,
	}, MetricGraph)

	self.Frame = Instance.new("Frame")
	self.Frame.Size = UDim2.fromOffset(300, 120)
	self.Frame.BackgroundColor3 = Color3.fromRGB(113, 152, 181)
	self.Frame.BackgroundTransparency = 0.3
	self.Frame.BorderSizePixel = 0

	self._titleLabel = Instance.new("TextLabel")
	self._titleLabel.ZIndex = 10
	self._titleLabel.Name = "title"
	self._titleLabel.Text = title
	self._titleLabel.Size = UDim2.new(1, 0, 0, 20)
	self._titleLabel.Position = UDim2.new(0, 0, 0, 0)
	self._titleLabel.BackgroundTransparency = 1
	self._titleLabel.TextColor3 = Color3.new(1, 1, 1)
	self._titleLabel.TextSize = 17
	self._titleLabel.TextStrokeColor3 = Color3.new()
	self._titleLabel.TextStrokeTransparency = 0
	self._titleLabel.Font = Enum.Font.RobotoMono
	self._titleLabel.Parent = self.Frame

	self._avgLabel = Instance.new("TextLabel")
	self._avgLabel.ZIndex = 10
	self._avgLabel.Name = "avg"
	self._avgLabel.Text = ""
	self._avgLabel.Size = UDim2.new(1, 0, 0, 16)
	self._avgLabel.Position = UDim2.new(0, 0, 0, 20)
	self._avgLabel.BackgroundTransparency = 1
	self._avgLabel.TextColor3 = Color3.new(1, 1, 1)
	self._avgLabel.TextSize = 13
	self._avgLabel.TextStrokeColor3 = Color3.new()
	self._avgLabel.TextStrokeTransparency = 0
	self._avgLabel.Font = Enum.Font.RobotoMono
	self._avgLabel.Parent = self.Frame

	self._maxLabel = Instance.new("TextLabel")
	self._maxLabel.ZIndex = 5
	self._maxLabel.Name = "max"
	self._maxLabel.Text = "0"
	self._maxLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._maxLabel.Size = UDim2.new(0, 30, 0, 20)
	self._maxLabel.Position = UDim2.new(0, 2, 0, 0)
	self._maxLabel.BackgroundTransparency = 1
	self._maxLabel.TextColor3 = Color3.new(1, 1, 1)
	self._maxLabel.TextSize = 14
	self._maxLabel.TextStrokeColor3 = Color3.new()
	self._maxLabel.TextStrokeTransparency = 0
	self._maxLabel.Font = Enum.Font.RobotoMono
	self._maxLabel.Parent = self.Frame

	self._minLabel = Instance.new("TextLabel")
	self._minLabel.ZIndex = 5
	self._minLabel.Name = "min"
	self._minLabel.Text = "0"
	self._minLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._minLabel.Size = UDim2.new(0, 30, 0, 20)
	self._minLabel.Position = UDim2.new(0, 2, 1, -20)
	self._minLabel.BackgroundTransparency = 1
	self._minLabel.TextColor3 = Color3.new(1, 1, 1)
	self._minLabel.TextSize = 14
	self._minLabel.TextStrokeColor3 = Color3.new()
	self._minLabel.TextStrokeTransparency = 0
	self._minLabel.Font = Enum.Font.RobotoMono
	self._minLabel.Parent = self.Frame

	self._currentLabel = Instance.new("TextLabel")
	self._currentLabel.ZIndex = 5
	self._currentLabel.Name = "latest"
	self._currentLabel.Text = "0"
	self._currentLabel.TextXAlignment = Enum.TextXAlignment.Right
	self._currentLabel.Size = UDim2.new(0, 30, 0, 20)
	self._currentLabel.Position = UDim2.new(1, -2, 0.5, 0)
	self._currentLabel.AnchorPoint = Vector2.new(1, 0.5)
	self._currentLabel.BackgroundTransparency = 1
	self._currentLabel.TextColor3 = Color3.new(1, 1, 1)
	self._currentLabel.TextSize = 16
	self._currentLabel.TextStrokeColor3 = Color3.new()
	self._currentLabel.TextStrokeTransparency = 0
	self._currentLabel.Font = Enum.Font.RobotoMono
	self._currentLabel.Parent = self.Frame

	local count = #self._data
	for i = 1, count do
		local line = Instance.new("Frame")
		line.BackgroundColor3 = Color3.new()
		line.BorderSizePixel = 0
		line.Name = tostring(i)
		line.Size = UDim2.new(1 / count, 0, 0, 3)
		line.Position = UDim2.new((i - 1) / count, 0, 1, 0)
		line.AnchorPoint = Vector2.new(0, 1)
		line.Parent = self.Frame
		self._lineFrames[i] = line
	end

	self:refresh()

	return self
end

function MetricGraph.refresh(self: MetricGraph)
	local trueMin, trueMax = math.min(table.unpack(self._data)), math.max(table.unpack(self._data))
	local min, max = math.min(self.Min, trueMin), math.max(self.Max, trueMax)

	self._maxLabel.Text = string.format(self.FormatStr, max)
	self._minLabel.Text = string.format(self.FormatStr, min)
	self._currentLabel.Text = string.format(self.FormatStr, self._data[#self._data])

	local range = max - min
	local sum = 0
	for i, datapoint in self._data do
		sum += datapoint
		local height = if range == 0 then 0.5 else math.map((datapoint - min) / range, 0, 1, 0.05, 0.95)
		local line = self._lineFrames[i]
		if line then
			line.Size = UDim2.fromScale(1 / #self._data, height)
			line.BackgroundColor3 = Utility.getHeatmapColor((datapoint - self.Min) / (self.Max - self.Min))
		end
	end

	self._avgLabel.Text = string.format(self.FormatStr, sum / #self._data)
end

function MetricGraph.measure(self: MetricGraph, datapoint: number)
	table.insert(self._data, datapoint)
	table.remove(self._data, 1)
	self:refresh()
end

return MetricGraph
