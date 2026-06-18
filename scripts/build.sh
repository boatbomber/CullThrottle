#!/bin/sh
set -e

rm -rf dist/ && darklua process --config default.darklua.json src/ dist/src
rojo sourcemap sourcemap.project.json -o sourcemap.json
rojo build default.project.json -o CullThrottle.rbxm