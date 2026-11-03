#!/usr/bin/env python3
"""agent_deploy.py —— 给 AI agent 用的无人值守部署器

两种模式：

  1) 已有服务器（推荐先试这个，最省事）：
       python3 scripts/agent_deploy.py --host 203.0.113.10 --ssh-key ~/.ssh/id_ed25519

  2) 从零开一台（需要 Vultr API Key，会产生费用）：
       python3 scripts/agent_deploy.py --vultr-key "$VULTR_API_KEY" --region nrt

原则：
  - 只在 stdout 输出**一行 JSON**，其它日志走 stderr，方便 agent 解析
  - 绝不打印私钥 / config.env
  - 失败时给出可执行的下一步（error + hint）
  - 非 0 退出码 = 失败，agent 应当停止并向人报告

退出码：0 成功 / 2 参数或环境问题 / 3 SSH 不通 / 4 安装失败 / 5 体检未通过
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = os.environ.get("VULTR_VPN_REPO", "zjr284/vultr-vpn")
DEFAULT_REF = os.environ.get("VULTR_VPN_REF", "main")
VULTR_API = "https://api.vultr.com/v2"


def log(msg):
    print("[agent] " + msg, file=sys.stderr, flush=True)


def die(code, error, hint=""):
    print(json.dumps({"ok": False, "error": error, "hint": hint}, ensure_ascii=False))
    sys.exit(code)


def run(cmd, timeout=120):
    p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


# --------------------------------------------------------------------- Vultr API
class Vultr:
    def __init__(self, key):
        self.key = key

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(VULTR_API + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.key)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            if e.code == 401:
                code, out, _ = run("curl -s --max-time 8 https://api.ipify.org")
                ip = out.strip() if code == 0 else "本机"
                die(2, "Vultr API 401（IP 白名单不放行）",
                    "把这台机器的出口 IP %s 加到 Vultr API Key 的允许列表，或换一个不限 IP 的 Key" % ip)
            die(2, "Vultr API %s %s -> %s %s" % (method, path, e.code, raw[:200]),
                "确认 Key 有 Instances / Firewall 读写权限")

    def egress_ip(self):
        code, out, _ = run("curl -s --max-time 8 https://api.ipify.org")
        return out.strip() if code == 0 else "unknown"


def find_or_create_firewall(v, instance_ip, fw_name):
    inst = None
    for i in v.call("GET", "/instances").get("instances", []):
        if i.get("main_ip") == instance_ip:
            inst = i
            break
    if not inst:
        return None, None
    fw = inst.get("firewall_group_id") or ""
    if not fw:
        fw = v.call("POST", "/firewalls", {"description": fw_name})["firewall_group"]["id"]
        v.call("PUT", "/instances/" + inst["id"], {"firewall_group_id": fw})
        log("新建防火墙组 %s 并挂载" % fw)
    have = {(r["protocol"], str(r["port"]))
            for r in v.call("GET", "/firewalls/%s/rules" % fw).get("firewall_rules", [])
            if r.get("subnet") == "0.0.0.0/0"}
    for proto, port in [("tcp", "22"), ("tcp", "80"), ("tcp", "443"), ("udp", "443"), ("udp", "51821")]:
        if (proto, port) in have:
            continue
        v.call("POST", "/firewalls/%s/rules" % fw,
               {"protocol": proto, "port": port, "subnet": "0.0.0.0/0", "ip_type": "v4", "notes": "agent"})
        log("放行 %s/%s" % (proto, port))
        time.sleep(1)
    return inst["id"], fw


def create_instance(v, args):
    pubkey = open(args.pubkey).read().strip() if args.pubkey else ""
    key_ids = []
    if pubkey:
        name = "agent-%d" % int(time.time())
        kid = v.call("POST", "/ssh-keys", {"name": name, "ssh_key": pubkey})["ssh_key"]["id"]
        key_ids.append(kid)
        log("上传公钥 %s" % kid)
    body = {
        "region": args.region,
        "plan": args.plan,
        "os_id": int(args.os_id),
        "label": args.label,
        "hostname": args.label[:63],
        "sshkey_ids": key_ids,
        "backups": "disabled",
        "enable_ipv6": True,
    }
    log("创建实例 region=%s plan=%s（按小时计费，失败会自动删除）" % (args.region, args.plan))
    inst = v.call("POST", "/instances", body)["instance"]
    iid, ip = inst["id"], inst.get("main_ip", "")
    for _ in range(60):
        time.sleep(5)
        cur = v.call("GET", "/instances/" + iid)["instance"]
        ip = cur.get("main_ip") or ip
        if cur.get("status") == "active" and ip:
            log("实例 active: %s" % ip)
            break
    else:
        v.call("DELETE", "/instances/" + iid)
        die(2, "实例 300 秒内没起来，已删除", "换 region 或 plan 重试")
    find_or_create_firewall(v, ip, args.label + "-fw")
    return iid, ip


# --------------------------------------------------------------------- SSH
def ssh(host, key, cmd, timeout=900, user="root"):
    base = ["ssh", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-i", key, "%s@%s" % (user, host)]
    return run(base + [cmd], timeout=timeout)


def wait_ssh(host, key, tries=40):
    for i in range(tries):
        code, _, _ = ssh(host, key, "echo ok", timeout=20)
        if code == 0:
            return True
        time.sleep(5)
    return False


def deploy(host, key, args):
    if not wait_ssh(host, key):
        die(3, "SSH 连不上 %s" % host,
            "检查：22 端口是否放行、root 登录是否被禁、密钥是否正确；校园网/公司网可能拦 22")

    log("SSH 已连通，开始安装（3–6 分钟）")
    flags = ["--json"]
    if args.domain:
        flags += ["--domain", args.domain]
    if args.reset:
        flags += ["--reset"]
    url = "https://raw.githubusercontent.com/%s/%s/install.sh" % (REPO, args.ref)
    cmd = "bash <(curl -fsSL %s) --ref %s %s" % (url, args.ref, " ".join(flags))
    code, out, err = ssh(host, key, cmd, timeout=1200)
    if code != 0:
        tail = "\n".join((out + err).strip().splitlines()[-12:])
        die(4, "安装脚本失败", tail)

    line = ""
    for ln in out.splitlines():
        if ln.startswith("VPN_JSON="):
            line = ln[len("VPN_JSON="):]
    if not line:
        die(4, "安装结束但没有拿到 VPN_JSON", "手动执行 bash /opt/vultr-vpn/setup.sh --json 看看")
    info = json.loads(line)

    log("安装完成，开始体检")
    ccode, cout, _ = ssh(host, key, "bash /opt/vultr-vpn/setup.sh --check", timeout=120)
    checks = [l for l in cout.splitlines() if l.strip() and not l.startswith("[")]
    info["check_ok"] = (ccode == 0)
    info["checks"] = checks
    if ccode != 0:
        info["ok"] = False
        info["error"] = "体检未通过"
        print(json.dumps(info, ensure_ascii=False))
        sys.exit(5)

    sub = info.get("subscription", "")
    log("验证订阅可达：%s" % sub)
    code, _, _ = ssh(host, key, "curl -fsS -o /dev/null -w '%%{http_code}' %s" % sub, timeout=60)
    info["subscription_ok"] = (code == 0)
    info["ok"] = True
    return info


def main():
    ap = argparse.ArgumentParser(description="无人值守部署 vultr-vpn")
    ap.add_argument("--host", help="已有服务器的 IP（SSH 模式）")
    ap.add_argument("--ssh-key", default=os.path.expanduser("~/.ssh/id_ed25519"))
    ap.add_argument("--domain", default="", help="自定义域名；不填则用 <IP>.sslip.io")
    ap.add_argument("--ref", default=DEFAULT_REF, help="版本 tag，默认 main")
    ap.add_argument("--reset", action="store_true", help="重新生成密钥")
    ap.add_argument("--json", action="store_true", help="（默认就输出 JSON，保留此参数兼容）")
    ap.add_argument("--dry-run", action="store_true")

    # Vultr 模式
    ap.add_argument("--vultr-key", default=os.environ.get("VULTR_API_KEY", ""))
    ap.add_argument("--pubkey", default=os.path.expanduser("~/.ssh/id_ed25519.pub"))
    ap.add_argument("--region", default="nrt", help="nrt 东京 / icn 首尔 / lax 洛杉矶")
    ap.add_argument("--plan", default="vc2-1c-1gb")
    ap.add_argument("--os-id", default="2284", help="2284 = Ubuntu 24.04 x64")
    ap.add_argument("--label", default="vpn-agent")
    ap.add_argument("--destroy-on-failure", action="store_true", default=True)
    ap.add_argument("--keep", action="store_true", help="失败也保留实例（默认删除）")
    args = ap.parse_args()
    args.destroy_on_failure = not args.keep

    if not args.host and not args.vultr_key:
        die(2, "要么给 --host（已有服务器），要么给 --vultr-key（新建）",
            "agent 应该先问人：你已经有服务器了吗？还是要我开一台（会产生费用）？")

    if args.dry_run:
        plan = {
            "mode": "ssh" if args.host else "vultr",
            "host": args.host or "(新建)",
            "ref": args.ref,
            "domain": args.domain or "(<IP>.sslip.io)",
            "steps": [
                "连通 SSH（重试 40 次，每次间隔 5s）",
                "执行 install.sh --ref %s --json" % args.ref,
                "解析 VPN_JSON",
                "setup.sh --check",
                "验证订阅 URL 可达",
                "输出 JSON",
            ],
        }
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return

    iid = None
    v = None
    host = args.host
    try:
        if not host:
            v = Vultr(args.vultr_key)
            log("出口 IP: %s" % v.egress_ip())
            iid, host = create_instance(v, args)
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001
        die(2, "创建实例失败: %s" % e, "确认 Vultr 余额、Key 权限、region 是否有货")

    try:
        info = deploy(host, args.ssh_key, args)
        info["instance_id"] = iid
        info["mode"] = "vultr" if iid else "ssh"
        print(json.dumps(info, ensure_ascii=False))
    except SystemExit:
        if iid and args.destroy_on_failure and v:
            log("失败，删除实例 %s 止损" % iid)
            try:
                v.call("DELETE", "/instances/" + iid)
            except Exception:  # noqa: BLE001
                pass
        raise


if __name__ == "__main__":
    main()
