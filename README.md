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
已测试：
- RT-BE58_Go
- 3006.102.8
- ARM
- Tailscale 1.102.4

  特别注意，如果华硕梅林固件路由器做二级路由时，dns一般为上级路由器分配的内网ip，DNS如为内网ip就不能走ts隧道查询，请把华硕路由器DNS手动指定为1.1.1.1和8.8.8.8。

安装最新版 main：
wget -qO /tmp/ts-manager.sh https://raw.githubusercontent.com/why95599/merlin-tailscale/main/ts-manager.sh && sh /tmp/ts-manager.sh

安装稳定版v1.0.0：
wget -qO /tmp/ts-manager.sh https://raw.githubusercontent.com/why95599/merlin-tailscale/v1.0.0/ts-manager.sh && sh /tmp/ts-manager.sh
