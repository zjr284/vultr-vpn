# vultr-vpn

[![ci](https://github.com/zjr284/vultr-vpn/actions/workflows/ci.yml/badge.svg)](https://github.com/zjr284/vultr-vpn/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/zjr284/vultr-vpn)](https://github.com/zjr284/vultr-vpn/releases)
[![license](https://img.shields.io/github/license/zjr284/vultr-vpn)](LICENSE)

> **One command. Three independent proxy channels. Built for humans and AI agents.**
> WireGuard + Xray Reality + Hysteria2 + a subscription URL, on your own VPS.

中文说明 → [README.md](README.md)

> ⭐ If it saves you an afternoon, a [star](https://github.com/zjr284/vultr-vpn/stargazers) helps other people find it.
> Built and battle-tested with **DeepSeek Harness** — including the agent deploy path, which the harness ran end-to-end on a live VPS.

---

## Why another one-click script?

Most "one-click" proxy scripts give you a single protocol. When that protocol gets fingerprinted, or the IP gets blocked, everything dies at once and you start over.

This one runs **three channels on one box, with three different anti-blocking strategies**:

| Channel | Transport | Survives |
|---|---|---|
| **Xray VLESS + Reality** | TCP 443, borrows a real site's TLS handshake | protocol fingerprinting, no domain needed |
| **Hysteria2** | QUIC / UDP 443 | packet loss, jitter, high-latency links |
| **WireGuard** | UDP 51821 | everything, but is the most fingerprintable |

When one gets blocked, switch clients — and because **all keys live in `config.env`, clients never change** across rebuilds.

## Features

- **Three channels, one script** — Reality (TCP 443), Hysteria2 (UDP 443), WireGuard (UDP 51821)
- **Agent-native** — `scripts/agent_deploy.py` deploys end-to-end and prints a single JSON line; a machine-readable `--json` contract, documented exit codes, auto-destroy on failure
- **Zero-touch TLS** — Let's Encrypt + renewal hooks; no `allowInsecure` (removed in newer Xray cores)
- **Subscription service** — one URL imports every node, served by a tiny systemd unit on port 80
- **Idempotent** — re-runnable; existing `config.env` and keys are reused, never overwritten
- **CN split routing** — `geoip:cn` / `geosite:cn` go direct, saving a hop
- **Beginner docs** — a 17 KB step-by-step guide for people who have never touched a server

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zjr284/vultr-vpn/main/install.sh)
```

On a fresh Ubuntu 22.04 / 24.04 box as root. It installs everything, obtains a certificate, starts the subscription service, then prints:

```
订阅地址: http://203-0-113-10.sslip.io/dsh-sub-1a2b3c4d.txt
VLESS:    vless://...
Hysteria2: hysteria2://...
```

Paste the subscription URL into v2rayNG / v2rayN / Shadowrocket → update → connect.

Pin a version in production:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zjr284/vultr-vpn/v1.1.0/install.sh) --ref v1.1.0
```

## Deploy it with an AI agent

This repo is designed to be driven by coding agents (Claude Code, Codex, Cursor, DSH…):

```bash
python3 scripts/agent_deploy.py --host 203.0.113.10 --ssh-key ~/.ssh/id_ed25519 --ref v1.1.0
```

Output is exactly one JSON line:

```json
{"host":"203.0.113.10","domain":"203-0-113-10.sslip.io","subscription":"http://...","ok":true,"check_ok":true,"subscription_ok":true,"cert":true}
```

Exit codes: `0` ok · `2` bad args/credentials · `3` SSH unreachable · `4` install failed · `5` health check failed. On failure the JSON carries a `hint`, and Vultr mode destroys the instance to stop billing.

Full runbook for agents: [docs/agent-deploy.md](docs/agent-deploy.md) · conventions for contributing: [AGENTS.md](AGENTS.md)

## What it installs

| Service | Port | Notes |
|---|---|---|
| `xray` | TCP 443 | VLESS + Reality, `xtls-rprx-vision` |
| `hysteria-server` | UDP 443 | password auth, Let's Encrypt cert, bandwidth tuned |
| `wg-quick@wg0` | UDP 51821 | 10.8.0.0/24 |
| `dsh-sub` | TCP 80 | subscription file (also used by ACME) |

## Requirements

- Ubuntu 22.04 / 24.04, root, 1 vCPU / 1 GB RAM is plenty
- A public IPv4; no domain required (`<ip>.sslip.io` is used, or pass `--domain`)
- Cloud firewall: allow tcp 22/80/443 and udp 443/51821 — or pass `--vultr-key` and let the script do it

## Docs

| Doc | What |
|---|---|
| [docs/beginner.md](docs/beginner.md) | Zero-knowledge walkthrough: sign up → deploy → phone connected (Chinese) |
| [docs/agent-deploy.md](docs/agent-deploy.md) | Runbook for AI agents |
| [docs/02-deploy.md](docs/02-deploy.md) | Deployment details & flags |
| [docs/03-clients.md](docs/03-clients.md) | Android / iOS / Windows / WSL clients |
| [docs/04-troubleshoot.md](docs/04-troubleshoot.md) | Symptom → cause → fix table |
| [docs/05-rebuild.md](docs/05-rebuild.md) | Rebuild after an IP block in ~15 min |

## Benchmarks (Tokyo → campus network in Beijing)

| Path | Download | TTFB |
|---|---|---|
| Direct | 11.9 MB/s | 449 ms |
| Reality | 15.3 MB/s | 426 ms |
| Hysteria2 (after tuning) | 25.0 MB/s | 281 ms |

Latency, not bandwidth, is the bottleneck: 160–190 ms RTT with 100 ms+ jitter on the international link.

## Honest caveats

- The subscription service lives on the same box — if the IP is blocked, the subscription is unreachable too. Fix: your own domain + Cloudflare DNS.
- Hysteria2 uses `<ip>.sslip.io`, which changes when the IP changes; pass `--domain` to avoid re-issuing certs.
- This is a self-hosting tool. You are responsible for complying with the laws and terms of service where you live.

## License

MIT
