#!/usr/bin/env bash
# =============================================================================
#  vultr-vpn — 一条命令搭好三通道代理
#  WireGuard(udp 51821) + Xray Reality(tcp 443) + Hysteria2(udp 443) + 订阅服务
#
#  用法（root，Ubuntu 22.04/24.04）:
#     bash setup.sh                          # 用 <IP>.sslip.io 域名
#     bash setup.sh --domain vpn.example.com # 用自己的域名（推荐）
#     bash setup.sh --vultr-key KEY --vultr-fw vpn   # 连防火墙一起开好
#     bash setup.sh --check                  # 只体检，不改任何配置
#     bash setup.sh --links                  # 只打印节点链接
#     bash setup.sh --cert-only              # 只补签证书
#     bash setup.sh --json                   # 末尾多打一行 VPN_JSON={...}，给 agent 解析
#     bash setup.sh --reset                  # 重新生成全部密钥（客户端要重导）
#
#  首次运行会在同目录生成 config.env（含随机密钥）和 clients/（客户端配置），
#  两者都已在 .gitignore 里，不会也不该被提交。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/config.env"
CLIENTS="$ROOT/clients"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; NC=$'\033[0m'
log()  { echo "${GRN}[+ ]${NC} $*"; }
warn() { echo "${YEL}[! ]${NC} $*"; }
die()  { echo "${RED}[x ]${NC} $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"
command -v apt-get >/dev/null || die "只支持 Debian / Ubuntu"

MODE="deploy"; ARG_DOMAIN=""; ARG_VULTR_KEY=""; ARG_VULTR_FW=""; RESET=0; JSON_OUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)     ARG_DOMAIN="$2"; shift 2;;
    --vultr-key)  ARG_VULTR_KEY="$2"; shift 2;;
    --vultr-fw)   ARG_VULTR_FW="$2"; shift 2;;
    --links)      MODE="links"; shift;;
    --check)      MODE="check"; shift;;
    --cert-only)  MODE="cert"; shift;;
    --json)       JSON_OUT=1; shift;;
    --reset)      RESET=1; shift;;
    --yes)        shift;;
    -h|--help)    sed -n '6,18p' "$0"; exit 0;;
    *) die "未知参数: $1";;
  esac
done

# ---------------------------------------------------------------- 基础软件
export DEBIAN_FRONTEND=noninteractive
if ! command -v xray >/dev/null || ! command -v wg >/dev/null; then
  log "安装依赖（wireguard-tools / curl / certbot / xray）"
  apt-get update -qq
  apt-get install -y -qq wireguard-tools iptables curl ca-certificates certbot python3 qrencode >/dev/null
  if ! command -v xray >/dev/null; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
  fi
fi

IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
[ -n "$IFACE" ] || die "找不到默认网卡"
PUB_IP="$(curl -fsS --max-time 10 https://api.ipify.org || curl -fsS --max-time 10 https://ifconfig.me)"
[ -n "$PUB_IP" ] || die "取不到公网 IP"

# ---------------------------------------------------------------- 配置
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi
DOMAIN="${ARG_DOMAIN:-${DOMAIN:-}}"
: "${DOMAIN:=${PUB_IP//./-}.sslip.io}"
[ "$MODE" = "links" ] && { DOMAIN="${ARG_DOMAIN:-${DOMAIN}}"; }

# sslip.io 域名是从 IP 派生的：换机器后要跟着变，否则证书/订阅还指向旧 IP
case "$DOMAIN" in
  *.sslip.io|*.nip.io|*.traefik.me)
    if [ "$DOMAIN" != "${PUB_IP//./-}.sslip.io" ] && [ -z "$ARG_DOMAIN" ]; then
      warn "域名 $DOMAIN 与当前公网 IP 不匹配，自动改用 ${PUB_IP//./-}.sslip.io"
      DOMAIN="${PUB_IP//./-}.sslip.io"
      [ -f "$CONFIG" ] && sed -i "s|^DOMAIN=.*|DOMAIN=\"$DOMAIN\"|" "$CONFIG"
    fi;;
esac

