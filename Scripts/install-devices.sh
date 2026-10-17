#!/bin/bash
# 把 AquaEcho 装到已配对的 iPhone，并由手机把内嵌手表包推到手表。
#
# devicectl 在手机上已经有这个应用时走增量更新。Mac 上的命令在 iPhone
# 应用更新完成时就返回，系统不会把 Watch/AquaEchoWatch.app 再推一次，
# 手表会停在上一版。卸掉手机应用后，LaunchServices 没有安装记录，增量
# 被跳过，这次完整安装才会经配对推送手表包。
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

先构建 iOS scheme（内嵌手表包），备份手机 Documents，卸掉已安装的
${BUNDLE_ID}，再完整安装。装完后让手表解锁并靠近手机，两边界面的构建号才会变成同一版。
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

backup_dir=""
if [[ -n "$installed_version" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$HOME/Library/Application Support/AquaEcho/install-backups/$stamp"
  mkdir -p "$backup_dir"
  echo "备份 Documents 到 ${backup_dir}（当前手机构建 ${installed_version}）。"
  if ! xcrun devicectl device copy from \
      --device "$DEVICE" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source Documents \
      --destination "$backup_dir"; then
    # 目标必须已存在。Documents 若被写成文件，拷到目录会失败，再落到一个文件路径。
    if ! xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents \
        --destination "$backup_dir/Documents-recovered"; then
      echo "Documents 没有备份下来，已停止，没有卸载。" >&2
      exit 1
    fi
    echo "手机上的 Documents 是文件。内容已备份，卸载后会恢复成目录。"
  fi
  echo "卸掉手机上的 ${BUNDLE_ID}，让下一次安装跳过增量。"
  xcrun devicectl device uninstall app --device "$DEVICE" "$BUNDLE_ID"
else
  echo "手机上还没有 ${BUNDLE_ID}，直接完整安装。"
fi

echo "安装 $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"

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
  exit 1
fi

if [[ -n "$backup_dir" ]]; then
  shopt -s nullglob
  files=("$backup_dir"/*)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Documents 是空的，不用拷回。"
  else
    restore_failed=0
    for file in "${files[@]}"; do
      [[ -f "$file" ]] || continue
      name="$(basename "$file")"
      # 必须写到 Documents/文件名。写到 Documents 本身会把目录变成文件。
      if ! xcrun devicectl device copy to \
          --device "$DEVICE" \
          --domain-type appDataContainer \
          --domain-identifier "$BUNDLE_ID" \
          --source "$file" \
          --destination "Documents/${name}"; then
        restore_failed=1
      fi
    done
    if [[ "$restore_failed" -eq 1 ]]; then
      echo "新容器还没有 Documents 目录，应用第一次打开时才会创建。备份仍在 ${backup_dir}"
    else
      echo "已把 Documents 拷回手机。"
    fi
  fi
fi

echo "手机已装上构建 ${phone_version}，内嵌手表也是构建 ${phone_version}。"
echo "让手表解锁并靠近手机，等配对推送完成后再看手表上的构建号。"
