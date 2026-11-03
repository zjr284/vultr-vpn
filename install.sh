#!/usr/bin/env bash
# =============================================================================
#  vultr-vpn 一键入口
#
#  在全新的 Ubuntu 22.04 / 24.04 上，以 root 执行一行即可：
#
#     bash <(curl -fsSL https://raw.githubusercontent.com/zjr284/vultr-vpn/main/install.sh) \
#          --domain vpn.example.com
#
#  可选参数（其余原样传给 setup.sh）：
#     --ref <v1.0.0|main>    指定版本，默认 main（生产环境建议锁定版本号）
#     --domain <域名>        用自己的域名（不填则用 <IP>.sslip.io）
#     --vultr-key <APIKEY>   自动开 Vultr 防火墙端口
#     --vultr-fw <组名>      没有防火墙组时新建一个并挂上（默认 vpn）
#     --check                只做体检，不改配置
#     --links                只打印节点链接
#
#  如果本机已经有仓库副本（install.sh 旁边就有 setup.sh），会直接用本地副本。
# =============================================================================
set -euo pipefail

REPO="zjr284/vultr-vpn"
REF="${VPN_REF:-main}"
DEST="${VPN_DIR:-/opt/vultr-vpn}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; NC=$'\033[0m'
log()  { echo "${GRN}[+ ]${NC} $*"; }
warn() { echo "${YEL}[! ]${NC} $*"; }
die()  { echo "${RED}[x ]${NC} $*" >&2; exit 1; }

# --ref 由本脚本消费，其余参数透传给 setup.sh
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)   REF="$2"; shift 2;;
    --ref=*) REF="${1#*=}"; shift;;
    *)       PASS+=("$1"); shift;;
  esac
done
set -- "${PASS[@]}"

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i 后重试）"
command -v curl >/dev/null || die "缺少 curl"

# ---- 本地已经有仓库？直接用
export VULTR_VPN_REF="$REF"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
if [ -f "$SELF_DIR/setup.sh" ] && [ -f "$SELF_DIR/scripts/sub.py" ]; then
  log "使用本地副本: $SELF_DIR"
  exec bash "$SELF_DIR/setup.sh" "$@"
fi

# ---- 否则下载仓库
log "下载 $REPO@$REF"
mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URLS=(
  "https://codeload.github.com/$REPO/tar.gz/$REF"
  "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
  "https://ghproxy.net/https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
)
ok=0
for u in "${URLS[@]}"; do
  if curl -fsSL --max-time 90 "$u" -o "$TMP/src.tar.gz"; then ok=1; break; fi
  warn "下载源不可用: $u"
done
[ "$ok" = "1" ] || die "仓库下载失败，检查网络或改用 git clone"

tar xzf "$TMP/src.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 2 -name setup.sh -printf '%h\n' | head -1)"
[ -n "$SRC" ] || die "压缩包结构异常"

# 保留旧机器上的密钥与客户端配置：重装/重建时客户端才不用重新导入
if [ -d "$DEST" ]; then
  for f in config.env; do
    [ -f "$DEST/$f" ] && cp -a "$DEST/$f" "$TMP/keep-$f"
  done
  [ -d "$DEST/clients" ] && cp -a "$DEST/clients" "$TMP/keep-clients"
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC"/. "$DEST"/
[ -f "$TMP/keep-config.env" ] && { cp -a "$TMP/keep-config.env" "$DEST/config.env"; log "复用已有 config.env（密钥不变）"; }
[ -d "$TMP/keep-clients" ] && cp -a "$TMP/keep-clients" "$DEST/clients"
log "已展开到 $DEST"

exec bash "$DEST/setup.sh" "$@"
