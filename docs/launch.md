# 发布与推广 Playbook

> 目标不是"骗星星"，是让**真正需要它的人**看到。星星是结果，不是手段。
> ⚠️ 买星/互星属于 GitHub 明确禁止的 abuse 行为，会被清空甚至封号，本文件不涉及。

---

## 0. 先把"转化漏斗"修好（不做这步，发哪都没用）

用户从点进来 to 点 star，中间只给你 **10 秒**。检查这 5 项：

| 项 | 现状 | 要做 |
|---|---|---|
| **仓库简介（description）** | 已有 | 改成一句话讲清"是什么 + 给谁" |
| **Topics** | ❌ 空的 | 必须填，GitHub 搜索靠它 |
| **社交预览图** | ❌ 没有 | 上传 `assets/social-preview.png`（1280×640） |
| **README 首屏** | 中文只有一段 | 一句话 + 一张图 + 一行命令，3 秒能懂 |
| **English README** | ✅ `README.en.md` | 顶部互链，否则海外用户直接关掉 |

### 建议填的 topics（复制即用）

```
vpn wireguard xray reality hysteria2 vless proxy self-hosted ubuntu vultr
one-click installer ai-agent claude-code codex subscription
```

### 建议的 description

> 一条命令搭好 WireGuard + Xray Reality + Hysteria2 三通道代理，自带订阅服务；附零基础教程与 AI Agent 部署接口。

英文版（更利于被搜到）：

> One command to deploy WireGuard + Xray Reality + Hysteria2 on your VPS — with a subscription URL, a beginner guide, and an agent-native deployer.

---

## 1. 你得有一个"一句话差异点"

同类项目已经卷到天上（`233boy/sing-box`、`yonggekkk/argosbx`、`mack-a/v2ray-agent` 都是几千星）。你的东西如果只是"又一个一键脚本"，不会有星星。

目前这个仓库真正稀缺的三点，按传播力排序：

1. **第一个为 AI Agent 设计的一键翻墙脚本**
   —— 2026 年这个时间点，"让 Claude Code 帮我把 VPN 部署好"是新鲜叙事。
   `--json` 契约、退出码、失败自动删机，这些是"给机器用的接口"，别人没有。
2. **三通道同机 + 密钥持久化**
   —— 换服务器客户端不用重配，这解决的是真实痛点（大多数脚本做不到）。
3. **零基础教程 17 KB**
   —— "不用买域名、不用懂 Linux、30 分钟"是搜索长尾流量入口。

**发布时只讲第 1 条当标题，第 2、3 条放正文。**

---

## 2. 渠道清单（按 ROI 排序）

| 渠道 | 版块 / 方式 | 适合文案 | 注意 |
|---|---|---|---|
| **V2EX** | `/go/programmer` 或 `/go/create` | A | 别放纯推广口吻，讲"我踩的坑 + 解法"更吃得开；标题带"已开源" |
| **LINUX DO** | `开发` / `软件` 分区 | A | 社区对"AI 写的项目"接受度高，直接讲 agent 部署 |
| **GitHub Topics** | 靠 topics 被搜到 | — | 填满 10 个以上 topics |
| **Reddit** | r/selfhosted、r/China_Internet、r/VPN | B（英文） | r/selfhosted 反感"代理工具"营销，讲 self-host 与自动化 |
| **Hacker News** | Show HN | C（英文） | 只在拿到 ~50 star 后发，否则容易被当 spam |
| **少数派 / 知乎** | 投稿 / 回答"如何自建梯子" | D（长文） | 长尾流量最好，一篇能吃半年 |
| **Telegram 群** | 自建代理 / VPS 交流群 | A | 不要刷屏，发一次 + 答疑 |
| **awesome-lists** | PR 到 self-hosted 类清单 | — | 多数不收代理工具，先看 CONTRIBUTING 再提，别硬塞 |

> 前 100 颗星 **100% 来自人肉分发**，不存在"发上去自然涨"。发 3 个渠道 = 大概 10–30 星（如果 README 转化 OK）。

---

## 3. 文案模板

