#!/usr/bin/env bash
# Rebuild the Rede 3D device models: see tool/blender/README.md.
#   tool/blender/factory.sh              re-render every changed model + regenerate code
#   tool/blender/factory.sh siren        just that model
#   tool/blender/factory.sh --force      everything
#   tool/blender/factory.sh --codegen    only the Dart registry, pubspec and docs
set -euo pipefail
cd "$(dirname "$0")/../.."
B="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
"$B" -b --factory-startup --python-exit-code 1 --python tool/blender/model_factory.py -- "$@"
