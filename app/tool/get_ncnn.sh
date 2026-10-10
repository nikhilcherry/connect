#!/usr/bin/env bash
# Fetches the prebuilt ncnn (Vulkan) libraries the Drive Mode road scan compiles against.
# They are ~50 MB and not committed. Run once from app/:   bash tool/get_ncnn.sh
set -euo pipefail

VERSION=20260526
NAME="ncnn-${VERSION}-android-vulkan"
DEST="android/third_party"
URL="https://github.com/Tencent/ncnn/releases/download/${VERSION}/${NAME}.zip"

if [ -d "${DEST}/${NAME}/arm64-v8a" ]; then
  echo "ncnn already in ${DEST}/${NAME}"
  exit 0
fi

mkdir -p "${DEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
echo "downloading ${URL}"
curl -fL -o "${TMP}/ncnn.zip" "${URL}"

if command -v unzip >/dev/null 2>&1; then
  unzip -q "${TMP}/ncnn.zip" -d "${DEST}"
else
  python3 -m zipfile -e "${TMP}/ncnn.zip" "${DEST}"
fi

# Only the ABIs the app builds (arm64-v8a for phones, x86_64 for the emulator).
for abi in armeabi-v7a riscv64 x86; do rm -rf "${DEST}/${NAME}/${abi}"; done
echo "ncnn ready in ${DEST}/${NAME}"
