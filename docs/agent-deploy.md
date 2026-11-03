# 让 AI Agent 全自动部署

> 这份文档不是写给人的操作手册，是**写给 AI agent 执行的 runbook**。
> 人只需要提供三样东西（SSH 访问、预算确认、要不要域名），剩下的可以全自动完成。

适用 agent：Claude Code、Codex、Cursor、Cline、DSH 等任何能执行 shell 的编码 agent。

---

## 0. 给人看：怎么用这份文档

把下面这段粘进你的 agent 对话框，替换尖括号里的内容：

```
请按 https://github.com/zjr284/vultr-vpn/blob/main/docs/agent-deploy.md 执行部署。

我的情况：
- 服务器：<已有 IP，或写"没有，帮我开一台">
- SSH 私钥：<~/.ssh/id_ed25519，或"没有，用密码">
- 域名：<vpn.example.com，或"没有，用 sslip.io">
- 预算：<最多花多少，比如 5 美元>
- 我的出口 IP（如果需要 Vultr API）：<agent 会自己查>
```

agent 会自己跑命令、验证、最后把**订阅地址**交给你。你要做的只剩"手机装客户端、粘贴订阅"。

---

## 1. Agent 执行前必须确认的三件事

在动手之前，agent **必须**向人确认，不能自己假设：

| 必须确认 | 为什么 | 默认动作 |
|---|---|---|
| **是否有现成服务器** | 决定走 SSH 模式还是 Vultr API 模式（后者会花钱） | 优先问；没答复不要自己开机器 |
| **预算上限** | 开机器 = 花钱 | 默认 $5/月档，且**失败要删机** |
| **域名** | 影响证书和订阅地址 | 没有就用 `<IP>.sslip.io`，不要去买域名 |

❌ **绝对不要**替人做这些决定：绑支付方式、注册云账号、买域名、开超预算的机型。

---

## 2. 凭据清单

| 凭据 | 用途 | 获取方式 |
|---|---|---|
| `SSH 私钥`（或 root 密码） | 登进服务器执行部署 | 人提供；`ssh-copy-id` 或 Vultr 的 SSH Key |
| `Vultr API Key` | 全自动开机器 + 配防火墙 | 人提供（仅 Vultr 模式需要） |
| 出口 IP | Vultr API Key 通常有 IP 白名单 | agent 自己查：`curl -s https://api.ipify.org` |

> ⚠️ Vultr API Key 若返回 **401**，99% 是"出口 IP 不在白名单"。
> 常见坑：agent 跑在 WSL/容器里，出口 IP 和人的浏览器不一样。**让人把 agent 的出口 IP 加进白名单**。

---

## 3. 执行：一键脚本

仓库自带 `scripts/agent_deploy.py`，把"连通 → 安装 → 体检 → 验证订阅 → 输出 JSON"全做了。

### 模式 A：已有服务器（推荐，零成本）

```bash
python3 scripts/agent_deploy.py \
  --host 203.0.113.10 \
  --ssh-key ~/.ssh/id_ed25519 \
  --ref v1.0.0
```

### 模式 B：从零开一台（付费，自动配防火墙）

```bash
export VULTR_API_KEY=...          # 人提供
python3 scripts/agent_deploy.py \
  --vultr-key "$VULTR_API_KEY" \
  --region nrt \
  --pubkey ~/.ssh/id_ed25519.pub \
  --ref v1.0.0
```

想先看它要干什么：

```bash
python3 scripts/agent_deploy.py --host 203.0.113.10 --dry-run
```

### 输出（stdout 只有一行 JSON）

```json
{
  "host": "203.0.113.10",
  "domain": "203-0-113-10.sslip.io",
  "subscription": "http://203-0-113-10.sslip.io/dsh-sub-1a2b3c4d.txt",
  "reality": "vless://...",
  "hysteria2": "hysteria2://...",
  "cert": true,
  "wg_port": "51821",
  "ref": "v1.0.0",
  "check_ok": true,
  "checks": ["服务 wg-quick@wg0  OK", "..."],
  "subscription_ok": true,
  "instance_id": null,
  "mode": "ssh",
  "ok": true
}
```

**agent 拿到 `ok: true` 就可以结束了**——把 `subscription` 交给用户即可。

---

## 4. 退出码 → agent 该做什么