gen_config() {
  log "生成配置（随机密钥）"
  WG_SERVER_PRIVKEY="$(wg genkey)"
  CLIENT_PHONE_PRIVKEY="$(wg genkey)"
  CLIENT_WINDOWS_PRIVKEY="$(wg genkey)"
  CLIENT_WSL_PRIVKEY="$(wg genkey)"
  XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
  _keys="$(xray x25519)"
  XRAY_PRIVKEY="$(echo "$_keys" | awk -F': ' '/Private/{print $2}')"
  XRAY_PUBKEY="$(echo "$_keys" | awk -F': ' '/Public/{print $2}')"
  XRAY_SHORTID="$(openssl rand -hex 8)"
  HY2_PASSWORD="$(openssl rand -hex 8)"
  SUB_TOKEN="dsh-sub-$(openssl rand -hex 4)"
  WG_PORT="51821"
  XRAY_SNI="www.yahoo.co.jp"
  cat >"$CONFIG" <<EOF
# 由 setup.sh 自动生成 $(date -u +%FT%TZ) — 请勿提交
DOMAIN="$DOMAIN"
WG_PORT="$WG_PORT"
WG_SERVER_PRIVKEY="$WG_SERVER_PRIVKEY"
CLIENT_PHONE_PRIVKEY="$CLIENT_PHONE_PRIVKEY"
CLIENT_WINDOWS_PRIVKEY="$CLIENT_WINDOWS_PRIVKEY"
CLIENT_WSL_PRIVKEY="$CLIENT_WSL_PRIVKEY"
XRAY_UUID="$XRAY_UUID"
XRAY_PRIVKEY="$XRAY_PRIVKEY"
XRAY_PUBKEY="$XRAY_PUBKEY"
XRAY_SHORTID="$XRAY_SHORTID"
XRAY_SNI="$XRAY_SNI"
HY2_PASSWORD="$HY2_PASSWORD"
SUB_TOKEN="$SUB_TOKEN"
EOF
  chmod 600 "$CONFIG"
}

if [ "$RESET" = "1" ] && [ -f "$CONFIG" ]; then
  warn "--reset：删除旧配置，重新生成密钥（客户端需要重新导入）"
  rm -f "$CONFIG"
fi
if [ ! -f "$CONFIG" ]; then
  case "$MODE" in
    links|check) die "还没有 config.env，先完整执行一次部署（bash setup.sh）";;
    *) gen_config;;
  esac
fi
# 补全老配置里缺的字段
[ -n "${SUB_TOKEN:-}" ] || { SUB_TOKEN="dsh-sub-$(openssl rand -hex 4)"; echo "SUB_TOKEN=\"$SUB_TOKEN\"" >>"$CONFIG"; }
[ -n "${HY2_PASSWORD:-}" ] || { HY2_PASSWORD="$(openssl rand -hex 8)"; echo "HY2_PASSWORD=\"$HY2_PASSWORD\"" >>"$CONFIG"; }
# 云厂商 API（可选，用于自动开防火墙）
if [ -n "$ARG_VULTR_KEY" ] && [ "$ARG_VULTR_KEY" != "${VULTR_API_KEY:-}" ]; then
  sed -i '/^VULTR_API_KEY=/d;/^VULTR_FW_NAME=/d' "$CONFIG"
  echo "VULTR_API_KEY=\"$ARG_VULTR_KEY\"" >>"$CONFIG"
  [ -n "$ARG_VULTR_FW" ] && echo "VULTR_FW_NAME=\"$ARG_VULTR_FW\"" >>"$CONFIG"
