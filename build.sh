#!/bin/bash
# Builds ShotShelf.app and packages it in a DMG. Needs only the Xcode
# Command Line Tools (no Xcode project).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/ShotShelf.app"
NAME="ShotShelf"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
# GitHub repo the app checks for updates (owner/name).
UPDATE_REPO="${UPDATE_REPO:-antaflu/shotshelf}"
DEPLOY="13.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
ARCHS=()
for arch in arm64 x86_64; do
  if swiftc -O -target "${arch}-apple-macos${DEPLOY}" \
       -o "$BUILD/$NAME-$arch" "$ROOT"/Sources/*.swift 2>/dev/null; then
    ARCHS+=("$BUILD/$NAME-$arch")
    echo "    $arch ok"
  else
    echo "    $arch skipped"
  fi
done
[ ${#ARCHS[@]} -gt 0 ] || { echo "compilation failed"; exit 1; }
lipo -create "${ARCHS[@]}" -output "$APP/Contents/MacOS/$NAME"
rm -f "${ARCHS[@]}"

echo "==> Icon"
swiftc -O -o "$BUILD/makeicon" "$ROOT/Tools/MakeIcon.swift"
"$BUILD/makeicon" "$BUILD" >/dev/null
rm -f "$BUILD/makeicon"
iconutil -c icns "$BUILD/$NAME.iconset" -o "$APP/Contents/Resources/$NAME.icns"
rm -rf "$BUILD/$NAME.iconset"

echo "==> Bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>nl.shotshelf.app</string>
    <key>CFBundleIconFile</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOY</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>ShotShelf moves your screenshots to the Desktop when you close the shelf.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>ShotShelf moves your screenshots to the folder you chose in Settings.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>ShotShelf moves your screenshots to the folder you chose in Settings.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>ShotShelf moves your screenshots to the folder you chose in Settings.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>ShotShelf moves your screenshots to the folder you chose in Settings.</string>
    <key>ShotShelfUpdateRepo</key><string>$UPDATE_REPO</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>ShotShelf Shelf</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>nl.shotshelf.shelf</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>nl.shotshelf.shelf</string>
            <key>UTTypeDescription</key><string>ShotShelf Shelf</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.zip-archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>shelf</string></array></dict>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key><string>ShotShelf</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad hoc)"
codesign --force --deep --sign - --options runtime "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"

echo "==> DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO \
  -quiet "$BUILD/$NAME-$VERSION.dmg"
rm -rf "$STAGE"

echo
echo "Done:"
echo "  App: $APP"
echo "  DMG: $BUILD/$NAME-$VERSION.dmg"
echo "  Updates via: github.com/$UPDATE_REPO"
