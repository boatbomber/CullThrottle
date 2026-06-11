#!/bin/bash
set -e

selene src/
stylua src/ --check
luau-lsp analyze --defs ./.vscode/globalTypes.PluginSecurity.d.luau --platform roblox --sourcemap sourcemap.json src/
bash scripts/test.sh