fi
VULTR_API_KEY="${VULTR_API_KEY:-}"
VULTR_FW_NAME="${VULTR_FW_NAME:-${ARG_VULTR_FW:-vpn}}"
# 允许 --domain 覆盖
if [ -n "$ARG_DOMAIN" ] && [ "$ARG_DOMAIN" != "$(grep -oP '^DOMAIN="\K[^"]*' "$CONFIG" || true)" ]; then
  sed -i "s|^DOMAIN=.*|DOMAIN=\"$ARG_DOMAIN\"|" "$CONFIG"
  DOMAIN="$ARG_DOMAIN"
fi

log "默认网卡=$IFACE 公网IP=$PUB_IP 域名=$DOMAIN"

links() {
  if [ -z "${XRAY_UUID:-}" ] || [ -z "${XRAY_PUBKEY:-}" ] || [ -z "${HY2_PASSWORD:-}" ]; then
    die "config.env 不完整（缺 XRAY_UUID / XRAY_PUBKEY / HY2_PASSWORD），先完整执行一次部署"
  fi
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-Reality\n' \
    "$XRAY_UUID" "$DOMAIN" "$XRAY_SNI" "$XRAY_PUBKEY" "$XRAY_SHORTID" "${1:-Tokyo}"
  printf 'hysteria2://%s@%s:443/?sni=%s#%s-Hysteria2\n' \
    "$HY2_PASSWORD" "$DOMAIN" "$DOMAIN" "${1:-Tokyo}"
}

if [ "$MODE" = "links" ]; then links; exit 0; fi

# ---------------------------------------------------------------- 体检
check() {
  [ -f "$CONFIG" ] || die "还没有 config.env，先执行一次部署：bash setup.sh"
  local fail=0
  printf '%-26s %-10s %s\n' "检查项" "结果" "说明"
  printf '%-26s %-10s %s\n' "------" "----" "----"
  row() { printf '%-26s %-10s %s\n' "$1" "$2" "$3"; }

  for s in wg-quick@wg0 xray hysteria-server dsh-sub; do
    if systemctl is-active --quiet "$s"; then row "服务 $s" "OK" ""
    else row "服务 $s" "FAIL" "systemctl status $s"; fail=1; fi
  done

  port_open() { ss -lnu 2>/dev/null | grep -q ":$1 " || ss -lnt 2>/dev/null | grep -q ":$1 "; }
  if port_open "$WG_PORT"; then row "WireGuard udp/$WG_PORT" "OK" ""; else row "WireGuard udp/$WG_PORT" "FAIL" "未监听"; fail=1; fi
  if port_open 443; then row "TCP 443 (Reality)" "OK" ""; else row "TCP 443 (Reality)" "FAIL" "未监听"; fail=1; fi

  if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    local exp days
    exp="$(openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -enddate | cut -d= -f2)"
    days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
    if [ "$days" -gt 10 ]; then row "证书 $DOMAIN" "OK" "剩 $days 天"
    else row "证书 $DOMAIN" "WARN" "剩 $days 天，执行 bash setup.sh --cert-only"; fi
  else
    row "证书 $DOMAIN" "FAIL" "无证书，Hysteria2 会连不上"; fail=1
  fi

  if curl -fsS --max-time 6 "http://127.0.0.1/$SUB_TOKEN.txt" -o /dev/null; then
    row "订阅（本机 80）" "OK" "http://$DOMAIN/$SUB_TOKEN.txt"
  else
    row "订阅（本机 80）" "FAIL" "dsh-sub 未响应"; fail=1
  fi

  if [ -n "${VULTR_API_KEY:-}" ]; then
    local inst fw
    inst="$(curl -sS -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/instances \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next((i.get("firewall_group_id","") for i in d["instances"] if i["main_ip"]=="'"$PUB_IP"'"),""))' 2>/dev/null || true)"
    if [ -n "$inst" ]; then
      fw="$(curl -sS -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/firewalls/$inst/rules" \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print(",".join(sorted({f"{r[\"protocol\"]}/{r[\"port\"]}" for r in d["firewall_rules"]})))' 2>/dev/null || true)"
      row "Vultr 防火墙组" "OK" "${fw:-空}"
    else
      row "Vultr 防火墙组" "WARN" "该实例未挂防火墙组（=所有端口放行）"
    fi
  fi

  echo
  if [ "$fail" = "1" ]; then warn "存在 FAIL 项，按说明修复后重跑 --check"; return 1; fi
  log "全部关键项正常"
}

if [ "$MODE" = "check" ]; then check || exit 1; exit 0; fi

# ---------------------------------------------------------------- 内核调优
log "写入内核/网络调优"
cat >/etc/sysctl.d/99-vpn-perf.conf <<'EOF'
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
EOF
sysctl -q --system

# ---------------------------------------------------------------- WireGuard
if [ -f /etc/wireguard/wg0.conf ]; then
  warn "已存在 /etc/wireguard/wg0.conf，保留不动"
else
  log "写入 WireGuard 配置"
  mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
  P_WIN="$(echo "$CLIENT_WINDOWS_PRIVKEY" | wg pubkey)"
  P_WSL="$(echo "$CLIENT_WSL_PRIVKEY"    | wg pubkey)"
  P_PHONE="$(echo "$CLIENT_PHONE_PRIVKEY"| wg pubkey)"
  cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = $WG_PORT
PrivateKey = $WG_SERVER_PRIVKEY
MTU = 1420
PostUp = iptables -A FORWARD -i %i -o $IFACE -j ACCEPT; iptables -A FORWARD -i $IFACE -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o $IFACE -j ACCEPT; iptables -D FORWARD -i $IFACE -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $IFACE -j MASQUERADE

[Peer]
# windows
PublicKey = $P_WIN
AllowedIPs = 10.8.0.2/32

[Peer]
# wsl
PublicKey = $P_WSL
AllowedIPs = 10.8.0.3/32

[Peer]
# phone
PublicKey = $P_PHONE
AllowedIPs = 10.8.0.4/32
EOF
  chmod 600 /etc/wireguard/wg0.conf
fi
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0 || warn "wg-quick 启动失败，检查 /etc/wireguard/wg0.conf"

# ---------------------------------------------------------------- 端口冲突
# 有些机器为了让 SSH 穿过封锁，会把 sshd 也放一个监听在 443 —— 那样 Xray 起不来
if grep -rqsE '^[[:space:]]*Port[[:space:]]+443' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
  warn "检测到 sshd 监听 443，改为只监听 22（443 让给 Xray）"
  sed -i -E 's/^[[:space:]]*Port[[:space:]]+443[[:space:]]*$/Port 22/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
  sed -i -E 's/^[[:space:]]*Port[[:space:]]+443[[:space:]]*$/Port 22/' /etc/ssh/sshd_config 2>/dev/null || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
fi

# ---------------------------------------------------------------- Xray
log "写入 Xray Reality 配置"
mkdir -p /usr/local/etc/xray
[ -f /usr/local/etc/xray/config.json ] && cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak
cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$XRAY_SNI:443",
          "xver": 0,
          "serverNames": ["$XRAY_SNI"],
          "privateKey": "$XRAY_PRIVKEY",
          "shortIds": ["$XRAY_SHORTID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:cn"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "direct" }
    ]
  }
}
EOF
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray

