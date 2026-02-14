✅ 从 GitHub 下载并运行（你要的“一键命令”）
方式 A：下载到本地再执行（推荐，便于审计）
rm -f openclaw_https_lan_fix.sh && \
curl -fsSL -H "Cache-Control: no-cache" \
"https://raw.githubusercontent.com/fioew/aish/main/openclaw_https_lan_fix.sh?ts=$(date +%s)" \
-o openclaw_https_lan_fix.sh && \
chmod +x openclaw_https_lan_fix.sh && \
sudo bash openclaw_https_lan_fix.sh
方式 B：直接 curl | bash（快速但不建议长期用）
curl -fsSL -H "Cache-Control: no-cache" \
"https://raw.githubusercontent.com/fioew/aish/main/openclaw_https_lan_fix.sh?ts=$(date +%s)" | sudo bash
⚠️ 你需要自己手动做的一件事

Windows 上要让 openclaw.lan 指向虚拟机 IP（你现在是 xxx.xxx.xxx.xxx），确保 hosts 有：

xxx.xxx.xxx.xxx openclaw.lan


同时 Clash Verge 的全局覆写里（你之前已经做过规则）建议保留：

.lan / LAN 直连

dns.hosts 里映射 openclaw.lan -> xxx.xxx.xxx.xxx（避免 Clash DNS 解析失败）
