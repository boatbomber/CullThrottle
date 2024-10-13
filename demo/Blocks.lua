local Blocks = {}

function Blocks.createCluster(clusterRegion: Region3, count: number): { BasePart }
	local blocks = {}

	for _ = 1, count do
		-- Get a random point within the cluster region
		local point = clusterRegion.CFrame:PointToWorldSpace(
			Vector3.new(
				math.random(-clusterRegion.Size.X / 2, clusterRegion.Size.X / 2),
				math.random(-clusterRegion.Size.Y / 2, clusterRegion.Size.Y / 2),
				math.random(-clusterRegion.Size.Z / 2, clusterRegion.Size.Z / 2)
			)
		)

		-- Create a new block
		local block = Instance.new("Part")
		block.Name = "Block"
		block.Size = Vector3.one * math.random(1, 20)
		block.CFrame = CFrame.new(point)
			* CFrame.Angles(
				math.random(-math.pi, math.pi),
				math.random(-math.pi, math.pi),
				math.random(-math.pi, math.pi)
			)
		block.Anchored = true
		block.CanCollide = false
		block.CastShadow = false
		block.CanTouch = false
		block.CanQuery = false
		block.Locked = true

		table.insert(blocks, block)
	end

	return blocks
end

function Blocks.generateBlockClusters(clusterCount: number, totalCount: number): { BasePart }
	local blocks = {}

	local blocksPerCluster = totalCount / clusterCount

	for _ = 1, clusterCount do
		local min = Vector3.new(math.random(-1000, 1000), math.random(-500, 500), math.random(-1000, 1000))
		local max = min + Vector3.new(math.random(100, 400), math.random(100, 400), math.random(100, 400))

		local cluster = Blocks.createCluster(Region3.new(min, max), blocksPerCluster)
		for _, block in cluster do
			table.insert(blocks, block)
		end
	end

	return blocks
end

return Blocks