# ---------------------------------------------------------------- 证书
# 先把 80 放出去，否则 HTTP-01 验证必然超时
ufw allow 80/tcp >/dev/null 2>&1 || true
vultr_firewall

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
HAVE_CERT=0
need_cert=1
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  exp="$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)"
  days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
  if [ "$days" -gt 20 ]; then need_cert=0; log "证书有效（剩 $days 天），跳过签发"; fi
fi

if [ "$need_cert" = "1" ]; then
  log "签发 Let's Encrypt 证书: $DOMAIN"
  ufw allow 80/tcp >/dev/null 2>&1 || true
  if certbot certonly --standalone --non-interactive --agree-tos \
       --register-unsafely-without-email -d "$DOMAIN" >/tmp/certbot.log 2>&1; then
    log "证书签发成功"
  else
    warn "签发失败，日志: /tmp/certbot.log"
    warn "常见原因: 云厂商防火墙未放行 tcp 80（规则生效有 1~3 分钟延迟）"
    warn "放行后执行: bash setup.sh --cert-only"
    [ "$MODE" = "cert" ] && die "中止"
  fi
fi

if [ -f "$CERT" ]; then
  install -d -m 755 /etc/hysteria
  install -m 644 "$CERT" /etc/hysteria/cert.pem
  install -m 644 "$KEY"  /etc/hysteria/key.pem
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/hysteria.sh <<EOF
#!/bin/sh
install -m 644 "$CERT" /etc/hysteria/cert.pem || exit 0
install -m 644 "$KEY"  /etc/hysteria/key.pem || exit 0
systemctl restart hysteria-server
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/hysteria.sh
  RENEW_CONF="/etc/letsencrypt/renewal/$DOMAIN.conf"
  if [ -f "$RENEW_CONF" ] && ! grep -q '^pre_hook' "$RENEW_CONF"; then
    sed -i '/^\[renewalparams\]/a pre_hook = systemctl stop dsh-sub\npost_hook = systemctl start dsh-sub' "$RENEW_CONF"
  fi
  HAVE_CERT=1
else
  warn "无有效证书，Hysteria2 使用自签证书（新版客户端不允许跳过校验，会连不上）"
  install -d -m 755 /etc/hysteria
  openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
    -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
    -subj "/CN=$DOMAIN" >/dev/null 2>&1
fi

