#!/bin/sh

set -e

# If Packages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    sh scripts/install-packages.sh
fi


rojo sourcemap sourcemap.project.json -o sourcemap.json --watch \
    & darklua process --config dev.darklua.json --watch src/ dist/src \
    & darklua process --config dev.darklua.json --watch scripts/run-tests.server.luau dist/run-tests.server.luau \
    & rojo serve dev.project.json