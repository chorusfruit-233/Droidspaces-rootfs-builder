#!/usr/bin/env bash

# 为 Kali Linux（Debian 系）构建并安装带旧内核兼容补丁的完整 systemd 257 包族。
#
# 实现方式（容器内源码编译）：
#   1. 下载 Debian trixie 官方源码包 systemd_257.13-1~deb13u1（校验 SHA-256）；
#   2. 应用 0001-droidspaces-old-kernel-compat.patch（Android 4.14/4.19 旧内核兼容）；
#   3. 用发行版原生打包规则（dpkg-buildpackage）现场编译完整 DEB 包族；
#   4. 通过 apt 安装，替换 Kali rolling 的 systemd 258+；
#   5. apt-mark hold 锁定，防止滚动升级覆盖兼容版本。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

readonly SYSTEMD257_TARGET_MAJOR=257
readonly SYSTEMD257_STATE="/etc/droidspaces-systemd257"
readonly SOURCE_VERSION="257.13"
readonly DEBIAN_VERSION="257.13-1~deb13u1"
readonly REBUILD_VERSION="${DEBIAN_VERSION}+droidspaces1"
readonly POOL_URL="https://deb.debian.org/debian/pool/main/s/systemd"
readonly DSC_SHA256="1b3405d671a82d1e20c9d99f52d4336aafe8543b28d04e91b7f1f586d3a667c7"
readonly ORIG_SHA256="1eb7d5f9ff8a426ff880a3cded9ce819613ba8003ac5ddde9eca162f14ddabe7"
readonly DEBIAN_TAR_SHA256="9c6e435d613b996efcdb3b7dd9a4cebaa745333a3f64dc722f3fad646f1fdc1a"
readonly DEFAULT_PATCH_FILE="/usr/local/share/droidspaces/0001-droidspaces-old-kernel-compat.patch"

PATCH_FILE="${SYSTEMD257_PATCH_FILE:-$DEFAULT_PATCH_FILE}"
WORK_DIR=""
CURRENT_VERSION_LINE=""
PREVIOUS_VERSION_LINE=""

declare -a BUILT_FILES=()
declare -a PACKAGE_NAMES=()
declare -a SELECTED_NAMES=()
declare -a SELECTED_FILES=()
declare -a MANAGED_NAMES=()
declare -A PACKAGE_PATH=()
declare -A PACKAGE_VERSION=()
declare -A SELECTED_SET=()

log() {
  printf '[systemd257] %s\n' "$*"
}

die() {
  printf '[systemd257] error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

require_root() {
  if (( EUID != 0 )); then
    die "请用 root 运行：sudo bash systemd257.sh"
  fi
}

require_kali() {
  [[ -r /etc/os-release ]] || die "缺少 /etc/os-release，无法确认发行版"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID,,}" == kali ]] ||
    die "此脚本仅支持 Kali Linux，当前 ID=${ID:-unknown}"
}

require_arm64() {
  local architecture

  command -v dpkg >/dev/null 2>&1 || die "缺少 dpkg"
  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == arm64 ]] || die "Kali 包族仅支持 arm64，当前为 $architecture"
}

systemd_version_line() {
  local candidate line

  if command -v systemctl >/dev/null 2>&1; then
    line="$(systemctl --version 2>/dev/null | sed -n '1p')"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi

  for candidate in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    if [[ -x "$candidate" ]]; then
      line="$("$candidate" --version 2>/dev/null | sed -n '1p')"
      if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
        return 0
      fi
    fi
  done

  return 1
}

systemd_major_from_line() {
  printf '%s\n' "$1" | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+/) {
          sub(/[^0-9].*$/, "", $i)
          print $i
          exit
        }
      }
    }
  '
}

