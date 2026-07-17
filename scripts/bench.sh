#!/bin/sh
set -e

# The bench place holds only the library, so the jest runner can't compete
# with the benchmark for the clock.
darklua process --config dev.darklua.json src/ dist/src
darklua process --config dev.darklua.json scripts/run-bench.server.luau dist/run-bench.server.luau
rojo build bench.project.json --output CullThrottleBench.rbxl
run-in-roblox --place CullThrottleBench.rbxl --script dist/run-bench.server.luau
