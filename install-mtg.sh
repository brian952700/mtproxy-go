#!/usr/bin/env bash
set -euo pipefail
umask 077

cyan='' green='' yellow='' red='' reset=''
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
    cyan=$'\033[36m' green=$'\033[32m' yellow=$'\033[33m'
    red=$'\033[31m' reset=$'\033[0m'
fi

stage() { printf '\n%s  [%s/4] %s%s\n' "$cyan" "$1" "$2" "$reset"; }
done_step() { printf '%s      完成%s\n' "$green" "$reset"; }
die() { printf '%s  失败：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

version=2.3.0
printf '\n%s  MTProto 代理安装器 · mtg v%s%s\n' "$cyan" "$version" "$reset"
stage 1 '检查系统与依赖'

[[ "$(uname -s)" == Linux && -d /run/systemd/system ]] || die '需要使用 systemd 的 Linux。'
(( EUID == 0 )) || die '请以 root 用户运行。'
(( $# <= 2 )) || die '用法: bash install-mtg.sh [HTTPS域名] [端口]'
domain=${1:-www.apple.com}
port=${2:-3128}
[[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$domain" == *.* ]] || die '请输入域名，不带 https:// 或路径。'
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || die '端口必须为 1–65535。'

[[ -r /etc/os-release ]] || die '无法识别系统版本。'
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" =~ ^[0-9]+$ ]] && (( VERSION_ID >= 12 )) || die '需要 Debian 12 或更高版本。'

for command in curl tar sha256sum awk install systemctl ss flock; do
    if ! command -v "$command" >/dev/null; then
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl tar coreutils mawk iproute2 util-linux
        break
    fi
done
if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates
fi

for command in curl tar sha256sum awk install systemctl ss flock; do
    command -v "$command" >/dev/null || die "缺少命令: $command"
done

case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die '仅支持 Linux x86_64 和 ARM64。' ;;
esac

exec 9>/run/lock/mtg-install.lock
flock -n 9 || die '已有安装正在进行。'
binary=/usr/local/bin/mtg
config=/etc/mtg.toml
unit=/etc/systemd/system/mtg.service
if systemctl cat mtg.service >/dev/null 2>&1; then
    die 'mtg.service 已存在。'
fi
for path in "$binary" "$config" "$unit"; do
    [[ ! -e "$path" && ! -L "$path" ]] || die "已有文件: $path"
done
listeners=$(ss -H -ltn "sport = :$port")
[[ -z "$listeners" ]] || die "TCP $port 已被占用。"

printf '      Debian %s / %s · TCP %s · %s\n' "$VERSION_ID" "$arch" "$port" "$domain"
done_step

stage 2 '下载并校验 mtg'
archive="mtg-$version-linux-$arch.tar.gz"
checksums="mtg-$version-checksums.txt"
base="https://github.com/9seconds/mtg/releases/download/v$version"
tmp=$(mktemp -d)
installed=0
success=0
cleanup() {
    local status=$?
    if (( status != 0 )); then
        printf '%s  安装中止（退出码 %s）%s\n' "$red" "$status" "$reset" >&2
    fi
    if (( installed && !success )); then
        printf '%s  正在清理本次安装的服务和文件…%s\n' "$yellow" "$reset" >&2
        systemctl disable --now mtg.service >/dev/null 2>&1 || true
        rm -f -- "$binary" "$config" "$unit"
        systemctl daemon-reload || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
cd "$tmp"
for file in "$archive" "$checksums"; do
    printf '      下载 %s\n' "$file"
    curl --proto '=https' --proto-redir '=https' -fSL --retry 3 -o "$file" "$base/$file"
done
awk -v file="$archive" '$2 == file || $2 == "*" file { print; found=1 } END { exit !found }' "$checksums" > checksum
sha256sum --check checksum
tar -xzf "$archive"
[[ -x ./mtg ]] || die '发行包内找不到 mtg 可执行文件。'
secret=$(./mtg generate-secret --hex "$domain")
[[ "$secret" =~ ^ee[0-9a-f]+$ ]] || die '生成密钥失败。'

done_step

stage 3 '写入配置和服务'
bind="[::]:$port"
prefer_ip=prefer-ipv6
if [[ ! -s /proc/net/if_inet6 ]]; then
    bind="0.0.0.0:$port"
    prefer_ip=prefer-ipv4
    printf '%s      IPv6 不可用，改用 IPv4 监听%s\n' "$yellow" "$reset"
fi
printf 'secret = "%s"\nbind-to = "%s"\nprefer-ip = "%s"\n' "$secret" "$bind" "$prefer_ip" > config.toml
cat > mtg.service <<'UNIT'
[Unit]
Description=mtg Telegram MTProto proxy
Wants=network-online.target
After=network-online.target

[Service]
DynamicUser=yes
LoadCredential=mtg.toml:/etc/mtg.toml
ExecStart=/usr/local/bin/mtg run %d/mtg.toml
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

installed=1
install -m 0755 ./mtg "$binary"
install -m 0600 config.toml "$config"
install -m 0644 mtg.service "$unit"
systemctl daemon-reload
done_step

stage 4 '启动服务并检查监听'
systemctl enable --now mtg.service
for attempt in {1..20}; do
    listeners=$(ss -H -ltnp "sport = :$port")
    if [[ "$listeners" == *'"mtg",pid='* ]] && systemctl is-active --quiet mtg.service; then
        success=1
        break
    fi
    sleep 1
done
if (( !success )); then
    journalctl -u mtg.service -n 20 --no-pager >&2 || true
    die 'mtg 未成功监听，正在回滚安装。'
fi

done_step
printf '\n%s  安装成功 · 已启用开机自启%s\n' "$green" "$reset"
printf '  监听地址      %s\n' "$bind"
printf '  TLS 域名     %s\n\n' "$domain"
printf '  生成 Telegram 连接链接\n    %s access %s\n\n' "$binary" "$config"
printf '  查看服务状态\n    systemctl status mtg --no-pager\n\n'
