#!/bin/sh

set -e

# If Packages aren't installed, install them.
if [ ! -d "DevPackages" ]; then
    sh scripts/install-packages.sh
fi


rojo sourcemap sourcemap.project.json -o sourcemap.json --watch \
    & DEV=1 darklua process --config .darklua.json --watch src/ dist/src \
    & DEV=1 darklua process --config .darklua.json --watch scripts/run-tests.server.luau dist/run-tests.server.luau \
    & rojo serve dev.project.json