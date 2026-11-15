#!/bin/zsh
# Сборка MegaLoader.app (Apple Silicon + Intel) с иконкой.
#   ./build.sh            → ставит в /Applications
#   ./build.sh release    → ещё и dist/MegaLoader-<версия>.zip для GitHub Releases
set -e
cd "$(dirname "$0")"
VER=1.7.2
OUT="build.noindex/MegaLoader.app"
rm -rf build.noindex; mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
for a in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $a-apple-macos14.0 main.swift -o build.noindex/MegaLoader-$a
done
lipo -create build.noindex/MegaLoader-arm64 build.noindex/MegaLoader-x86_64 -output "$OUT/Contents/MacOS/MegaLoader"
cp icon/AppIcon.icns "$OUT/Contents/Resources/"
cat > "$OUT/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MegaLoader</string>
<key>CFBundleDisplayName</key><string>MegaLoader</string>
<key>CFBundleIdentifier</key><string>app.diskloader</string>
<key>CFBundleExecutable</key><string>MegaLoader</string>
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
rm -rf /Applications/MegaLoader.app /Applications/DiskLoader.app && cp -R "$OUT" /Applications/   # DiskLoader — старое имя
echo "OK: /Applications/MegaLoader.app ($VER)"
if [ "$1" = "release" ]; then
  mkdir -p dist; rm -f dist/MegaLoader-$VER.zip dist/MegaLoader-$VER.dmg
  ditto -c -k --keepParent "$OUT" dist/MegaLoader-$VER.zip          # для автообновления внутри приложения
  # DMG с окном «перетащи в Программы» (dmgbuild сам пишет фон и раскладку, без Finder)
  ~/.venvs/dmgbuild/bin/dmgbuild -s dmg_settings.py -D app="$OUT" "MegaLoader $VER" dist/MegaLoader-$VER.dmg >/dev/null
  echo "OK: dist/MegaLoader-$VER.dmg"
fi
