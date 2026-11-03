# AGENTS.md

给在这个仓库里干活的 AI agent 的约定。**部署到服务器**的流程见 [docs/agent-deploy.md](docs/agent-deploy.md)，这里讲的是**改代码**。

## 项目是什么

一套 bash + 一个 Python 小服务，在 Ubuntu 22.04/24.04 上部署三通道代理：

```
install.sh  → 下载仓库到 /opt/vultr-vpn → 调 setup.sh
setup.sh    → 装依赖 / 写配置 / 签证书 / 起订阅 / 打印结果
scripts/sub.py        → 订阅分发服务（systemd: dsh-sub）
scripts/agent_deploy.py → 无人值守部署（给 agent 用，输出单行 JSON）
```

## 改完必须自测

```bash
bash -n setup.sh && bash -n install.sh        # 语法
python3 -m py_compile scripts/sub.py scripts/agent_deploy.py
shellcheck -S error setup.sh install.sh      # 只允许 error 级为 0
bash setup.sh --links                        # 需要 config.env，否则会提示先部署
```

真实环境验证只能在一台一次性 VPS 上做（`--dry-run` 先看计划）。

## 铁律

1. **绝不提交** `config.env`、`clients/`、任何真实 IP / 密钥 / 订阅 token
   - CI 会扫描真实公网 IP 段与真实 token 形态（规则见 `.github/workflows/ci.yml`）；文档里的示例一律用 `203.0.113.10`（RFC 5737 保留段）
2. **幂等**：`setup.sh` 重复执行不能破坏已有配置；新增步骤要写成"存在则跳过"
3. **不覆盖密钥**：`config.env` 存在就复用；只有 `--reset` 才重新生成
4. **失败要可诊断**：所有 `die` 都给中文原因 + 下一步动作，不要裸 `exit 1`
5. **给人看的输出**用中文，**给机器看的**（`--json`、退出码）保持稳定契约

## 兼容性约束

- 目标系统只有 Ubuntu 22.04 / 24.04，**不要引入** `jq` 之外的重依赖（尽量只用 `python3`/`grep`/`awk`）
- 不要假设 `pwsh`、Node、Docker 存在
- `setup.sh` 顶部 `set -euo pipefail`，新增变量前先给默认值，否则 `--links` 这类轻量模式会炸
- 端口约定：`tcp 22/80/443`、`udp 443`（Hysteria2）、`udp 51821`（WireGuard）；改动要同步 README 与 setup.sh 的 `ufw` 列表

## 提交规范

- 提交信息用中文，前缀 `feat: / fix: / docs: / chore:`
- 发版：`git tag -a vX.Y.Z -m "..."` + `git push origin vX.Y.Z`，Release 由 workflow 自动生成
- 改 README 的"快速开始"时必须同步 `docs/02-deploy.md`，两边都在被用户直接照抄
