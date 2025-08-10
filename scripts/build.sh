#!/bin/sh

set -e

rojo sourcemap sourcemap.project.json -o sourcemap.json

darklua process --config .darklua.json src/ dist/src
rojo build build.project.json -o CullThrottle.rbxm