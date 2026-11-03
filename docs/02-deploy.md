# 02 · 部署

## 前置条件

- Ubuntu 22.04 / 24.04，root 权限
- 能访问 GitHub（脚本要从 GitHub 装 Xray 和 Hysteria2）
- 防火墙放行 tcp 22 / 80 / 443、udp 443 / 51821 —— 或者给脚本一个 Vultr API Key，它自己开

## 方式零：一行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zjr284/vultr-vpn/main/install.sh) --domain vpn.example.com
```

连防火墙一起：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zjr284/vultr-vpn/main/install.sh) \
     --vultr-key "$VULTR_API_KEY" --vultr-fw vpn --domain vpn.example.com
```

脚本会自动下载仓库到 `/opt/vultr-vpn`、装依赖、配三通道、签证书、起订阅、打印二维码。
重复执行是安全的（幂等），升级脚本版本也只需要重跑这一行。

## 方式一：用 sslip.io 自动域名（零成本）

```bash
scp -r . root@<IP>:/opt/vultr-vpn/     # 或者 git clone
ssh root@<IP> "bash /opt/vultr-vpn/setup.sh"
```

脚本会从公网 IP 推导域名，例如 IP 是 `203.0.113.10`，域名就是 `203-0-113-10.sslip.io`。
`sslip.io` 是公共泛解析服务，任何人访问 `203-0-113-10.sslip.io` 都会解析到 `203.0.113.10`，**不需要买域名**。

> 缺点：域名里带 IP，换服务器域名就变了，客户端要重新导入。

## 方式二：用自己的域名（推荐）

1. DNS 加一条 A 记录：`vpn.example.com → <IP>`（如果走 Cloudflare，**关掉橙色云朵**）
2. 确认解析生效：

   ```bash
   dig +short vpn.example.com @223.5.5.5
   dig +short vpn.example.com @8.8.8.8
   ```

3. 部署：

   ```bash
   bash /opt/vultr-vpn/setup.sh --domain vpn.example.com
   ```

之后换 IP 只需要改这条 A 记录，**客户端一个字都不用动**——这是自建代理里性价比最高的一步。

## 脚本执行流程

```
[+ ] 安装依赖（wireguard-tools / curl / certbot / xray）
[+ ] 生成配置（随机密钥）            # 首次运行
[+ ] 写入内核/网络调优
[+ ] 写入 WireGuard 配置
[+ ] 写入 Xray Reality 配置
[+ ] 签发 Let's Encrypt 证书
[+ ] 写入 Hysteria2 配置
[+ ] 配置订阅服务
[+ ] 配置 ufw
```

产物：

| 路径 | 内容 |
|---|---|
| `config.env` | 全部密钥（**不要提交，已在 .gitignore**） |
| `clients/*.conf` | WireGuard 客户端配置 |
| `/etc/wireguard/wg0.conf` | 服务端 WireGuard |
| `/usr/local/etc/xray/config.json` | Xray |
| `/etc/hysteria/config.yaml` | Hysteria2 |
| `/var/www/dsh-sub/<token>.txt` | 订阅文件（base64） |

## 验证

```bash
systemctl is-active wg-quick@wg0 xray hysteria-server dsh-sub
wg show
ss -lntup | grep -E ':(80|443|51821)\b'
curl -s http://127.0.0.1/ | head -c 0 && echo "订阅端口 OK"
```

## 常见报错

### `certbot` 报 `Timeout during connect`

云防火墙没放行 tcp 80，或者规则还没生效。放行后等 1~3 分钟再跑：

```bash
bash setup.sh --cert-only
```

### `Address already in use`（443）

sshd 可能占用了 443（有些教程会让你把 SSH 也放 443）。改成只监听 22：

```bash
sudo sed -i 's/^Port 443/#Port 443/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### Xray 启动后警告 `target 使用 CDN 域名会提高封 IP 概率`

脚本默认用 `www.yahoo.co.jp` 作为 Reality 的伪装目标，一般没有这个问题。如果你改成 `www.microsoft.com` 之类的 CDN 域名，会看到这条警告 —— 换成非 CDN 的真实站点即可。

### `Failed to build TLS config ... allowInsecure has been removed`

新版 Xray 内核不允许跳过证书校验。说明你用了自签证书 —— 放行 tcp 80 重新签正式证书即可。

## 换域名

```bash
bash setup.sh --domain new.example.com
```

脚本会重新签证书、更新订阅内容。然后在客户端点一次"更新订阅"。

## 更新订阅内容（不换域名）

```bash
vpn-sub-update            # 用 config.env 里的域名
vpn-sub-update vpn.xxx.com # 临时指定
```
