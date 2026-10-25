#!/bin/bash
# 把 AquaEcho 增量装到已配对的 iPhone，并直接升级手表上的 AquaEchoWatch.app。
#
# 关键：不再为了推送手表包而卸载手机 App。卸载会清掉麦克风、HealthKit
# 等系统授权，导致每次新装都重新申请。手机用 devicectl 覆盖安装，
# 手表用 devicectl 直接覆盖安装；两边都保留已有授权和数据。
# 手表直装失败时只报错，不卸载手机，避免丢权限。

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

先构建 iOS scheme（内嵌手表包），再增量装到 iPhone，并直接覆盖安装手表 App。
不再卸载手机 App；手表直装失败时保留手机安装和权限，重试即可。
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
WATCH_APP="$DERIVED_DATA/Build/Products/Debug-watchos/AquaEchoWatch.app"

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

watch_install() {
  local src="$WATCH_APP"
  if [[ ! -d "$src" ]]; then
    src="$APP/Watch/AquaEchoWatch.app"
  fi
  if [[ ! -d "$src" ]]; then
    echo "找不到手表包: $WATCH_APP 或 $APP/Watch/AquaEchoWatch.app" >&2
    return 1
  fi
  echo "直接覆盖安装手表包（保留已有授权/数据）：$src"
  local attempt
  for attempt in 1 2 3; do
    if xcrun devicectl device install app --device "$WATCH_UDID" "$src"; then
      return 0
    fi
    echo "手表安装第 ${attempt} 次失败（可能是手机正在推送手表包），等待后重试。"
    sleep 5
  done
  echo "手表包仍未安装成功；手机安装和权限已保留，可直接重跑脚本。" >&2
  return 1
}

if [[ -n "$installed_version" ]]; then
  echo "增量覆盖安装到手机（当前构建 ${installed_version}，不卸载）。"
else
  echo "手机上还没有 ${BUNDLE_ID}，首次安装。"
fi
install_app
phone_reports_version
rm -f "$install_log"

# 手机安装会同时触发手表推送；等它完成，避免与直装争同一安装协调器。
sleep 5
watch_install

echo "手机已装上构建 ${phone_version}，手表包同为构建 ${phone_version}。"
echo "手机和手表都是覆盖安装，已有权限和数据应保留；升级后不再反复申请权限。"
