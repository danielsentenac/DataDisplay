#!/bin/sh
set -e

WORKSPACE_ROOT="$(cd "${PROJECT_DIR}/../../.." && pwd)"

if [ "${CONFIGURATION}" = "Debug" ]; then
  RUST_PROFILE="debug"
  CARGO_ARGS="build -p dd-ffi"
else
  RUST_PROFILE="release"
  CARGO_ARGS="build -p dd-ffi --release"
fi

LIB_NAME="libdd_ffi.dylib"
OUTPUT_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"
SOURCE_LIB="${WORKSPACE_ROOT}/target/${RUST_PROFILE}/${LIB_NAME}"
DEST_LIB="${OUTPUT_DIR}/${LIB_NAME}"

cd "${WORKSPACE_ROOT}"
cargo ${CARGO_ARGS}

mkdir -p "${OUTPUT_DIR}"
cp -f "${SOURCE_LIB}" "${DEST_LIB}"

if [ "${CODE_SIGNING_ALLOWED}" = "YES" ]; then
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${DEST_LIB}"
  else
    codesign --force --sign - --timestamp=none "${DEST_LIB}"
  fi
fi
