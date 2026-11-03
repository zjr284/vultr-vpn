# 03 · 客户端配置

订阅地址形如：

- `https://vpn.example.com:8443/dsh-sub-xxxxxxxx.txt`（推荐，需要云防火墙放行 tcp 8443）
- `http://vpn.example.com/dsh-sub-xxxxxxxx.txt`（备用，明文；v2rayNG/v2rayN 会提示"不安全的 HTTP"）

内容是一串 base64，解码后是两行节点链接（Reality + Hysteria2）。WireGuard 不放进订阅，因为它需要独立的 `.conf` 文件。

> ⚠️ **客户端提示"请不要使用不安全的 HTTP 协议订阅地址"怎么办？**
> 优先把地址换成 `https://域名:8443/...`；如果暂时没放行 8443，就在客户端里打开「允许不安全的 HTTP 地址」开关（v2rayNG 在订阅设置最下方）。

---

## Android：v2rayNG

1. 安装 [v2rayNG](https://github.com/2dust/v2rayNG/releases)（选 `arm64-v8a`）
2. 底部 **订阅分组** → 右上 `+` → **添加订阅**
   - 备注：`Tokyo`
   - 地址：粘贴订阅 URL
3. 右上 `⋮` → **更新订阅** → 列表出现两个节点
4. 点一个 → 右下角 ▶ 连接（首次会请求 VPN 权限）
5. **设置 → 路由设置 → 绕过大陆**（必做）

### 为什么一定要设分流

不开分流时，访问 `baidu.com` 也会绕到东京再回来——延迟从 10ms 变成 150ms，还费流量。

v2rayNG 的「绕过大陆地址」内置了国内 IP 段和域名规则，开了之后只有墙外流量走代理。

### 想更精细：自定义路由

「路由设置 → 自定义规则」可以按域名/应用分流，例如：

```json
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:cn"], "outboundTag": "direct" },
      { "type": "field", "outboundTag": "proxy" }
    ]
  }
}
```

---

## Windows：v2rayN

1. 下载 `v2rayN-windows-64.zip` 解压运行
2. **订阅分组 → 订阅设置 → 添加**，粘贴 URL → 确定
3. **订阅分组 → 更新订阅**
4. 选中节点 → 右键 **设为活动服务器**
5. 系统代理 → **自动配置系统代理**
6. 路由 → **绕过大陆**

> v2rayN 默认只监听 `127.0.0.1`。如果想让 WSL 或局域网设备用，去「参数设置 → 基础设置」勾选 **允许来自局域网的连接**。

---

## Windows：WireGuard（全局）

1. 装 [WireGuard for Windows](https://www.wireguard.com/install/)
2. 「导入隧道 → 从文件导入」选 `clients/windows.conf`
3. 点「激活」

WireGuard 是**全局代理**，没有分流，国内网站也会绕路。适合临时用，或者需要 UDP 全流量（游戏、P2P）的场景。

---

## macOS / iOS

- iOS：App Store 装 `Shadowrocket`（付费）或 `Streisand`（免费），直接粘贴单节点链接
- macOS：`V2RayXS` 或 `v2rayU`，导入方式同 Windows

---

## WSL

WSL2 是独立网络命名空间，**Windows 的系统代理不会自动继承**。

### 方式一：借用 Windows 上的 v2rayN（推荐）

先在 v2rayN 勾选「允许来自局域网的连接」，然后：

```bash
export host_ip=$(ip route show default | awk '{print $3}')
export ALL_PROXY="socks5h://${host_ip}:10808"
export http_proxy="http://${host_ip}:10809"
export https_proxy="http://${host_ip}:10809"
```

写进 `~/.bashrc` 免得每次敲：

```bash
if grep -qi microsoft /proc/version 2>/dev/null; then
  _win_ip=$(ip route show default | awk '{print $3}')
  export ALL_PROXY="socks5h://${_win_ip}:10808"
fi
```

> 用 `socks5h` 而不是 `socks5`：`h` 表示让代理解析 DNS，否则 WSL 自己解析国外域名可能失败或泄漏。

### 方式二：直接在 WSL 里跑客户端

```bash
hysteria client -c ~/hysteria.yaml &
export ALL_PROXY="socks5h://127.0.0.1:20809"
```

### apt 不走环境变量

```bash
sudo tee /etc/apt/apt.conf.d/99proxy >/dev/null <<EOF
Acquire::http::Proxy "http://${host_ip}:10809";
Acquire::https::Proxy "http://${host_ip}:10809";
EOF
```

### git 也不走系统代理

```bash
git config --global http.proxy http://127.0.0.1:10809
```

---

## 验证是否生效

```bash
curl -s https://api.ip.sb/ip     # 应该返回服务器 IP
curl -s https://www.google.com -o /dev/null -w '%{http_code}\n'
```

---

## 怎么选通道

| 场景 | 推荐 |
|---|---|
| 日常浏览、视频 | Reality（抖动低，像正常 HTTPS） |
| 游戏、语音（UDP） | Hysteria2（QUIC 抗丢包） |
| 需要完整 UDP / 局域网互通 | WireGuard |
| 一个挂了 | 手动切另一个；v2rayN 可开「自动选择」 |
