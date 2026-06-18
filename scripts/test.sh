#!/bin/sh
set -e

# If DevPackages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    wally install
fi
darklua process --config dev.darklua.json src/ dist/src
darklua process --config dev.darklua.json scripts/run-tests.server.luau dist/run-tests.server.luau
rojo build dev.project.json --output CullThrottleTest.rbxl
run-in-roblox --place CullThrottleTest.rbxl --script dist/run-tests.server.luau
