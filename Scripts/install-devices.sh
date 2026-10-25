#!/bin/bash
# 把 AquaEcho 装到已配对的 iPhone，并由手机把内嵌手表包推到手表。
#
# 先增量安装。安装日志里如果是一次完成的增量（没有 skip delta），
# 手表包不会被推送，脚本再卸掉手机应用做完整安装。完整安装会清掉
# 手机上的日志、CSV 和录音。
#
# 只安装 iPhone 包。不要把 AquaEchoWatch.app 装到手表：那条链路是
# Mac 和手表之间的 localNetwork，没有 Wi-Fi 时会失败。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.deadlee.AquaEcho"
WATCH_UDID="00008310-000575961420E01E"
DEVICE="${AQUAECHO_DEVICE:-00008150-000525C82E03401C}"
DERIVED_DATA="${AQUAECHO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/AquaEcho-bucrljbqfcogffakvsrlnwkzomox}"
DO_BUILD=1

usage() {
  cat <<EOF
用法: Scripts/install-devices.sh [--device <iPhone UDID>] [--derived-data <路径>] [--no-build]

先构建 iOS scheme（内嵌手表包），再增量安装到 iPhone。
安装日志显示增量完成、手表包没有推送时，卸掉后做完整安装。
卸载会清掉手机上的日志、CSV 和录音。装完后让手表解锁并靠近手机。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE="${2:?缺少 UDID}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:?缺少 DerivedData 路径}"
      shift 2
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "无法识别的参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$DEVICE" == "$WATCH_UDID" ]]; then
  echo "这个脚本只安装到 iPhone。手表包在手机包的 Watch 目录里，由手机经配对推送。" >&2
  exit 1
fi

APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/AquaEcho.app"

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "构建 iOS scheme，手表包会嵌进 AquaEcho.app。"
  build_log="$(mktemp -t aquaecho-build)"
  if ! xcodebuild \
      -project "$ROOT/AquaEcho.xcodeproj" \
      -scheme AquaEcho \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      build >"$build_log" 2>&1; then
    tail -40 "$build_log" >&2
    echo "构建失败，完整日志在 $build_log" >&2
    exit 1
  fi
  rm -f "$build_log"
fi

if [[ ! -d "$APP/Watch/AquaEchoWatch.app" ]]; then
  echo "找不到内嵌手表包: $APP/Watch/AquaEchoWatch.app" >&2
  echo "需要先用 AquaEcho scheme 构建 iOS 包。" >&2
  exit 1
fi

phone_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
watch_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Watch/AquaEchoWatch.app/Info.plist")"
if [[ -z "$phone_version" || "$phone_version" != "$watch_version" ]]; then
  echo "手机构建号（${phone_version:-空}）和内嵌手表构建号（${watch_version:-空}）不一致，已停止，没有卸载。" >&2
  exit 1
fi
echo "待安装构建 ${phone_version}。手机包和内嵌手表包一致。"

apps_json="$(mktemp -t aquaecho-apps)"
xcrun devicectl device info apps --device "$DEVICE" --json-output "$apps_json" --quiet
installed_version="$(python3 - "$apps_json" "$BUNDLE_ID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
apps = data.get("result", {}).get("apps", [])
found = [app for app in apps if app.get("bundleIdentifier") == sys.argv[2]]
print(found[0].get("bundleVersion", "") if found else "")
PY
)"
rm -f "$apps_json"

install_log="$(mktemp -t aquaecho-install)"

install_app() {
  local started
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  xcrun devicectl device install app --device "$DEVICE" "$APP"
  sleep 1
  /usr/bin/log show --start "$started" --style compact \
    --predicate 'subsystem == "com.apple.installcoordination" AND eventMessage CONTAINS "AquaEcho"' \
    >"$install_log" || true
}

phone_reports_version() {
  local apps_json reported
  apps_json="$(mktemp -t aquaecho-apps)"
  xcrun devicectl device info apps --device "$DEVICE" --json-output "$apps_json" --quiet
  reported="$(python3 - "$apps_json" "$BUNDLE_ID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
apps = data.get("result", {}).get("apps", [])
found = [app for app in apps if app.get("bundleIdentifier") == sys.argv[2]]
print(found[0].get("bundleVersion", "") if found else "")
PY
)"
  rm -f "$apps_json"
  if [[ "$reported" != "$phone_version" ]]; then
    echo "手机上的构建号是 ${reported:-未安装}，期望 ${phone_version}。" >&2
    return 1
  fi
}

# 增量安装成功时，Mac 日志只有 iPhone 包的 ComputedDelta，没有手表包推送。
watch_publish_failed() {
  if grep -q "skip delta" "$install_log"; then
    echo "安装跳过了增量，手机会经配对推送手表包。"
    return 1
  fi
  if grep -q "Computing delta" "$install_log" && grep -q "kIXRemoteInstallMessageTypeComplete" "$install_log"; then
    echo "增量安装已完成，安装日志里没有手表包推送。"
    return 0
  fi
  echo "安装日志里看不到增量是否完成，不把这次当成手表发布失败。"
  return 1
}

if [[ -n "$installed_version" ]]; then
  echo "先增量安装到手机（当前构建 ${installed_version}）。"
  install_app
  phone_reports_version
  if watch_publish_failed; then
    echo "手表发布失败，改为完整安装。日志、CSV 和录音会一起删掉。"
    xcrun devicectl device uninstall app --device "$DEVICE" "$BUNDLE_ID"
    install_app
    phone_reports_version
  fi
else
  echo "手机上还没有 ${BUNDLE_ID}，直接完整安装。"
  install_app
  phone_reports_version
fi
rm -f "$install_log"

echo "手机已装上构建 ${phone_version}，内嵌手表也是构建 ${phone_version}。"
echo "让手表解锁并靠近手机，等配对推送完成后再看手表上的构建号。"
