Asuswrt-Merlin Tailscale Manager

功能：
- 无需 USB / Entware
- 适配 Tiny-JFFS
- Tailscale 二进制运行于 /tmp
- 登录状态保存于 /jffs
- 支持整个 LAN/Wi-Fi 选择一个 Tailscale Exit Node
- 支持恢复普通 WAN

已测试：
- ASUS RT-AX86U
- Asuswrt-Merlin 3004.388.11
- ARM64
- Tailscale 1.102.4

安装：
wget -qO /tmp/ts-manager.sh https://raw.githubusercontent.com/why95599/merlin-tailscale/main/ts-manager.sh && sh /tmp/ts-manager.sh
