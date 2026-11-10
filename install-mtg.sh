#!/usr/bin/env bash
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux && -d /run/systemd/system ]] || die '需要使用 systemd 的 Linux。'
(( EUID == 0 )) || die '请用 sudo 运行。'
(( $# >= 1 && $# <= 2 )) || die '用法: sudo bash install-mtg.sh <HTTPS域名> [端口]'
domain=$1
port=${2:-3128}
[[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$domain" == *.* ]] || die '请输入域名，不带 https:// 或路径。'
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || die '端口必须为 1–65535。'

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

version=2.3.0
archive="mtg-$version-linux-$arch.tar.gz"
checksums="mtg-$version-checksums.txt"
base="https://github.com/9seconds/mtg/releases/download/v$version"
tmp=$(mktemp -d)
installed=0
success=0
cleanup() {
    if (( installed && !success )); then
        systemctl disable --now mtg.service >/dev/null 2>&1 || true
        rm -f -- "$binary" "$config" "$unit"
        systemctl daemon-reload || true
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
cd "$tmp"
for file in "$archive" "$checksums"; do
    curl --proto '=https' --proto-redir '=https' -fSL --retry 3 -o "$file" "$base/$file"
done
awk -v file="$archive" '$2 == file || $2 == "*" file { print; found=1 } END { exit !found }' "$checksums" > checksum
sha256sum --check checksum
tar -xzf "$archive"
[[ -x ./mtg ]] || die '发行包内找不到 mtg 可执行文件。'
secret=$(./mtg generate-secret --hex "$domain")
[[ "$secret" =~ ^ee[0-9a-f]+$ ]] || die '生成密钥失败。'

printf 'secret = "%s"\nbind-to = "[::]:%s"\nprefer-ip = "prefer-ipv6"\n' "$secret" "$port" > config.toml
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

printf '\nmtg %s 已启动，监听 TCP %s。\n' "$version" "$port"
printf '生成 Telegram 连接链接: sudo %s access %s\n' "$binary" "$config"
