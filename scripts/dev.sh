#!/bin/sh
set -e

# If DevPackages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    wally install
fi
rojo sourcemap sourcemap.project.json -o sourcemap.json --watch \
    & darklua process --config dev.darklua.json --watch src/ dist/src \
    & darklua process --config dev.darklua.json --watch scripts/run-tests.server.luau dist/run-tests.server.luau \
    & rojo serve dev.project.json