# ---------------------------------------------------------------- Hysteria2
if ! command -v hysteria >/dev/null; then
  log "安装 Hysteria2"
  bash <(curl -fsSL -L https://get.hy2.sh/) >/dev/null 2>&1 || die "Hysteria2 安装失败"
fi
log "写入 Hysteria2 配置"
[ -f /etc/hysteria/config.yaml ] && cp /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak
cat >/etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem

auth:
  type: password
  password: $HY2_PASSWORD

bandwidth:
  up: 100 mbps
  down: 300 mbps

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 67108864
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 134217728
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
chown -R hysteria:hysteria /etc/hysteria 2>/dev/null || true
systemctl enable hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server

# ---------------------------------------------------------------- 订阅服务
log "配置订阅服务（80 端口，另有 8443 HTTPS）"
install -d -m 755 /opt/dsh-sub /var/www/dsh-sub
install -m 755 "$ROOT/scripts/sub.py" /opt/dsh-sub/sub.py 2>/dev/null || warn "缺少 scripts/sub.py，跳过订阅服务"
if [ -f /opt/dsh-sub/sub.py ]; then
  cat >/etc/systemd/system/dsh-sub.service <<'EOF'
[Unit]
Description=VPN subscription endpoint
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/dsh-sub/sub.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable dsh-sub >/dev/null 2>&1 || true
  systemctl restart dsh-sub
fi

cat >/usr/local/bin/vpn-sub-update <<EOF
#!/bin/bash
# 重新生成订阅内容（换域名/换密钥后执行）：vpn-sub-update [新域名]
set -e
D="\${1:-$DOMAIN}"
mkdir -p /var/www/dsh-sub
{
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Tokyo-Reality\n' \\
    "$XRAY_UUID" "\$D" "$XRAY_SNI" "$XRAY_PUBKEY" "$XRAY_SHORTID"
  printf 'hysteria2://%s@%s:443/?sni=%s#Tokyo-Hysteria2\n' "$HY2_PASSWORD" "\$D" "\$D"
} | base64 -w0 > /var/www/dsh-sub/$SUB_TOKEN.txt
echo "订阅已更新: http://\$D/$SUB_TOKEN.txt"
EOF
chmod +x /usr/local/bin/vpn-sub-update
/usr/local/bin/vpn-sub-update "$DOMAIN"

# ---------------------------------------------------------------- 客户端配置
mkdir -p "$CLIENTS"
SRV_PUB="$(echo "$WG_SERVER_PRIVKEY" | wg pubkey)"
write_client() {
  local name=$1 priv=$2 ip=$3
  cat >"$CLIENTS/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $SRV_PUB
Endpoint = $PUB_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENTS/$name.conf"
}
write_client windows "$CLIENT_WINDOWS_PRIVKEY" 10.8.0.2
write_client wsl     "$CLIENT_WSL_PRIVKEY"     10.8.0.3
write_client phone   "$CLIENT_PHONE_PRIVKEY"   10.8.0.4

# ---------------------------------------------------------------- 云防火墙
# 有 VULTR_API_KEY 时自动把 22/80/443/udp443/udp51821 开好，省掉最容易翻车的一步
vultr_firewall() {
  [ -n "${VULTR_API_KEY:-}" ] || return 0
  command -v python3 >/dev/null || { warn "缺 python3，跳过云防火墙自动配置"; return 0; }
  log "配置 Vultr 防火墙（组: $VULTR_FW_NAME）"
  local api="https://api.vultr.com/v2"
  local inst iid fw have spec proto port
  inst="$(curl -sS -H "Authorization: Bearer $VULTR_API_KEY" "$api/instances" 2>/dev/null | python3 -c '
import sys, json
ip = sys.argv[1]
d = json.load(sys.stdin)
for i in d.get("instances", []):
    if i.get("main_ip") == ip:
        print(i["id"], i.get("firewall_group_id") or "-")
        break
' "$PUB_IP" || true)"
  if [ -z "$inst" ]; then
    warn "API 查不到实例 $PUB_IP（key 的 IP 白名单可能不含本机出口 IP），跳过"
    return 0
  fi
  iid="${inst%% *}"; fw="${inst##* }"
  if [ "$fw" = "-" ]; then
    fw="$(curl -sS -X POST -H "Authorization: Bearer $VULTR_API_KEY" -H "Content-Type: application/json" \
          -d "{\"description\":\"$VULTR_FW_NAME\"}" "$api/firewalls" \
          | python3 -c 'import sys,json;print(json.load(sys.stdin)["firewall_group"]["id"])' 2>/dev/null || true)"
    [ -n "$fw" ] && curl -sS -X PUT -H "Authorization: Bearer $VULTR_API_KEY" -H "Content-Type: application/json" \
          -d "{\"firewall_group_id\":\"$fw\"}" "$api/instances/$iid" >/dev/null 2>&1 || true
    log "新建防火墙组并挂载: ${fw:-失败}"
  fi
  [ -n "$fw" ] || return 0
  have="$(curl -sS -H "Authorization: Bearer $VULTR_API_KEY" "$api/firewalls/$fw/rules" 2>/dev/null \
          | python3 -c 'import sys,json;d=json.load(sys.stdin);print(" ".join(sorted({r["protocol"]+":"+str(r["port"]) for r in d.get("firewall_rules",[]) if r.get("subnet")=="0.0.0.0/0"})))' 2>/dev/null || true)"
  for spec in "tcp:22" "tcp:80" "tcp:443" "udp:443" "udp:$WG_PORT"; do
    proto="${spec%%:*}"; port="${spec##*:}"
    case " $have " in *" $spec "*) continue;; esac
    if curl -sS -X POST -H "Authorization: Bearer $VULTR_API_KEY" -H "Content-Type: application/json" \
         -d "{\"protocol\":\"$proto\",\"port\":\"$port\",\"subnet\":\"0.0.0.0/0\",\"ip_type\":\"v4\",\"notes\":\"vpn-auto\"}" \
         "$api/firewalls/$fw/rules" -o /dev/null -w '%{http_code}' | grep -q '^20'; then
      log "放行 $proto/$port"
    else
      warn "放行 $proto/$port 失败（规则可能已存在）"
    fi
    sleep 1
  done
  warn "云防火墙规则生效有 1~3 分钟延迟，证书签发失败就等两分钟再 bash setup.sh --cert-only"
}

