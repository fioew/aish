#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-18789}"
LAN_CIDR="${LAN_CIDR:-192.168.31.0/24}"
UNIT="openclaw-gateway.service"
BIND="0.0.0.0"

echo "[1/5] 检查 systemd 单元: ${UNIT}"
if ! systemctl status "${UNIT}" >/dev/null 2>&1; then
  echo "❌ 未找到 ${UNIT}"
  exit 1
fi

echo "[2/5] 写入 systemd override"
mkdir -p "/etc/systemd/system/${UNIT}.d"
cat > "/etc/systemd/system/${UNIT}.d/override.conf" <<EOF
[Service]
Environment="OPENCLAW_GATEWAY_BIND=${BIND}"
EOF

echo "[3/5] 重载并重启服务"
systemctl daemon-reload
systemctl restart "${UNIT}"

echo "[4/5] 放行局域网端口（如启用 UFW）"
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -qi active; then
    ufw allow from "${LAN_CIDR}" to any port "${PORT}" proto tcp
  fi
fi

echo "[5/5] 验证监听状态"
ss -tlnp | grep "${PORT}" || true

echo ""
echo "✅ 现在可访问: http://192.168.31.57:${PORT}"
