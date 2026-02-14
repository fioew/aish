#!/usr/bin/env bash
set -euo pipefail

# ====== 可按需修改的参数 ======
DOMAIN="${DOMAIN:-openclaw.lan}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
UPSTREAM_HOST="${UPSTREAM_HOST:-127.0.0.1}"
UPSTREAM_PORT="${UPSTREAM_PORT:-18789}"
ORIGIN="https://${DOMAIN}:${HTTPS_PORT}"
CONF="/root/.openclaw/openclaw.json"
CADDYFILE="/etc/caddy/Caddyfile"
# ==============================

log() { echo -e "\n==> $*"; }
warn() { echo -e "\n[WARN] $*" >&2; }
die() { echo -e "\n[ERR] $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo -i 或 sudo bash $0"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_services_exist() {
  have_cmd openclaw || die "未找到 openclaw 命令，请先安装 OpenClaw"
  have_cmd python3 || die "未找到 python3，请先安装：apt-get update && apt-get install -y python3"
  have_cmd systemctl || die "未找到 systemctl（不是 systemd 环境？）"
  systemctl status caddy >/dev/null 2>&1 || warn "检测到 caddy.service 不存在/不可用（若你没装 Caddy，需要先安装）"
}

user_systemctl() {
  # root 下使用 --user 必须指定 XDG_RUNTIME_DIR
  XDG_RUNTIME_DIR=/run/user/0 systemctl --user "$@"
}

get_token_from_running_gateway() {
  local pid token
  pid="$(pgrep -f openclaw-gateway | head -n1 || true)"
  if [ -n "${pid:-}" ] && [ -r "/proc/$pid/environ" ]; then
    token="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' | head -n1 || true)"
    [ -n "${token:-}" ] && { echo "$token"; return 0; }
  fi
  return 1
}

gen_token() {
  if have_cmd openssl; then
    openssl rand -hex 32
  else
    # fallback: 64 hex chars
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

ensure_gateway_running_for_token() {
  # 尝试启动/重启一次，便于从进程环境拿到 token（如果 OpenClaw 会自动生成）
  user_systemctl restart openclaw-gateway.service >/dev/null 2>&1 || true
  sleep 0.5
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local bak="${f}.bak.$(date +%s)"
  cp -a "$f" "$bak"
  echo "$bak"
}

write_openclaw_config() {
  local token="$1"

  [ -f "$CONF" ] || die "找不到配置文件：$CONF"

  local bak
  bak="$(backup_file "$CONF" || true)"
  [ -n "${bak:-}" ] && log "已备份 openclaw.json：$bak"

  # 先 doctor fix，去掉未知键（避免你之前那种崩溃）
  log "运行 openclaw doctor --fix（移除不支持的配置键）"
  openclaw doctor --fix || true

  log "写入/更新 openclaw.json：auth.token + allowedOrigins + allowInsecureAuth + trustedProxies + bind=loopback"
  python3 - <<PY
import json, pathlib

p = pathlib.Path("$CONF")
data = json.loads(p.read_text(encoding="utf-8"))

gw = data.setdefault("gateway", {})

# 1) 建议通过 Caddy 反代对外，所以网关只监听 loopback 更安全
gw["bind"] = "loopback"

# 2) 固化 token 认证（Control UI 会用这个 token）
auth = gw.setdefault("auth", {})
auth["token"] = "$token"

# 3) 允许从 HTTPS 域名访问；并启用 allowInsecureAuth 以禁用设备身份/配对（永久解决 pairing required）
cu = gw.setdefault("controlUi", {})
cu["allowedOrigins"] = ["$ORIGIN"]
cu["allowInsecureAuth"] = True

# 4) 可信代理（你是本机 Caddy 反代）
tp = gw.setdefault("trustedProxies", [])
for ip in ["127.0.0.1", "::1"]:
    if ip not in tp:
        tp.append(ip)

p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")
print("OK updated", p)
PY
}

write_caddyfile() {
  # Caddyfile：禁用 h3/QUIC，使用 h1/h2；TLS internal；反代到 127.0.0.1:18789
  log "写入 Caddyfile：${CADDYFILE}"
  cat >"$CADDYFILE" <<EOF
{
  servers {
    protocols h1 h2
  }
}

${DOMAIN}:${HTTPS_PORT} {
  tls internal

  reverse_proxy ${UPSTREAM_HOST}:${UPSTREAM_PORT} {
    header_up Host {host}
    header_up X-Real-IP {remote}
    header_up X-Forwarded-For {remote}
    header_up X-Forwarded-Proto https
  }
}
EOF
}

restart_services() {
  log "重启 openclaw-gateway（user service）"
  user_systemctl daemon-reload || true
  user_systemctl restart openclaw-gateway.service

  log "等待网关端口监听：${UPSTREAM_PORT}"
  for i in {1..40}; do
    ss -tln 2>/dev/null | grep -q ":${UPSTREAM_PORT} " && break
    sleep 0.2
  done

  log "重启 caddy（system service）"
  systemctl restart caddy || die "caddy 重启失败，请运行：systemctl status caddy && journalctl -u caddy -n 50 --no-pager"
}

tighten_perms() {
  if [ -d /root/.openclaw/credentials ]; then
    log "收紧凭据目录权限：chmod 700 /root/.openclaw/credentials"
    chmod 700 /root/.openclaw/credentials || true
  fi
}

self_check() {
  log "自检：本机 HTTPS 访问（忽略自签 CA 校验）"
  if have_cmd curl; then
    curl -kfsS "https://127.0.0.1:${HTTPS_PORT}/" >/dev/null && echo "✅ local https ok" || warn "本机 https 访问失败（可能是 caddy 未启动）"
  else
    warn "未安装 curl，跳过自检"
  fi

  log "监听端口："
  ss -tlnp | egrep "(:${HTTPS_PORT}|:${UPSTREAM_PORT})" || true

  echo
  echo "✅ 完成"
  echo "访问地址：${ORIGIN}/"
  echo "在 Control UI 里填 token 并点 Connect（token 已写入 openclaw.json 的 gateway.auth.token）"
}

main() {
  require_root
  ensure_services_exist

  log "获取/生成 Gateway Token（不会写死在脚本中）"
  local token=""
  if token="$(get_token_from_running_gateway 2>/dev/null)"; then
    echo "✅ 从正在运行的 openclaw-gateway 获取到 token"
  else
    ensure_gateway_running_for_token
    if token="$(get_token_from_running_gateway 2>/dev/null)"; then
      echo "✅ 重启后从 openclaw-gateway 获取到 token"
    else
      token="$(gen_token)"
      echo "✅ 未能从进程环境读取 token，已自动生成新 token"
    fi
  fi

  write_openclaw_config "$token"
  tighten_perms
  write_caddyfile
  restart_services
  self_check
}

main "$@"
