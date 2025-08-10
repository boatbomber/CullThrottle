#!/bin/sh

set -e

OUTPUT=CullThrottleTest.rbxl

# If Packages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    sh scripts/install-packages.sh
fi

darklua process --config dev.darklua.json src/ dist/src \
    && darklua process --config dev.darklua.json scripts/run-tests.server.luau dist/run-tests.server.luau \
    && rojo build dev.project.json --output $OUTPUT \
    && run-in-roblox --place $OUTPUT --script dist/run-tests.server.luau
