# Changelog

本文件记录每个版本的变更，供 `release.yml` 自动生成中文 Release 说明。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **发版流程**：先在本文件顶部加一节 `## [vX.Y.Z] - YYYY-MM-DD`，提交后打 tag：
> `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`。
> workflow 会抽取该节作为 Release 正文；找不到就回退到 GitHub 自动生成的英文 changelog。

## [Unreleased]

## [v1.1.1] - 2026-11-03

### 修复

- Release 正文中的中文变成 `????`：改为从本文件读取中文说明，不再依赖自动生成的英文 changelog。

## [v1.1.0] - 2026-11-03

### 新增

- `scripts/agent_deploy.py`：无人值守部署，支持「已有服务器（SSH）」与「从零开一台（Vultr API）」两条路径
  - stdout 只输出一行 JSON：`ok / check_ok / subscription_ok / subscription / cert / ref`
  - 退出码契约：`0` 成功 · `2` 参数或凭据 · `3` SSH 不通 · `4` 安装失败 · `5` 体检未过
  - 失败自动删除实例止损（`--keep` 可关闭）
- `setup.sh --json`：末尾多打一行 `VPN_JSON={...}`，供程序解析
- `docs/agent-deploy.md`：给 Agent 的 runbook（确认清单、命令、退出码、安全红线）
- 根目录 `AGENTS.md`：改代码的约定（自测命令、铁律、兼容性约束）
- `README.en.md`：英文说明

### 修复

- `vultr_firewall` 函数定义在调用之后导致 `command not found`
- 体检输出里的 ANSI 颜色码会污染 JSON

## [v1.0.0] - 2026-11-03

### 新增

- `install.sh` 一行入口，codeload / archive / ghproxy 三个下载源兜底
- `setup.sh` 参数化部署，首次运行生成 `config.env` 保存全部密钥（重装不换密钥）
- 三通道：Reality（tcp 443）/ Hysteria2（udp 443）/ WireGuard（udp 51821）
- 订阅服务 `dsh-sub`：80 端口 base64 节点列表，另带一个 HTML 清单页
- Let's Encrypt 证书 + 续期 hook；sshd 占用 443 时自动改回 22
- `--check` 体检、`--links` 打印节点、`--cert-only` 补签、`--reset` 重置
- 零基础教程（不用买域名）与排障文档
- CI（语法 / shellcheck / 密钥扫描）与打 tag 自动发 Release
