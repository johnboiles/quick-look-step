#!/bin/bash

SCRIPT_DIR=$(dirname "$0")

sips -z 16 16     $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_16x16.png
sips -z 32 32     $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png
sips -z 32 32     $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_32x32.png
sips -z 64 64     $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png
sips -z 128 128   $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_128x128.png
sips -z 256 256   $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png
sips -z 256 256   $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_256x256.png
sips -z 512 512   $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png
sips -z 512 512   $SCRIPT_DIR/app-icon.png --out $SCRIPT_DIR/../QuickLookStep/Assets.xcassets/AppIcon.appiconset/icon_512x512.png
