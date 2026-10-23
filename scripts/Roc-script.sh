#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_CONFIG_FILE="${1:-${CONFIG_FILE:-}}"
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-configs/General.config}}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

case "$GIT_CLONE_RETRY_COUNT" in
  '' | *[!0-9]* | 0)
    echo "Error: GIT_CLONE_RETRY_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

resolve_config_file() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then
    printf '%s\n' "$WORKSPACE/$config_file"
  else
    echo "Error: configuration file was not found: $config_file" >&2
    return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  # Keep direct invocations compatible with an existing OpenWrt .config.
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2
  exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

config_symbol_enabled() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

target_device_package_enabled() {
  local package_name="$1"

  awk -v package_name="$package_name" '
    { sub(/\r$/, "") }
    /^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
      packages = $0
      sub(/^[^"]*"/, "", packages)
      sub(/"$/, "", packages)
      count = split(packages, values, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (values[i] == package_name) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name

  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name" || target_device_package_enabled "$package_name"; then
      return 0
    fi
  done

  return 1
}

clone_with_retry() {
  local target_dir="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then
      return 0
    fi

    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT): ${*: -1}" >&2
      sleep $((attempt * 2))
    fi
  done

  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1}" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1"
  local branch="$2"
  local checkout_dir="$3"
  local commit
  local revision

  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  clone_with_retry "$target_dir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# 修改默认IP & 固件名称 & 编译署名和时间
sed -i 's/192.168.1.1/$OWRT_IP/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='$OWRT_NAME'/g" package/base-files/files/bin/config_generate
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' / ',\n \
            E('a', {\n \
                href: 'https://github.com/JerryRocket/openwrt-ci-roc/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ '$(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
# sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# Git稀疏克隆，只克隆指定目录到本地
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl"
  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )
  record_git_revision "$repourl" "$branch" "$repodir"

  for sparse_path in "$@"; do
    rm -rf "package/$(basename "$sparse_path")"
    mv "$repodir/$sparse_path" package/
  done
  rm -rf "$repodir"
}

# Aria2 & nginx & Go & DDNS & frp & UPnP & Wol
rm -rf feeds/packages/lang/golang
git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv package/golang feeds/packages/lang/golang

if package_enabled luci-app-aria2 aria2; then
  rm -rf feeds/packages/net/aria2
  git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
  mv package/aria2 feeds/packages/net/aria2
fi
if package_enabled ariang; then
  rm -rf feeds/packages/net/ariang
  git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
  mv package/ariang feeds/packages/net/ariang
fi

if package_enabled nginx nginx-full nginx-ssl luci-app-nginx; then
  rm -rf feeds/packages/net/nginx
  git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
  mv package/nginx feeds/packages/net/nginx
fi

if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/immortalwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# Themes and standalone applications. A config application pulls in its theme as a dependency.
if package_enabled luci-theme-argon luci-app-argon-config; then
  rm -rf feeds/luci/themes/luci-theme-argon
  clone_repository https://github.com/jerrykuku/luci-theme-argon master feeds/luci/themes/luci-theme-argon
fi
if package_enabled luci-app-argon-config; then
  rm -rf feeds/luci/applications/luci-app-argon-config
  clone_repository https://github.com/jerrykuku/luci-app-argon-config master feeds/luci/applications/luci-app-argon-config
fi

### PassWall & OpenClash ###

if package_enabled luci-app-passwall2; then
  # 移除 OpenWrt Feeds 自带的核心库
  rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall-packages main package/passwall-packages
fi

if package_enabled luci-app-passwall2; then
  rm -rf feeds/luci/applications/luci-app-passwall2
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall2 main package/luci-app-passwall2
fi

# 清理 PassWall 的 chnlist 规则文件
# echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

./scripts/feeds update -i -a
./scripts/feeds install -a
