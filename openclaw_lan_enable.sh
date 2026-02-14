cat > /root/openclaw_lan_enable.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

PORT="18789"
LAN_CIDR="192.168.31.0/24"   # 你的局域网段（按需改）
BIND="0.0.0.0"

echo "[1/6] 找到 openclaw 配置文件..."
CANDIDATES=(
  "/root/.openclaw/config.yaml"
  "/root/.openclaw/config.yml"
  "/etc/openclaw/config.yaml"
  "/etc/openclaw/config.yml"
)
CFG=""
for f in "${CANDIDATES[@]}"; do
  if [[ -f "$f" ]]; then CFG="$f"; break; fi
done

if [[ -z "$CFG" ]]; then
  echo "❌ 未找到配置文件。请确认 openclaw 配置路径（常见: /root/.openclaw/config.yaml 或 /etc/openclaw/config.yaml）"
  exit 1
fi
echo "✅ 使用配置文件: $CFG"

echo "[2/6] 备份配置文件..."
cp -a "$CFG" "${CFG}.bak.$(date +%Y%m%d%H%M%S)"
echo "✅ 备份完成"

echo "[3/6] 写入 gateway.bind=0.0.0.0，并确保 gateway.auth.token 存在..."
python3 - <<PY
import os, re, secrets

cfg = "${CFG}"
text = open(cfg, "r", encoding="utf-8").read()

def ensure_gateway_block(t: str) -> str:
    if re.search(r'(?m)^gateway:\s*$', t):
        return t
    # 没有 gateway: 就追加在末尾
    if not t.endswith("\n"):
        t += "\n"
    t += "\ngateway:\n"
    return t

text = ensure_gateway_block(text)

# 确保 gateway: 块内有 bind
# 简化做法：如果已有 gateway.bind 行则替换；否则在 gateway: 下一行插入
if re.search(r'(?m)^\s*bind:\s*', text) and re.search(r'(?m)^gateway:\s*$', text):
    # 只替换 gateway 块中的第一个 bind（尽量保守）
    lines = text.splitlines(True)
    out = []
    in_gateway = False
    replaced = False
    for line in lines:
        if re.match(r'(?m)^gateway:\s*$', line):
            in_gateway = True
            out.append(line)
            continue
        if in_gateway and re.match(r'^[A-Za-z0-9_.-]+:\s*$', line):  # 下一个顶层块
            in_gateway = False
        if in_gateway and (not replaced) and re.match(r'^\s*bind:\s*', line):
            out.append("  bind: ${BIND}\n")
            replaced = True
        else:
            out.append(line)
    text = "".join(out)
else:
    # 插入 bind
    text = re.sub(r'(?m)^gateway:\s*$', "gateway:\n  bind: ${BIND}", text, count=1)

# 确保 auth.token 存在
if re.search(r'(?m)^\s*auth:\s*$', text) and re.search(r'(?m)^\s*token:\s*', text):
    pass  # 已存在
elif re.search(r'(?m)^gateway:\s*$', text):
    # 在 gateway 块中查找 auth，没有则添加
    token = secrets.token_urlsafe(48)
    lines = text.splitlines(True)
    out = []
    in_gateway = False
    have_auth = False
    inserted = False
    for i, line in enumerate(lines):
        if re.match(r'(?m)^gateway:\s*$', line):
            in_gateway = True
            out.append(line)
            continue
        if in_gateway and re.match(r'^[A-Za-z0-9_.-]+:\s*$', line):  # 下一个顶层块
            if not inserted:
                out.append("  auth:\n    token: \"%s\"\n" % token)
                inserted = True
            in_gateway = False
        if in_gateway and re.match(r'^\s*auth:\s*$', line):
            have_auth = True
        out.append(line)

    if in_gateway and not inserted:
        out.append("  auth:\n    token: \"%s\"\n" % token)
        inserted = True

    text = "".join(out)

    if inserted:
        print("✅ 已生成并写入 gateway.auth.token")
    else:
        print("ℹ️ 未写入 token（可能已存在）")
else:
    # 极端情况：追加整个 gateway.auth
    token = secrets.token_urlsafe(48)
    if not text.endswith("\n"):
        text += "\n"
    text += "\ngateway:\n  bind: ${BIND}\n  auth:\n    token: \"%s\"\n" % token
    print("✅ 已追加 gateway 配置并写入 token")

open(cfg, "w", encoding="utf-8").write(text)
PY

echo "[4/6] 收紧 credentials 目录权限..."
if [[ -d /root/.openclaw/credentials ]]; then
  chmod 700 /root/.openclaw/credentials
  echo "✅ chmod 700 /root/.openclaw/credentials"
else
  echo "ℹ️ 未找到 /root/.openclaw/credentials，跳过"
fi

echo "[5/6] 配置防火墙（如启用 UFW，则只允许局域网访问 ${PORT}）..."
if command -v ufw >/dev/null 2>&1; then
  status=$(ufw status | head -n1 || true)
  if echo "$status" | grep -qi "active"; then
    ufw allow from "${LAN_CIDR}" to any port "${PORT}" proto tcp
    echo "✅ UFW 已放行 ${LAN_CIDR} -> ${PORT}/tcp"
  else
    echo "ℹ️ UFW 未启用，跳过（如你使用其他防火墙，请自行放行）"
  fi
else
  echo "ℹ️ 未安装 ufw，跳过"
fi

echo "[6/6] 重启 openclaw 服务并检查监听..."
if systemctl list-units --type=service | grep -qE '^openclaw(\.service)?\s'; then
  systemctl restart openclaw || true
fi
# 有些服务名可能是 openclaw-gateway / openclaw-gatewa(截断)，尝试重启匹配项
systemctl restart openclaw-gateway 2>/dev/null || true
systemctl restart openclaw-gatewa 2>/dev/null || true

sleep 1
echo "当前监听："
ss -tlnp | grep "${PORT}" || true

echo ""
echo "✅ 完成。现在在宿主机/局域网访问： http://192.168.31.57:${PORT}"
echo "如果还是访问不了：检查虚拟机网络模式/路由、防火墙（非 UFW）、以及是否有反向代理绑定。"
BASH

chmod +x /root/openclaw_lan_enable.sh
bash /root/openclaw_lan_enable.sh
