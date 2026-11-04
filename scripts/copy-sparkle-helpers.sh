#!/bin/sh
set -eu

sparkle_framework="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
sparkle_versioned="${sparkle_framework}/Versions/A"
bundle_resources="${BUILT_PRODUCTS_DIR}/Sparkle_Sparkle.bundle/Contents/Resources"
package_resources="${BUILT_PRODUCTS_DIR}/PackageFrameworks/Sparkle.framework/Versions/A/Resources"

if [ ! -d "$sparkle_versioned" ]; then
  echo "error: Sparkle.framework was not embedded before copying its helper tools" >&2
  exit 1
fi

rm -rf "${sparkle_versioned}/Updater.app" "${sparkle_versioned}/Autoupdate"
cp -R "${SRCROOT}/vendor/Sparkle/Helpers/Updater.app" "${sparkle_versioned}/"
cp "${SRCROOT}/vendor/Sparkle/Helpers/Autoupdate" "${sparkle_versioned}/"
(
  cd "$sparkle_framework"
  ln -sfn Versions/Current/Autoupdate Autoupdate
  ln -sfn Versions/Current/Updater.app Updater.app
)

if [ -d "$bundle_resources" ]; then
  mkdir -p "${sparkle_versioned}/Resources"
  rsync -a --force "${bundle_resources}/" "${sparkle_versioned}/Resources/"
  rm -rf "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Sparkle_Sparkle.bundle"
fi

if [ -d "$package_resources" ] && [ -d "$bundle_resources" ]; then
  mkdir -p "$package_resources"
  rsync -a --force "${bundle_resources}/" "${package_resources}/"
fi

for plist in "${sparkle_versioned}/Resources/Info.plist" "${package_resources}/Info.plist"; do
  if [ -f "$plist" ]; then
    plutil -replace CFBundleIdentifier -string "org.sparkle-project.Sparkle" "$plist"
  fi
done

if [ "${MICROGRAVITY_SKIP_EMBED_SIGNING:-0}" != "1" ]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  codesign --force --sign "$identity" "$sparkle_framework"
fi