| 退出码 | 含义 | agent 的动作 |
|---|---|---|
| `0` | 成功 | 把 `subscription` 和二维码/链接交给用户，结束 |
| `2` | 参数/环境问题（如 API 401） | 把 `hint` 原文转告用户，**不要重试** |
| `3` | SSH 不通 | 告诉用户检查 22 端口/密钥；可以试一次 `ping`，但**不要反复重试** |
| `4` | 安装脚本失败 | 附上 `hint`（最后 12 行日志）问用户，不要自己改服务器配置 |
| `5` | 体检未通过 | 附 `checks` 里 FAIL 的行，问用户 |

失败时若走了模式 B，脚本会**自动删掉实例止损**（除非 `--keep`）。

---

## 5. 如果不使用脚本，手工步骤（agent 自行实现时）

```bash
# 1) 确认系统
ssh -i KEY root@HOST 'lsb_release -ds; uname -m'      # 期望 Ubuntu 22.04/24.04

# 2) 一行安装（--json 让脚本末尾吐一行机器可读结果）
ssh -i KEY root@HOST 'bash <(curl -fsSL https://raw.githubusercontent.com/zjr284/vultr-vpn/v1.0.0/install.sh) --ref v1.0.0 --json'

# 3) 从输出里 grep 出：  VPN_JSON={...}

# 4) 体检
ssh -i KEY root@HOST 'bash /opt/vultr-vpn/setup.sh --check'   # 退出码 0 = 全绿

# 5) 验证订阅真能取到
ssh -i KEY root@HOST 'curl -fsS -o /dev/null -w "%{http_code}" http://DOMAIN/dsh-sub-XXXX.txt'   # 200
```

### 关键判断点

| 检查 | 期望 | 不满足怎么办 |
|---|---|---|
| `VPN_JSON.cert` | `true` | 等 2 分钟重跑 `setup.sh --cert-only`（云防火墙有延迟） |
| `setup.sh --check` | 退出码 0 | 看 FAIL 行，按 hint 处理 |
| 订阅 URL | HTTP 200 | `systemctl restart dsh-sub` 后重试 |
| 公网可达 | 从**外部** `curl -m 8 http://IP/` 返回 200 | 大概率云防火墙没放行，让人去控制台加 80/tcp |

---

## 6. 安全红线（agent 必须遵守）

1. **不打印** `config.env`、私钥、`wg show` 的 private key 到聊天里
2. **不提交** 任何含真实 IP / 密钥的文件到 git；本仓库 CI 会扫描
3. **不共享**：不要把订阅地址发到任何群/公开站点
4. **失败即止损**：模式 B 失败时删机器，别留着计费
5. **不越权**：只改 `/opt/vultr-vpn`、`/etc/wireguard`、`/usr/local/etc/xray`、`/etc/hysteria`、`/var/www/dsh-sub` 这些脚本自己管理的路径
6. **不替人决定**：付款、注册账号、买域名、改 DNS 记录（除非人明确授权并要求）

---

## 7. 人需要做的最后一公里

agent 干完活之后，剩下三件**必须人来做**的事：

1. 手机装客户端（Android：v2rayNG；iOS：需非国区 Apple ID）
2. 把订阅地址粘进客户端 → 更新订阅 → 选 `Tokyo-Reality`
3. 打开「绕过大陆」分流（否则国内网站也走代理）

细节见 [零基础教程](beginner.md) 第 6–8 节。

---

## 8. 已验证 / 未验证

诚实标注，避免 agent 盲信：

| 项目 | 状态 |
|---|---|
| `--json` 输出格式 | ✅ 在真实服务器上跑通 |
| SSH 模式（已有服务器） | ✅ 端到端跑通（v1.0.0） |
| `--check` 体检 | ✅ 全绿输出已验证 |
| 订阅可达性检查 | ✅ 200 验证 |
| 模式 B（Vultr API 建机） | ⚠️ 代码完成，但**未在真实 API 上跑通**（测试时 Key 已失效/白名单不含测试机） |
| 自动删机止损 | ⚠️ 同上，逻辑已写但未实测 |

> 模式 B 第一次跑时，建议人**盯着控制台**，并在跑完后确认实例状态：
> `curl -H "Authorization: Bearer $KEY" https://api.vultr.com/v2/instances`

---

## 9. 给 agent 的一句话总结

> 用 `scripts/agent_deploy.py` 一条命令搞定；只信 `ok:true`；失败读 `hint` 转告人；永不动钱、永不打印密钥。
