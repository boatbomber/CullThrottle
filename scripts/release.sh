#!/bin/sh

set -e

rojo sourcemap sourcemap.project.json -o sourcemap.json

darklua process --config default.darklua.json src/ dist/src
rojo build default.project.json -o CullThrottle.rbxm
wally publish