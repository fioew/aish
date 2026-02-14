#!/usr/bin/env bash
set -euo pipefail

CONFIG="/root/.openclaw/openclaw.json"
SERVICE="openclaw-gateway"
PORT="18789"

echo "==== OpenClaw 局域网访问启用脚本 ===="

# 1️⃣ 检查配置文件
if [[ ! -f "$CONFIG" ]]; then
  echo "❌ 未找到 $CONFIG"
  exit 1
fi

echo "✅ 找到配置文件: $CONFIG"

# 2️⃣ 备份
cp -a "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
echo "✅ 已备份配置文件"

# 3️⃣ 修改 bind 为 lan
if grep -q '"bind"' "$CONFIG"; then
  sed -i 's/"bind"[[:space:]]*:[[:space:]]*"[^"]*"/"bind": "lan"/' "$CONFIG"
else
  # 如果没有 bind 字段，则在 gateway 下插入
  sed -i '/"gateway"[[:space:]]*:[[:space:]]*{/{n; s/.*/  "bind": "lan",\n&/}' "$CONFIG"
fi

echo "✅ 已设置 gateway.bind = lan"

# 4️⃣ 确保 credentials 权限安全
if [[ -d /root/.openclaw/credentials ]]; then
  chmod 700 /root/.openclaw/credentials
  echo "✅ credentials 权限已收紧"
fi

# 5️⃣ 重启服务
echo "🔄 重启 ${SERVICE}..."
systemctl restart ${SERVICE}

sleep 2

# 6️⃣ 验证监听状态
echo "📡 当前监听状态:"
ss -tlnp | grep ${PORT} || true

echo ""
echo "🎉 完成！"
echo "现在可以在局域网访问："
echo "http://$(hostname -I | awk '{print $1}'):${PORT}"
echo ""
echo "如果仍然是 127.0.0.1，请把 openclaw.json 内容发给我。"
