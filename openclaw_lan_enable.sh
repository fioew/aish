cat > openclaw_lan_enable.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-18789}"
LAN_CIDR="${LAN_CIDR:-192.168.31.0/24}"
UNIT="${UNIT:-openclaw-gateway.service}"
BIND="${BIND:-0.0.0.0}"

echo "[1/6] 检查 systemd 单元: ${UNIT}"
if ! systemctl status "${UNIT}" >/dev/null 2>&1; then
  echo "❌ 未找到 ${UNIT}，请用：systemctl list-units --type=service | grep -i openclaw"
  exit 1
fi

echo "[2/6] 写入 systemd override: OPENCLAW_GATEWAY_BIND=${BIND}"
mkdir -p "/etc/systemd/system/${UNIT}.d"
cat > "/etc/systemd/system/${UNIT}.d/override.conf" <<EOF
[Service]
Environment="OPENCLAW_GATEWAY_BIND=${BIND}"
EOF

echo "[3/6] 收紧 credentials 目录权限"
if [[ -d /root/.openclaw/credentials ]]; then
  chmod 700 /root/.openclaw/credentials
  echo "✅ chmod 700 /root/.openclaw/credentials"
else
  echo "ℹ️ 未找到 /root/.openclaw/credentials，跳过"
fi

echo "[4/6] UFW 防火墙：仅允许局域网访问 ${PORT}/tcp（若 UFW 启用）"
if command -v ufw >/dev/null 2>&1; then
  if ufw status | head -n1 | grep -qi "active"; then
    ufw allow from "${LAN_CIDR}" to any port "${PORT}" proto tcp
    echo "✅ 已放行 ${LAN_CIDR} -> ${PORT}/tcp"
  else
    echo "ℹ️ UFW 未启用，跳过"
  fi
else
  echo "ℹ️ 未安装 ufw，跳过"
fi

echo "[5/6] 重新加载并重启服务"
systemctl daemon-reload
systemctl restart "${UNIT}"

echo "[6/6] 验证监听端口"
ss -tlnp | grep "${PORT}" || true

echo ""
echo "✅ 完成：现在可在局域网访问 http://192.168.31.57:${PORT}"
echo "提示：你已存在 OPENCLAW_GATEWAY_TOKEN（鉴权 token），建议不要移除。"
BASH

chmod +x openclaw_lan_enable.sh
