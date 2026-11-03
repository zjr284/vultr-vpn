# 05 · 被封之后：15 分钟重建

## 1. 先确认是不是真的被封

不要一看到连不上就重装。按顺序排除：

```bash
# ① 本机能上网吗（关掉代理）
ping 223.5.5.5

# ② 服务器还活着吗
ping <IP>

# ③ 服务器自己在不在线（从别的路径 SSH）
ssh root@<IP> "uptime; curl -s ifconfig.me"

# ④ 端口通不通
curl -m 5 http://<IP>/
```

| 现象 | 结论 |
|---|---|
| ping 通、80/443 也通 | 服务器正常，问题在客户端或本地网络 |
| ping 通、端口不通 | 防火墙规则丢了，或端口被单独针对 |
| **ping 不通、所有端口超时** | **IP 被整段墙，换机器** |
| 服务器自己 curl 正常 | 服务器没问题，是链路 |

> 判断"IP 被墙"的铁证：连 **tcp 80** 都连不上，而服务器自己往外访问一切正常。

## 2. 开新机器

Vultr 控制台 → `Deploy New Server`：

```
Type      : Cloud Compute - Shared CPU
Location  : Tokyo（或换一个，有时换机房比换 IP 更有效）
Image     : Ubuntu 24.04 LTS x64
Plan      : vc2-1c-1gb ($5/mo)
SSH Keys  : 选已有的 key
Firewall  : 挂上原来的防火墙组（端口规则不用重建）
Hostname  : wg-tokyo
```

## 3. 部署

```bash
scp setup.sh root@<新IP>:/root/
ssh root@<新IP> "bash /root/setup.sh"
```

**两种模式，取决于你之前有没有用域名：**

### 有域名（推荐做法）

```bash
bash /root/setup.sh --domain vpn.example.com
```

1. 去 DNS 把 A 记录改成新 IP
2. 等解析生效（`dig +short vpn.example.com @8.8.8.8`）
3. 客户端**什么都不用改**

### 没域名（sslip.io）

脚本会打印新的订阅地址（域名里带新 IP）：

```
订阅地址 : http://203-0-113-20.sslip.io/dsh-sub-xxxxxxxx.txt
```

客户端里把订阅地址改一次，更新订阅即可。**节点密钥没变，不用重新导入。**

## 4. 检查

```bash
systemctl is-active wg-quick@wg0 xray hysteria-server dsh-sub
wg show
curl -sk https://vpn.example.com/ -o /dev/null -w '%{http_code}\n'
```

## 5. 销毁旧机器

Vultr → 旧实例 → `Server Destroy`，否则继续按小时计费。

## 6. 为什么客户端不用改

因为脚本把密钥存在 `config.env` 里，重新部署时是**复用**而不是重新生成：

```bash
# setup.sh 里
if [ -f "$CONFIG" ]; then
  source "$CONFIG"     # 已有配置就直接用
fi
```

所以：

| 变了 | 没变 |
|---|---|
| 服务器 IP | WireGuard 密钥 |
| 域名里的 IP（sslip.io） | Reality UUID / 公私钥 |
| 证书（重新签发） | Hysteria2 密码 |
| | 客户端 10.8.0.x 地址 |

## 7. 减少被封概率

1. **不要分享节点**——共享 IP 是最常见的被封原因
2. **优先用 Reality**，WireGuard 的原生 UDP 特征最明显
3. **不要用常见端口扫量**：51820 是 WireGuard 默认端口，脚本特意用了 51821
4. **域名不要发到公开场合**（论坛、GitHub issue）
5. **留一台备用机**，或者准备一个商业机场应急

## 8. 进阶：自动化

被封后最麻烦的是"发现得晚"。可以加个定时探测：

```bash
# /etc/cron.d/vpn-check
*/10 * * * * root curl -m 10 -s https://www.google.com -o /dev/null || curl -s -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" -d "chat_id=<CHAT>&text=vpn down"
```

连续失败再告警，避免误报。
