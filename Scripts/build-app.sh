#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd -P)"
BUILD_DIRECTORY="${REPOSITORY_ROOT}/build"
APP_PATH="${BUILD_DIRECTORY}/HeadPrivacy.app"
CONTENTS_PATH="${APP_PATH}/Contents"
EXECUTABLE_PATH="${CONTENTS_PATH}/MacOS/HeadPrivacy"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "HeadPrivacy requires an Apple-silicon (arm64) Mac." >&2
    exit 1
fi

if [[ ! -f "${REPOSITORY_ROOT}/Package.swift" || ! -f "${REPOSITORY_ROOT}/Config/Info.plist" ]]; then
    echo "Could not resolve the HeadPrivacy repository root." >&2
    exit 1
fi

if [[ -L "${BUILD_DIRECTORY}" ]]; then
    echo "Refusing to use a symbolic-link build directory: ${BUILD_DIRECTORY}" >&2
    exit 1
fi
mkdir -p -- "${BUILD_DIRECTORY}"

CANONICAL_BUILD_DIRECTORY="$(cd -- "${BUILD_DIRECTORY}" && pwd -P)"
if [[ "${CANONICAL_BUILD_DIRECTORY}" != "${REPOSITORY_ROOT}/build" || "${APP_PATH}" != "${REPOSITORY_ROOT}/build/HeadPrivacy.app" ]]; then
    echo "Refusing to recreate an app bundle outside the repository build directory." >&2
    exit 1
fi
if [[ -L "${APP_PATH}" ]]; then
    echo "Refusing to replace a symbolic-link app bundle: ${APP_PATH}" >&2
    exit 1
fi

cd -- "${REPOSITORY_ROOT}"
swift build --disable-sandbox -c release --arch arm64 -debug-info-format none
RELEASE_BIN_DIRECTORY="$(swift build --disable-sandbox -c release --arch arm64 -debug-info-format none --show-bin-path)"
SOURCE_EXECUTABLE="${RELEASE_BIN_DIRECTORY}/HeadPrivacyApp"
if [[ ! -f "${SOURCE_EXECUTABLE}" || ! -x "${SOURCE_EXECUTABLE}" ]]; then
    echo "Release executable was not produced: ${SOURCE_EXECUTABLE}" >&2
    exit 1
fi

rm -rf -- "${APP_PATH}"
mkdir -p -- "${CONTENTS_PATH}/MacOS"
cp -- "${REPOSITORY_ROOT}/Config/Info.plist" "${CONTENTS_PATH}/Info.plist"
cp -- "${SOURCE_EXECUTABLE}" "${EXECUTABLE_PATH}"
chmod 755 "${EXECUTABLE_PATH}"

/usr/bin/plutil -lint "${CONTENTS_PATH}/Info.plist"
/usr/bin/codesign --force --deep --sign - "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict "${APP_PATH}"

printf '%s\n' "${APP_PATH}"