# ---------------------------------------------------------------- 防火墙
log "配置 ufw"
ufw --force enable >/dev/null 2>&1 || true
for r in 22/tcp 80/tcp 443/tcp 8443/tcp "$WG_PORT"/udp 443/udp; do
  ufw allow "$r" >/dev/null 2>&1 || true
done
ufw route allow in on wg0 out on "$IFACE" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 汇总
SUB_URL="http://$DOMAIN/$SUB_TOKEN.txt"

# --json：只吐一行机器可读结果，供 agent 解析（日志仍在 stderr 之外，用 grep ^VPN_JSON= 取）
if [ "$JSON_OUT" = "1" ]; then
  L1="$(links | sed -n '1p')"
  L2="$(links | sed -n '2p')"
  CERT_JSON=false; [ "$HAVE_CERT" = "1" ] && CERT_JSON=true
  printf 'VPN_JSON={"host":"%s","domain":"%s","subscription":"%s","reality":"%s","hysteria2":"%s","cert":%s,"wg_port":"%s","ref":"%s"}\n' \
    "$PUB_IP" "$DOMAIN" "$SUB_URL" "$L1" "$L2" "$CERT_JSON" "$WG_PORT" "${VULTR_VPN_REF:-unknown}"
  exit 0
fi

echo
echo "==============================================================="
echo " 部署完成"
echo "   服务器   : $PUB_IP   ($DOMAIN)"
echo "   WireGuard: udp $WG_PORT"
echo "   Reality  : tcp 443"
echo "   Hysteria2: udp 443"
echo "   订阅地址 : $SUB_URL"
echo "   客户端   : $CLIENTS/{windows,wsl,phone}.conf"
echo "==============================================================="
echo
echo "【节点链接】"
links
echo
if command -v qrencode >/dev/null 2>&1; then
  echo "【订阅二维码】（客户端扫这个，不要扫单节点）"
  qrencode -t ANSIUTF8 -m 1 "$SUB_URL" || true
  echo
fi
echo "【下一步】"
echo "  1) 手机  : v2rayNG → 订阅分组 → 添加订阅 → 粘贴上面地址 → 更新"
echo "  2) Windows: v2rayN → 订阅 → 订阅设置 → 添加 → 更新；再开「路由→绕过大陆」"
echo "  3) 体检  : bash setup.sh --check"
echo "  4) 换域名: bash setup.sh --domain 新域名   （自动重签证书并刷新订阅）"
echo
if [ "$HAVE_CERT" = "1" ]; then
  log "证书就绪，Hysteria2 用正式证书，客户端无需跳过校验"
else
  warn "当前是自签证书：Hysteria2 可能连不上。放行 tcp 80 后执行: bash setup.sh --cert-only"
fi
[ -n "${VULTR_API_KEY:-}" ] || warn "未提供 --vultr-key：记得在云厂商控制台手动放行 tcp 22/80/443 与 udp 443/$WG_PORT"

