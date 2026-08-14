#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build-release"
DIST_DIR="${PROJECT_DIR}/dist"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/copyding-release.XXXXXX")"
APP_DIR="${STAGE_DIR}/CopyDing.app"
CONTENTS_DIR="${APP_DIR}/Contents"
trap 'rm -rf "${STAGE_DIR}"' EXIT

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"

SWIFT_OPTIONS=()
if [[ "${COPYDING_DISABLE_SWIFT_SANDBOX:-0}" == "1" ]]; then
  SWIFT_OPTIONS+=(--disable-sandbox)
fi

swift build \
  "${SWIFT_OPTIONS[@]}" \
  --package-path "${PROJECT_DIR}" \
  --scratch-path "${BUILD_DIR}" \
  --configuration release \
  --arch arm64 \
  --arch x86_64

cp "${BUILD_DIR}/apple/Products/Release/CopyDing" "${CONTENTS_DIR}/MacOS/CopyDing"
cp "${PROJECT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${PROJECT_DIR}/Assets/CopyDing.icns" "${CONTENTS_DIR}/Resources/CopyDing.icns"
chmod 755 "${CONTENTS_DIR}/MacOS/CopyDing"
xattr -cr "${APP_DIR}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "${CODESIGN_IDENTITY}" --identifier com.copyding.utility "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Info.plist")"
ARCHIVE="${DIST_DIR}/CopyDing-v${VERSION}.zip"
ditto -c -k --keepParent "${APP_DIR}" "${ARCHIVE}"

echo "Created ${ARCHIVE}"
