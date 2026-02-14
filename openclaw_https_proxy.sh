#!/usr/bin/env bash
set -euo pipefail

# ===== 可按需改 =====
OPENCLAW_CONFIG="/root/.openclaw/openclaw.json"
OPENCLAW_PORT="18789"          # openclaw gateway 本地端口（你当前就是这个）
HTTPS_PORT="8443"              # 对局域网提供 HTTPS 的端口（避免占用 443）
LAN_CIDR="192.168.31.0/24"     # 你的局域网网段
OPENCLAW_USER_UNIT="openclaw-gateway.service"
# ====================

echo "==== OpenClaw 方案A：Caddy 提供 HTTPS 反代（局域网访问）===="

if [[ $EUID -ne 0 ]]; then
  echo "❌ 请用 root 执行"
  exit 1
fi

echo "[1/8] 检查 OpenClaw 配置文件..."
if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
  echo "❌ 未找到 $OPENCLAW_CONFIG"
  exit 1
fi
echo "✅ 找到配置: $OPENCLAW_CONFIG"

echo "[2/8] 备份配置文件..."
cp -a "$OPENCLAW_CONFIG" "${OPENCLAW_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
echo "✅ 已备份"

echo "[3/8] 设置 OpenClaw 仅监听 localhost（更安全）并写入 trustedProxies..."
# 说明：openclaw.json 通常是 JSON5 风格，但这里用最保守的文本替换方式
# 目标：
# - gateway.bind = "loopback"   （避免直接 LAN 暴露 openclaw）
# - gateway.trustedProxies 包含 127.0.0.1 / ::1（反代场景）
# 如果你更想保持 gateway.bind="lan"，可以把 loopback 改成 lan。
python3 - <<PY
import re, json, sys, pathlib

p = pathlib.Path("${OPENCLAW_CONFIG}")
txt = p.read_text(encoding="utf-8")

# 尝试用正则做“最小侵入”替换（不强依赖严格 JSON）
def set_or_replace_field(obj_txt, key, value_txt):
    # 替换已有 "key": ...
    pat = re.compile(r'("'+re.escape(key)+r'"\s*:\s*)([^,\n}]+)', re.M)
    if pat.search(obj_txt):
        return pat.sub(r'\1'+value_txt, obj_txt, count=1), True
    return obj_txt, False

# 确保有 "gateway": { ... }
if not re.search(r'"gateway"\s*:\s*{', txt):
    # 没有 gateway 块就粗暴追加一个（极少发生）
    if not txt.endswith("\n"): txt += "\n"
    txt += '\n"gateway": {\n  "bind": "loopback",\n  "trustedProxies": ["127.0.0.1","::1"]\n}\n'
    p.write_text(txt, encoding="utf-8")
    print("✅ 追加 gateway 块")
    sys.exit(0)

# 在 gateway 块内设置 bind/trustedProxies（尽量不破坏其他字段）
# 简单做法：先全局替换 bind，再处理 trustedProxies；如果不存在则插入到 gateway { 后
txt, changed_bind = set_or_replace_field(txt, "bind", '"loopback"')

if not re.search(r'"trustedProxies"\s*:', txt):
    # 在 "gateway": { 之后插入 trustedProxies 一行
    txt = re.sub(r'("gateway"\s*:\s*{)', r'\1\n  "trustedProxies": ["127.0.0.1","::1"],', txt, count=1)
else:
    # 替换 trustedProxies 值
    txt = re.sub(r'("trustedProxies"\s*:\s*)\[[^\]]*\]', r'\1["127.0.0.1","::1"]', txt, count=1)

p.write_text(txt, encoding="utf-8")
print("✅ 已设置 gateway.bind=loopback，并写入 gateway.trustedProxies")
PY

echo "[4/8] 收紧 credentials 目录权限..."
if [[ -d /root/.openclaw/credentials ]]; then
  chmod 700 /root/.openclaw/credentials
  echo "✅ chmod 700 /root/.openclaw/credentials"
else
  echo "ℹ️ 未找到 /root/.openclaw/credentials，跳过"
fi

echo "[5/8] 安装并配置 Caddy..."
apt-get update -y
apt-get install -y caddy

# 写入 Caddyfile：对外 :8443 提供 HTTPS，自签证书；转发到 127.0.0.1:18789
cat >/etc/caddy/Caddyfile <<EOF
:${HTTPS_PORT} {
  tls internal
  encode gzip
  reverse_proxy 127.0.0.1:${OPENCLAW_PORT}
}
EOF

systemctl enable --now caddy
systemctl restart caddy
systemctl --no-pager --full status caddy | sed -n '1,12p' || true

echo "[6/8] 重启 OpenClaw（root 的 user service）..."
# 有些环境需要 XDG_RUNTIME_DIR 才能操作 root 的 --user unit
export XDG_RUNTIME_DIR=/run/user/0
systemctl --user restart "${OPENCLAW_USER_UNIT}"

echo "[7/8] 放行防火墙（如启用 UFW，仅允许局域网访问 HTTPS 端口）..."
if command -v ufw >/dev/null 2>&1; then
  if ufw status | head -n1 | grep -qi "active"; then
    ufw allow from "${LAN_CIDR}" to any port "${HTTPS_PORT}" proto tcp
    echo "✅ UFW 已放行 ${LAN_CIDR} -> ${HTTPS_PORT}/tcp"
  else
    echo "ℹ️ UFW 未启用，跳过"
  fi
else
  echo "ℹ️ 未安装 ufw，跳过"
fi

echo "[8/8] 验证监听..."
echo "OpenClaw(本地) 监听："
ss -tlnp | grep "${OPENCLAW_PORT}" || true
echo "Caddy(HTTPS) 监听："
ss -tlnp | grep "${HTTPS_PORT}" || true

IP="$(hostname -I | awk '{print $1}')"
echo ""
echo "🎉 完成！请在局域网设备访问："
echo "  https://${IP}:${HTTPS_PORT}"
echo ""
echo "提示：第一次访问会提示证书不受信任（Caddy internal CA），选择继续/信任即可。"
