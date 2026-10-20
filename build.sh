#!/bin/zsh
set -eu
task_src="${0:A:h}"
task_app="${APP_OUTPUT:-$task_src/dist/字形檢查器.app}"
task_cache="$task_src/.build-cache"
mkdir -p "$task_cache"
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This build currently targets Apple silicon (arm64)." >&2
  exit 1
fi
if [[ -n "${PYTHON_RUNTIME:-}" ]]; then
  task_python="$PYTHON_RUNTIME"
else
  task_archive="$task_cache/python-3.12.15.tar.gz"
  if [[ ! -f "$task_archive" ]]; then
    curl -fL --retry 3 'https://github.com/astral-sh/python-build-standalone/releases/download/20261009/cpython-3.12.15%2B20261009-aarch64-apple-darwin-install_only_stripped.tar.gz' -o "$task_archive"
  fi
  echo "233f8e15255b3e1d1fd47ea5dd5230dfed803f371138e896e54d98c60ae19f6f  $task_archive" | shasum -a 256 -c -
  mkdir -p "$task_cache/runtime"
  tar -xzf "$task_archive" -C "$task_cache/runtime"
  task_python="$task_cache/runtime/python"
fi
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/runtime/bin" "$task_app/Contents/Resources/runtime/lib" "$task_app/Contents/Resources/packages"
cp "$task_src/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_src/backend.py" "$task_app/Contents/Resources/backend.py"
cp "$task_src/reports.py" "$task_app/Contents/Resources/reports.py"
cp "$task_src/cross_repair.py" "$task_app/Contents/Resources/cross_repair.py"
cp "$task_src/glyph_audit.py" "$task_app/Contents/Resources/glyph_audit.py"
cp -L "$task_python/bin/python3.12" "$task_app/Contents/Resources/runtime/bin/python3"
rsync -a --exclude site-packages --exclude __pycache__ --exclude test --exclude tests "$task_python/lib/python3.12/" "$task_app/Contents/Resources/runtime/lib/python3.12/"
"$task_python/bin/python3.12" -m pip install --disable-pip-version-check --no-deps --upgrade --target "$task_app/Contents/Resources/packages" 'fonttools==4.66.1'
cp "$task_python/lib/python3.12/LICENSE.txt" "$task_app/Contents/Resources/Python-LICENSE.txt"
cp "$task_app/Contents/Resources/packages/fonttools-4.66.1.dist-info/licenses/LICENSE" "$task_app/Contents/Resources/fontTools-LICENSE.txt"
cp "$task_src/LICENSE" "$task_app/Contents/Resources/GlyphCheck-LICENSE.txt"
cp "$task_src/LICENSE-MIT-LEGACY.txt" "$task_app/Contents/Resources/GlyphCheck-Legacy-MIT.txt"
cp "$task_src/THIRD_PARTY_NOTICES.md" "$task_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
swift "$task_src/make_icon.swift" "$task_cache/AppIcon.iconset"
iconutil -c icns "$task_cache/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.0 "$task_src/GlyphCheck.swift" "$task_src/Workbench.swift" "$task_src/ReviewFlow.swift" "$task_src/CrossRepair.swift" "$task_src/GlyphAudit.swift" "$task_src/AutoScreen.swift" "$task_src/UpdateChecker.swift" "$task_src/ProgressStore.swift" "$task_src/WelcomeGuide.swift" "$task_src/Localization.swift" -o "$task_app/Contents/MacOS/GlyphCheck" -framework SwiftUI -framework AppKit -framework CoreText -framework Vision
codesign --force --deep --sign - "$task_app"
echo "$task_app"