### A. 中文社区（V2EX / LINUX DO / Telegram）

> **标题：我让 AI 自己把我的 VPN 服务器部署好了（已开源）**
>
> 上周我的代理 IP 被封了，重装一遍要手工改五个配置文件、三套客户端。
> 烦了，就把整套东西写成脚本 + 给 AI 用的接口，现在重装系统后只要说一句"帮我部署"，Agent 会自己 SSH 上去、装好、体检、把订阅地址给我。
>
> 三条通道在同一台机器上：Reality（TCP 443）、Hysteria2（UDP 443）、WireGuard（UDP 51821），一条挂了还有两条。
> 密钥存在 `config.env`，换机器客户端不用重配。
>
> 几个踩过的坑都写进文档了：
> - 目标 IP 被整段黑洞（不是端口问题，连 80 都不通）
> - 新版 Xray 内核移除了 `allowInsecure`，必须上真证书
> - 云防火墙规则生效有延迟，证书签发会假超时
>
> 仓库：https://github.com/zjr284/vultr-vpn
> 零基础教程（不用买域名）：docs/beginner.md
> 给 Agent 的部署说明：docs/agent-deploy.md
>
> 欢迎提 issue，尤其是"你的网络环境下哪条通道能活"。

### B. Reddit（r/selfhosted）

> **Title: I made my AI agent deploy my self-hosted VPN stack — here's the JSON contract**
>
> Got tired of rebuilding three configs after every IP block, so I wrote a one-shot deployer that an agent can drive end-to-end.
>
> - Three channels on one box: Xray Reality (TCP 443), Hysteria2 (UDP 443), WireGuard (UDP 51821)
> - `setup.sh --json` returns one machine-readable line: subscription URL, node links, cert status
> - `scripts/agent_deploy.py` handles SSH, install, health check, subscription verification; exit codes 0/2/3/4/5; destroys the instance on failure so you don't pay for a broken box
> - Keys live in `config.env`, so clients survive rebuilds
>
> Repo: https://github.com/zjr284/vultr-vpn (MIT)
> Happy to hear which channel survives your ISP.

### C. Show HN

> **Show HN: One-command VPN stack designed to be deployed by an AI agent**
>
> I kept rebuilding my personal VPN after IP blocks. So instead of another interactive installer, I made the whole thing machine-drivable: `setup.sh --json` prints a single JSON line (subscription URL, node URIs, cert state), and `scripts/agent_deploy.py` runs the whole thing from an agent with documented exit codes.
>
> Three transports on one host — VLESS+Reality on TCP/443, Hysteria2 on UDP/443, WireGuard on UDP/51821 — so a single blocking event doesn't take everything down. Keys persist in config.env, so clients don't change when you rebuild.
>
> Ubuntu 22.04/24.04, no domain needed (`<ip>.sslip.io` + Let's Encrypt).
>
> https://github.com/zjr284/vultr-vpn

### D. 知乎 / 少数派（长文骨架）

1. 为什么我不用机场（可控性 / 隐私 / 成本）
2. 三种协议到底差在哪（Reality / Hysteria2 / WireGuard 一张对比表）
3. 我的被封实录：怎么判断是 IP 被封而不是配置错
4. 一键部署全过程（截图 + 命令）
5. 让 AI 帮我运维（agent 部署）
6. 成本与合规边界

---

## 4. 发出去之后

- **24 小时内必须回评论**，前 10 条回复决定帖子会不会沉
- 有人报"我这边连不上"→ 记下来，这就是下一篇文档的素材（`docs/04-troubleshoot.md`）
- 每个真实 issue 修完都发一个小 release，Release 页面本身就是流量入口
- 每周看一次 `Insights → Traffic`，比看 star 数有用：**来源页 > 访问量 > star**

## 5. 明确别做的事

- ❌ 买星、互星群、star 农场 —— GitHub 会清洗，账号有风险
- ❌ 在别人 README / issue 里贴自己链接
- ❌ 标题党写"永久免费 / 永不封"——被举报一次就凉
- ❌ 承诺"国内直连速度飞快"——你的实测数据不支持
