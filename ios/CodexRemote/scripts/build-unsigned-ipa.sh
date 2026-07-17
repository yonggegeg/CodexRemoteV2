#!/bin/bash
set -euo pipefail

PROJECT="CodexRemote.xcodeproj"
SCHEME="CodexRemote"
CONFIGURATION="Release"
ARCHIVE_PATH="build/CodexRemote.xcarchive"
EXPORT_PATH="build/export"
IPA_OUT="build/CodexRemote-unsigned.ipa"

rm -rf build
mkdir -p build "$EXPORT_PATH"

# 编译 iOS 真机 Release 包。未配置证书时可先生成 archive，但导出可安装 IPA 仍需要签名。
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

APP_PATH="$ARCHIVE_PATH/Products/Applications/CodexRemote.app"
if [ ! -d "$APP_PATH" ]; then
  echo "App not found: $APP_PATH"
  exit 1
fi

# 生成未签名 IPA：可用于后续重签名，不保证能直接安装。
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/
cd build
zip -qry "CodexRemote-unsigned.ipa" Payload
cd - >/dev/null

echo "IPA created: $IPA_OUT"
