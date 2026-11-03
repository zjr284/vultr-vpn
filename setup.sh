#!/usr/bin/env bash
# =============================================================================
#  vultr-vpn — 一条命令搭好三通道代理
#  WireGuard(udp 51821) + Xray Reality(tcp 443) + Hysteria2(udp 443) + 订阅服务
#
#  用法（root，Ubuntu 22.04/24.04）:
#     bash setup.sh                          # 用 <IP>.sslip.io 域名
#     bash setup.sh --domain vpn.example.com # 用自己的域名（推荐）
#     bash setup.sh --links                  # 只打印节点链接
#     bash setup.sh --cert-only              # 只补签证书
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

MODE="deploy"; ARG_DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)    ARG_DOMAIN="$2"; shift 2;;
    --links)     MODE="links"; shift;;
    --cert-only) MODE="cert"; shift;;
    -h|--help)   sed -n '3,14p' "$0"; exit 0;;
    *) die "未知参数: $1";;
  esac
done

# ---------------------------------------------------------------- 基础软件
export DEBIAN_FRONTEND=noninteractive
if ! command -v xray >/dev/null || ! command -v wg >/dev/null; then
  log "安装依赖（wireguard-tools / curl / certbot / xray）"
  apt-get update -qq
  apt-get install -y -qq wireguard-tools iptables curl ca-certificates certbot python3 >/dev/null
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

[ -f "$CONFIG" ] || gen_config
# 补全老配置里缺的字段
[ -n "${SUB_TOKEN:-}" ] || { SUB_TOKEN="dsh-sub-$(openssl rand -hex 4)"; echo "SUB_TOKEN=\"$SUB_TOKEN\"" >>"$CONFIG"; }
[ -n "${HY2_PASSWORD:-}" ] || { HY2_PASSWORD="$(openssl rand -hex 8)"; echo "HY2_PASSWORD=\"$HY2_PASSWORD\"" >>"$CONFIG"; }
# 允许 --domain 覆盖
if [ -n "$ARG_DOMAIN" ] && [ "$ARG_DOMAIN" != "$(grep -oP '^DOMAIN="\K[^"]*' "$CONFIG" || true)" ]; then
  sed -i "s|^DOMAIN=.*|DOMAIN=\"$ARG_DOMAIN\"|" "$CONFIG"
  DOMAIN="$ARG_DOMAIN"
fi

log "默认网卡=$IFACE 公网IP=$PUB_IP 域名=$DOMAIN"

links() {
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-Reality\n' \
    "$XRAY_UUID" "$DOMAIN" "$XRAY_SNI" "$XRAY_PUBKEY" "$XRAY_SHORTID" "${1:-Tokyo}"
  printf 'hysteria2://%s@%s:443/?sni=%s#%s-Hysteria2\n' \
    "$HY2_PASSWORD" "$DOMAIN" "$DOMAIN" "${1:-Tokyo}"
}

if [ "$MODE" = "links" ]; then links; exit 0; fi

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

# ---------------------------------------------------------------- 防火墙
log "配置 ufw"
ufw --force enable >/dev/null 2>&1 || true
for r in 22/tcp 80/tcp 443/tcp 8443/tcp "$WG_PORT"/udp 443/udp; do
  ufw allow "$r" >/dev/null 2>&1 || true
done
ufw route allow in on wg0 out on "$IFACE" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 汇总
echo
echo "==============================================================="
echo " 部署完成"
echo "   服务器   : $PUB_IP   ($DOMAIN)"
echo "   WireGuard: udp $WG_PORT"
echo "   Reality  : tcp 443"
echo "   Hysteria2: udp 443"
echo "   订阅地址 : http://$DOMAIN/$SUB_TOKEN.txt"
echo "   客户端   : $CLIENTS/{windows,wsl,phone}.conf"
echo "==============================================================="
links
echo
echo "记得在云厂商防火墙放行: tcp 22 / 80 / 443，udp 443 / $WG_PORT"
[ "$HAVE_CERT" = "1" ] || warn "当前是自签证书，放行 tcp 80 后执行: bash setup.sh --cert-only"
