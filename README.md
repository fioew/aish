✅ 特点

自动获取 token：优先从正在运行的 openclaw-gateway 进程环境变量读取；读不到就自动生成并写入配置（不会在脚本里写死 token）。

自动修复你之前因为写入未知字段导致的崩溃：执行 openclaw doctor --fix。

写入你这个版本支持的永久方案：gateway.controlUi.allowInsecureAuth: true（从而避免 pairing required）。

固化：gateway.auth.token、gateway.controlUi.allowedOrigins、gateway.trustedProxies、gateway.bind=loopback。

配置 Caddy：openclaw.lan:8443 + tls internal + 反代到 127.0.0.1:18789，并禁用 HTTP/3（避免一些网络环境问题）。

收紧权限：chmod 700 /root/.openclaw/credentials。

自动重启 openclaw-gateway（user service）+ caddy（system service）。

脚本默认使用：域名 openclaw.lan、端口 8443、上游 127.0.0.1:18789。如需改端口/域名，改脚本顶部变量即可。
