# 04 · 连不上怎么查

> 排查原则：**从外到内、从底层到上层**。不要一上来就重装。

## 一张表定位问题

按顺序做，每步都能排除一类原因：

| # | 测什么 | 命令 | 正常 | 异常说明 |
|---|---|---|---|---|
| 1 | 本机有没有网 | 关代理，开浏览器 | 能上网 | 本机网络问题，与服务器无关 |
| 2 | 服务器活没活 | `ping <IP>` | 通 | 不通 → IP 可能被墙（见第 3 节） |
| 3 | 端口通不通 | `curl -m 5 http://<IP>/` | 有响应（200/404 都行） | 超时 → 防火墙/线路问题 |
| 4 | 服务在不在 | SSH: `systemctl is-active xray hysteria-server wg-quick@wg0` | 全 `active` | 有 `failed` → 看日志 |
| 5 | 出站通不通 | SSH: `curl -s ifconfig.me` | 返回 IP | 服务器没外网 |
| 6 | 端口有没有监听 | `ss -lntup \| grep -E ':(443\|51821)'` | 有 xray/hysteria | 配置没生效 |

## 症状 → 原因

### A. 客户端显示"已连接"，但打不开网页

这是最常见的问题。按这个顺序排：

1. **看传输量**：v2rayNG 节点详情里有"接收/发送"
   - 发送在涨、接收为 0 → **握手包发出去了但服务器没收到** → IP 或端口被封（不是配置问题）
   - 两边都在涨但网页打不开 → DNS 或分流规则问题
2. **服务端抓包**：

   ```bash
   sudo tcpdump -ni any 'udp port 443' -c 5 -U
   ```

   手机连一下，如果**一个包都没有**，就是中途被丢了。
3. **换 IP 验证**：这是终极判定。同样配置换台机器就通 → 100% 是 IP 问题。

> 我们实际遇到过：某个东京 IP 连 tcp 80 都是超时，但服务器自己访问外网完全正常。
> 这种"IP 整段黑洞"没有任何配置能救，只能换 IP。

### B. 证书相关

| 报错 | 原因 | 解决 |
|---|---|---|
| `allowInsecure has been removed` | 新版 Xray 不允许跳过证书校验 | 用正式证书，别用自签 |
| `certificate has expired` | 没续期 | `certbot renew --dry-run` 检查 |
| `x509: certificate signed by unknown authority` | 自签证书 | 同上 |

检查证书：

```bash
openssl s_client -connect vpn.example.com:443 -servername vpn.example.com 2>/dev/null | openssl x509 -noout -dates -subject
```

### C. 防火墙

```bash
sudo ufw status numbered
sudo iptables -t nat -S POSTROUTING
sysctl net.ipv4.ip_forward
```

云厂商那层的防火墙**在系统里看不到**，要去网页控制台查。改动有 1~3 分钟延迟。

### D. WireGuard 连上但没流量

```bash
wg show                     # 有没有 latest handshake
sysctl net.ipv4.ip_forward  # 必须是 1
iptables -t nat -S POSTROUTING | grep MASQUERADE
```

客户端 `AllowedIPs = 0.0.0.0/0` + 服务端 PostUp 的 MASQUERADE 缺一不可。

WSL 里跑 WireGuard 时，MTU 建议设 `1280`（NAT 双重封装容易分片）。

## 日志命令

```bash
journalctl -u xray -n 50 --no-pager
journalctl -u hysteria-server -n 50 --no-pager
journalctl -u wg-quick@wg0 -n 30 --no-pager
tail -f /var/log/nginx/error.log   # 如果你加了 nginx
```

## 速度慢

先分清是**带宽**还是**延迟**：

```bash
# 服务器到外网的带宽（不是你家到服务器）
curl -o /dev/null -w '%{speed_download}\n' https://speed.cloudflare.com/__down?bytes=50000000

# 回程路由
mtr -rw -c 20 219.158.3.29      # 北京联通
```

- 服务器下载 50MB/s，你只有 5MB/s → 瓶颈在国际链路 → 换优化线路（CN2 GIA / 9929）
- 服务器自己就慢 → 换机房

**换协议解决不了物理延迟。** 150ms 就是 150ms，只有换线路能变。

## 订阅打不开

订阅服务在 80 端口，和节点同机：

- IP 被封 → 订阅一起打不开（这是无域名方案的固有短板）
- 检查服务：`systemctl status dsh-sub`、`curl -s http://127.0.0.1/`
- 检查文件：`ls -l /var/www/dsh-sub/`