package_version_major() {
  local version="${1#*:}"

  if [[ "$version" =~ ^([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

is_systemd_family_name() {
  local name="${1%%:*}"

  [[ "$name" == systemd || "$name" == systemd-* || "$name" == udev ||
     "$name" == libsystemd* || "$name" == libudev* ||
     "$name" == libpam-systemd || "$name" == libnss-systemd ||
     "$name" == libnss-resolve || "$name" == libnss-myhostname ||
     "$name" == libnss-mymachines ]]
}

list_installed_family_packages() {
  local name version status

  while IFS=$'\t' read -r name version status; do
    name="${name%%:*}"
    if [[ "$status" == ii* ]] && is_systemd_family_name "$name"; then
      printf '%s\t%s\n' "$name" "$version"
    fi
  done < <(dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null)
}

has_mismatched_family_packages() {
  local name version major

  while IFS=$'\t' read -r name version; do
    major="$(package_version_major "$version" || true)"
    if [[ "$major" != "$SYSTEMD257_TARGET_MAJOR" ]]; then
      log "检测到非 257 包：$name $version"
      return 0
    fi
  done < <(list_installed_family_packages)
  return 1
}

install_build_tooling() {
  log "installing source-build tooling"
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl devscripts dpkg-dev equivs patch xz-utils
}

verify_checksum() {
  local expected="$1"
  local file="$2"
  local actual

  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] ||
    die "SHA-256 校验失败：$file（期望 $expected，实际 $actual）"
}

download_sources() {
  local sources_dir="$WORK_DIR/sources"
  local dsc_file="systemd_${DEBIAN_VERSION}.dsc"
  local orig_file="systemd_${SOURCE_VERSION}.orig.tar.gz"
  local debian_file="systemd_${DEBIAN_VERSION}.debian.tar.xz"

  mkdir -p "$sources_dir"
  log "downloading Debian systemd $DEBIAN_VERSION source package"
  for name in "$dsc_file" "$orig_file" "$debian_file"; do
    curl --proto '=https' --tlsv1.2 -fL --retry 5 --retry-all-errors \
      --connect-timeout 30 "$POOL_URL/$name" -o "$sources_dir/$name" ||
      die "无法下载 $name"
  done

  verify_checksum "$DSC_SHA256" "$sources_dir/$dsc_file"
  verify_checksum "$ORIG_SHA256" "$sources_dir/$orig_file"
  verify_checksum "$DEBIAN_TAR_SHA256" "$sources_dir/$debian_file"
  log "source package checksums verified"
}

build_package_family() {
  local source_dir="$WORK_DIR/source"

  cd "$WORK_DIR"
  dpkg-source -x "sources/systemd_${DEBIAN_VERSION}.dsc" source
  cd "$source_dir"

  [[ -f "$PATCH_FILE" ]] || die "缺少旧内核兼容补丁：$PATCH_FILE"
  log "applying $PATCH_FILE"
  patch --dry-run -p1 < "$PATCH_FILE" ||
    die "补丁 $PATCH_FILE 无法应用到 systemd $SOURCE_VERSION 源码"
  patch -p1 < "$PATCH_FILE"

  export DEBFULLNAME="Droidspaces Builder"
  export DEBEMAIL="noreply@github.com"
  export DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck noautodbgsym"
  export DEB_BUILD_PROFILES="pkg.systemd.nobpf"
  dch --newversion "$REBUILD_VERSION" --distribution unstable \
    "Rebuild the complete systemd 257 package family with Android old-kernel compatibility."

  log "installing source package build dependencies (this may take a while)"
  mk-build-deps --install --remove \
    --tool='apt-get -y --no-install-recommends' debian/control

  log "building the complete DEB package family (this takes a while)"
  dpkg-buildpackage -b -uc -us
}

collect_built_packages() {
  mapfile -t BUILT_FILES < <(
    find "$WORK_DIR" -maxdepth 1 -type f -name '*.deb' ! -name '*-dbgsym_*' -printf '%f\n' | sort
  )
  (( ${#BUILT_FILES[@]} >= 20 )) ||
    die "构建产物异常：仅得到 ${#BUILT_FILES[@]} 个 DEB 包"
  log "built ${#BUILT_FILES[@]} DEB packages"
}

register_package() {
  local name="$1"
  local version="$2"
  local architecture="$3"
  local path="$4"
  local major

  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || die "软件包名无效：$name"
  is_systemd_family_name "$name" || die "构建产物包含非 systemd 包族成员：$name"
  [[ -z "${PACKAGE_PATH[$name]+present}" ]] || die "构建产物包含重复软件包：$name"

  major="$(package_version_major "$version" || true)"
  [[ "$major" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
    die "软件包 $name 的版本不是 257：$version"

  case "$architecture" in
    arm64|all) ;;
    *) die "软件包 $name 的架构不匹配：$architecture" ;;
  esac

  PACKAGE_NAMES+=("$name")
  PACKAGE_PATH["$name"]="$path"
  PACKAGE_VERSION["$name"]="$version"
}

load_package_metadata() {
  local package_file path name version architecture

  for package_file in "${BUILT_FILES[@]}"; do
    path="$WORK_DIR/$package_file"
    name="$(dpkg-deb -f "$path" Package)"
    version="$(dpkg-deb -f "$path" Version)"
    architecture="$(dpkg-deb -f "$path" Architecture)"
    [[ -n "$name" && -n "$version" && -n "$architecture" ]] ||
      die "无法读取软件包元数据：$package_file"
    register_package "$name" "$version" "$architecture" "$path"
  done
}

package_is_installed() {
  local name="$1"

  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$name" 2>/dev/null || true)" == ii* ]]
}

installed_package_version() {
  local name="$1"

  dpkg-query -W -f='${Version}' "$name"
}

ensure_no_uncovered_mismatched_packages() {
  local name version major

  while IFS=$'\t' read -r name version; do
    major="$(package_version_major "$version" || true)"
    if [[ "$major" != "$SYSTEMD257_TARGET_MAJOR" ]] &&
       [[ -z "${PACKAGE_PATH[$name]+present}" ]]; then
      die "已安装的 $name ($version) 没有对应的 257 包，拒绝产生混合运行时"
    fi
  done < <(list_installed_family_packages)
}

add_selected_package() {
  local name="$1"

  [[ -n "${PACKAGE_PATH[$name]+present}" ]] || die "构建产物缺少核心软件包：$name"
  if [[ -z "${SELECTED_SET[$name]+present}" ]]; then
    SELECTED_SET["$name"]=1
    SELECTED_NAMES+=("$name")
    SELECTED_FILES+=("${PACKAGE_PATH[$name]}")
  fi
}

select_packages() {
  local name
  local -a core_names=(
    libsystemd0 libsystemd-shared libudev1 libpam-systemd libnss-systemd
    systemd udev systemd-sysv systemd-timesyncd systemd-resolved
  )

  for name in "${PACKAGE_NAMES[@]}"; do
    if package_is_installed "$name"; then
      add_selected_package "$name"
    fi
  done

  for name in "${core_names[@]}"; do
    add_selected_package "$name"
  done

  (( ${#SELECTED_FILES[@]} > 0 )) || die "没有选出可安装的软件包"
  log "将安装 ${#SELECTED_FILES[@]} 个 257 包：${SELECTED_NAMES[*]}"
}

install_selected_packages() {
  log "installing the complete systemd 257 runtime through apt"

  # 阻止维护脚本在构建环境中尝试启动服务
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod 0755 /usr/sbin/policy-rc.d

  apt-get -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    install -y --no-install-recommends --allow-downgrades \
    --allow-change-held-packages --no-remove "${SELECTED_FILES[@]}"
  apt-get check
}

package_owner() {
  local path="$1"
  local result owner

  result="$(dpkg-query -S "$path" 2>/dev/null | sed -n '1p' || true)"
  owner="${result%%: *}"
  owner="${owner%%:*}"
  printf '%s\n' "$owner"
}

verify_installed_family() {
  local name expected actual major daemon="" ldd_output installed_version_line installed_major

  MANAGED_NAMES=()
  for name in "${PACKAGE_NAMES[@]}"; do
    if package_is_installed "$name"; then
      expected="${PACKAGE_VERSION[$name]}"
      actual="$(installed_package_version "$name")"
      [[ "$actual" == "$expected" ]] ||
        die "检测到混合包版本：$name 已安装 $actual，构建要求 $expected"
      MANAGED_NAMES+=("$name")
    fi
  done

  while IFS=$'\t' read -r name actual; do
    major="$(package_version_major "$actual" || true)"
    [[ "$major" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
      die "安装后仍存在非 257 systemd 包族成员：$name $actual"
  done < <(list_installed_family_packages)

  for expected in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    if [[ -x "$expected" ]]; then
      daemon="$expected"
      break
    fi
  done
  [[ -n "$daemon" ]] || die "安装后找不到 systemd PID 1"
  [[ "$(package_owner "$daemon")" == systemd ]] ||
    die "systemd PID 1 未登记到 systemd 主包：$daemon"

  if command -v ldd >/dev/null 2>&1; then
    ldd_output="$(ldd "$daemon" 2>&1 || true)"
    if grep -q 'not found' <<< "$ldd_output"; then
      printf '%s\n' "$ldd_output" >&2
      die "systemd 257 PID 1 存在缺失的动态链接库"
    fi
  fi

  installed_version_line="$(systemd_version_line || true)"
  installed_major="$(systemd_major_from_line "$installed_version_line")"
  [[ "$installed_major" == "$SYSTEMD257_TARGET_MAJOR" ]] ||
    die "运行时版本验证失败：${installed_version_line:-unknown}"
  CURRENT_VERSION_LINE="$installed_version_line"
}

configure_apt_holds() {
  if (( ${#MANAGED_NAMES[@]} > 0 )); then
    apt-mark hold "${MANAGED_NAMES[@]}"
  fi
}

cleanup_build() {
  log "cleaning up build environment"

  rm -f /usr/sbin/policy-rc.d

  # mk-build-deps --remove 通常已移除占位包；此处兜底
  if dpkg-query -W -f='${db:Status-Abbrev}' systemd-build-deps >/dev/null 2>&1; then
    apt-get purge -y systemd-build-deps
  fi

  # 清理不再被任何手动安装包依赖的自动安装构建依赖
  apt-get autoremove --purge -y ||
    log "warning: apt autoremove 未完全清理构建依赖"
}

write_state_file() {
  local state_temp="$WORK_DIR/droidspaces-systemd257"
  local managed_packages_csv main_version

  printf -v managed_packages_csv '%s,' "${MANAGED_NAMES[@]}"
  managed_packages_csv="${managed_packages_csv%,}"
  main_version="${PACKAGE_VERSION[systemd]}"

  cat > "$state_temp" <<EOF
previous_version=$PREVIOUS_VERSION_LINE
installed_version=$CURRENT_VERSION_LINE
source_version=$SOURCE_VERSION
source_ref=v$SOURCE_VERSION
source_commit=not-recorded
package_manager=apt
managed_package=systemd
managed_package_version=$main_version
install_mode=source-build
packaging_source=Debian ${DEBIAN_VERSION} source package rebuilt in-container on Kali
compat_patch=0001-droidspaces-old-kernel-compat.patch
managed_packages=$managed_packages_csv
EOF
  install -m 0644 "$state_temp" "$SYSTEMD257_STATE"
}

main() {
  local current_major

  require_root
  CURRENT_VERSION_LINE="$(systemd_version_line || true)"
  [[ -n "$CURRENT_VERSION_LINE" ]] || die "无法检测当前 systemd 版本"
  current_major="$(systemd_major_from_line "$CURRENT_VERSION_LINE")"
  [[ "$current_major" =~ ^[0-9]+$ ]] ||
    die "无法从版本信息中提取主版本：$CURRENT_VERSION_LINE"
  readonly PREVIOUS_VERSION_LINE="$CURRENT_VERSION_LINE"

  log "current version: $CURRENT_VERSION_LINE"
  if (( current_major < SYSTEMD257_TARGET_MAJOR )); then
    log "systemd $current_major 低于 257，不执行构建"
    return 0
  fi

  require_kali
  require_arm64

  if (( current_major == SYSTEMD257_TARGET_MAJOR )) && ! has_mismatched_family_packages; then
    log "运行时和已安装 systemd 包族均为 257，不需要重复构建"
    return 0
  fi

  install_build_tooling
  WORK_DIR="$(mktemp -d -t systemd257.XXXXXXXX)"
  download_sources
  build_package_family
  collect_built_packages
  load_package_metadata
  ensure_no_uncovered_mismatched_packages
  select_packages
  install_selected_packages
  verify_installed_family
  configure_apt_holds
  cleanup_build
  write_state_file

  log "done: $CURRENT_VERSION_LINE (${#MANAGED_NAMES[@]} packages managed by apt)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
