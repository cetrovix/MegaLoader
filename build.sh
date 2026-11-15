#!/bin/zsh
# Сборка DiskLoader.app (Apple Silicon + Intel) с иконкой.
#   ./build.sh            → ставит в /Applications
#   ./build.sh release    → ещё и dist/DiskLoader-<версия>.zip для GitHub Releases
set -e
cd "$(dirname "$0")"
VER=1.5
OUT="build.noindex/DiskLoader.app"
rm -rf build.noindex; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
for a in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $a-apple-macos14.0 main.swift -o build.noindex/DiskLoader-$a
done
lipo -create build.noindex/DiskLoader-arm64 build.noindex/DiskLoader-x86_64 -output "$OUT/Contents/MacOS/DiskLoader"
cp icon/AppIcon.icns "$OUT/Contents/Resources/"
cat > "$OUT/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DiskLoader</string>
<key>CFBundleDisplayName</key><string>DiskLoader</string>
<key>CFBundleIdentifier</key><string>app.diskloader</string>
<key>CFBundleExecutable</key><string>DiskLoader</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>$VER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force --deep -s - "$OUT"
rm -rf /Applications/DiskLoader.app && cp -R "$OUT" /Applications/
echo "OK: /Applications/DiskLoader.app ($VER)"
if [ "$1" = "release" ]; then
  mkdir -p dist; rm -f dist/DiskLoader-$VER.zip dist/DiskLoader-$VER.dmg
  ditto -c -k --keepParent "$OUT" dist/DiskLoader-$VER.zip          # для автообновления внутри приложения
  # DMG с окном «перетащи в Программы» (dmgbuild сам пишет фон и раскладку, без Finder)
  ~/.venvs/dmgbuild/bin/dmgbuild -s dmg_settings.py -D app="$OUT" "DiskLoader $VER" dist/DiskLoader-$VER.dmg >/dev/null
  echo "OK: dist/DiskLoader-$VER.dmg"
fi
