#!/bin/sh

set -e

rojo sourcemap sourcemap.project.json -o sourcemap.json

darklua process --config default.darklua.json src/ dist/src
rm -rf dist/src/__tests__
rm -rf dist/src/jest.config.luau
rojo build default.project.json -o CullThrottle.rbxm
wally publish