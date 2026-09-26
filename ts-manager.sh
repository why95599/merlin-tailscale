#!/bin/sh
#
# ts-manager.sh - Tailscale Manager for Asuswrt-Merlin (Tiny-JFFS friendly)
# Version: 1.0.0
#
# Target:
#   - Asuswrt-Merlin routers such as RT-AX86U
#   - Works without USB / Entware
#   - Persistent data in /jffs; large binaries in /tmp
#   - Whole primary LAN/Wi-Fi can use ONE remote Tailscale Exit Node
#   - Router can advertise itself as a Tailscale Exit Node
#
# Tested core path:
#   RT-AX86U / Asuswrt-Merlin 3004.388.11 / aarch64 / Tailscale 1.102.4
#   LAN 192.168.50.0/24 -> MASQUERADE -> tailscale0 -> remote Exit Node
#
# Notes:
#   - This V1 targets the primary LAN bridge (usually br0), not guest VLANs.
#   - Advertising an Exit Node needs approval in the Tailscale admin console.
#   - IPv6 forwarding from the primary LAN is blocked while Exit Mode is ON.
#   - This is NOT a kill-switch: if tailscaled dies, IPv4 may fall back to WAN.
#   - Designed for a standalone Tailscale gateway; coexistence with other transparent-proxy stacks is out of scope.
#

SCRIPT_VERSION="1.0.0"

BASE="/jffs/tailscale"
CONF="$BASE/manager.conf"
SELF="$BASE/ts-manager.sh"
STATE="$BASE/tailscaled.state"

RUNTIME="/tmp/tailscale-bin"
RUNTIME_NEW="/tmp/tailscale-bin.new"
RUNTIME_OLD="/tmp/tailscale-bin.old"
STAGE="/tmp/ts-manager-stage"
PKG="/tmp/ts-manager.tgz"

TS="$RUNTIME/tailscale"
TSD="$RUNTIME/tailscaled"
LOG="/tmp/tailscaled.log"

OFFICIAL_BASE="https://pkgs.tailscale.com/stable"
LOCKDIR="/tmp/ts-manager.lock"

VERSION=""
MIRROR_BASE=""
EXIT_NODE=""
BLOCK_IPV6="1"
ADVERTISE_EXIT="0"

say() { echo "[TSM] $*"; }
warn() { echo "[TSM][WARN] $*" >&2; }
err() { echo "[TSM][ERROR] $*" >&2; }
syslog() { logger -t ts-manager "$*" 2>/dev/null; }

need_root() {
    # Asuswrt-Merlin is a highly stripped-down embedded Linux environment.
    # Some builds do not provide `id` / `whoami` even for the router
    # administrator account.  Check the capabilities we actually need
    # instead of requiring `id -u = 0`.
    if [ ! -w /jffs ]; then
        err "当前 SSH 会话没有 /jffs 写权限，请使用路由器管理员账号登录。"
        exit 1
    fi

    if ! iptables -L >/dev/null 2>&1; then
        err "当前 SSH 会话不能读取/管理 iptables，请使用路由器管理员账号登录。"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7*|armhf) ARCH="arm" ;;
        x86_64|amd64) ARCH="amd64" ;;
        i386|i486|i586|i686) ARCH="386" ;;
        *)
            err "暂不支持的 CPU 架构: $(uname -m)"
            return 1
            ;;
    esac
    return 0
}

init_base() {
    mkdir -p "$BASE" || return 1
    chmod 700 "$BASE" 2>/dev/null

    if [ ! -f "$CONF" ]; then
        cat >"$CONF" <<'EOF'
VERSION=''
MIRROR_BASE=''
EXIT_NODE=''
BLOCK_IPV6='1'
ADVERTISE_EXIT='0'
EOF
        chmod 600 "$CONF"
    fi
    load_config
}

load_config() {
    VERSION=""
    MIRROR_BASE=""
    EXIT_NODE=""
    BLOCK_IPV6="1"
    ADVERTISE_EXIT="0"
    [ -f "$CONF" ] && . "$CONF"
}

save_config() {
    cat >"$CONF" <<EOF
VERSION='$VERSION'
MIRROR_BASE='$MIRROR_BASE'
EXIT_NODE='$EXIT_NODE'
BLOCK_IPV6='$BLOCK_IPV6'
ADVERTISE_EXIT='$ADVERTISE_EXIT'
EOF
    chmod 600 "$CONF"
}

install_self() {
    case "$0" in
        "$SELF") return 0 ;;
    esac
    if [ -f "$0" ]; then
        cp "$0" "$SELF" 2>/dev/null && chmod 755 "$SELF"
    fi
}

ensure_hook_line() {
    _file="$1"
    _marker="$2"
    _cmd="$3"

    mkdir -p /jffs/scripts
    if [ ! -f "$_file" ]; then
        echo '#!/bin/sh' >"$_file"
    fi
    if ! grep -F "$_marker" "$_file" >/dev/null 2>&1; then
        {
            echo ""
            echo "$_marker"
            echo "$_cmd"
        } >>"$_file"
    fi
    chmod 755 "$_file"
}

install_hooks() {
    install_self

    ensure_hook_line \
        "/jffs/scripts/services-start" \
        "# ts-manager: boot" \
        "$SELF boot >/tmp/ts-manager-boot.log 2>&1 &"

    ensure_hook_line \
        "/jffs/scripts/wan-start" \
        "# ts-manager: wan retry" \
        "$SELF boot >/tmp/ts-manager-wan.log 2>&1 &"

    ensure_hook_line \
        "/jffs/scripts/nat-start" \
        "# ts-manager: restore NAT" \
        "$SELF nat-restore >/dev/null 2>&1 &"

    ensure_hook_line \
        "/jffs/scripts/firewall-start" \
        "# ts-manager: restore firewall" \
        "$SELF firewall-restore >/dev/null 2>&1 &"

    say "Merlin 开机/NAT/防火墙钩子已安装或确认存在。"
}

load_tun() {
    if [ ! -c /dev/net/tun ]; then
        modprobe tun >/dev/null 2>&1
    fi
    if [ ! -c /dev/net/tun ]; then
        err "/dev/net/tun 不存在，且 modprobe tun 未能创建它。"
        return 1
    fi
    return 0
}

get_lan_if() {
    LAN_IF="$(nvram get lan_ifname 2>/dev/null)"
    [ -n "$LAN_IF" ] || LAN_IF="br0"
}

get_lan_cidr() {
    get_lan_if
    LAN_CIDR="$(ip -4 route show dev "$LAN_IF" 2>/dev/null | \
        awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print $1; exit}')"

    if [ -z "$LAN_CIDR" ]; then
        err "无法自动识别 $LAN_IF 的 IPv4 LAN 网段。"
        return 1
    fi
    return 0
}

valid_version() {
    _v="$1"
    [ -n "$_v" ] || return 1
    case "$_v" in
        *[!0-9.]*|.*|*..*|*.) return 1 ;;
    esac
    return 0
}

fetch_text() {
    _url="$1"
    wget -qO- "$_url" 2>/dev/null
}

discover_latest_version() {
    _v=""

    if [ -n "$MIRROR_BASE" ]; then
        _base="${MIRROR_BASE%/}"
        _v="$(fetch_text "$_base/version.txt" | tr -d '\r\n ' | head -c 64)"
        if valid_version "$_v"; then
            echo "$_v"
            return 0
        fi
    fi

    _page="$(fetch_text "$OFFICIAL_BASE/")"
    _v="$(echo "$_page" | \
        sed -n "s/.*tailscale_\([0-9][0-9.]*\)_${ARCH}\.tgz.*/\1/p" | \
        head -n 1)"

    if valid_version "$_v"; then
        echo "$_v"
        return 0
    fi

    return 1
}


download_package() {
    _ver="$1"
    _pkg="tailscale_${_ver}_${ARCH}.tgz"
    rm -f "$PKG"

    if [ -n "$MIRROR_BASE" ]; then
        _base="${MIRROR_BASE%/}"
        say "尝试 VPS 镜像: $_base/$_pkg"
        if wget -q -O "$PKG" "$_base/$_pkg" 2>/dev/null; then
            [ -s "$PKG" ] && return 0
        fi
        rm -f "$PKG"
        warn "VPS 镜像下载失败，转官方源。"
    fi

    say "尝试 Tailscale 官方源: $OFFICIAL_BASE/$_pkg"
    if wget -q -O "$PKG" "$OFFICIAL_BASE/$_pkg" 2>/dev/null; then
        [ -s "$PKG" ] && return 0
    fi

    rm -f "$PKG"
    return 1
}



stage_version() {
    _ver="$1"

    download_package "$_ver" || {
        err "下载 Tailscale $_ver 失败。"
        return 1
    }

    rm -rf "$STAGE" "$RUNTIME_NEW"
    mkdir -p "$STAGE" || return 1

    if ! tar xzf "$PKG" -C "$STAGE"; then
        err "解压失败。"
        rm -rf "$STAGE" "$PKG"
        return 1
    fi
    rm -f "$PKG"

    _found=""
    for _d in "$STAGE"/tailscale_*; do
        if [ -x "$_d/tailscale" ] && [ -x "$_d/tailscaled" ]; then
            _found="$_d"
            break
        fi
    done

    if [ -z "$_found" ]; then
        err "安装包中未找到 tailscale/tailscaled。"
        rm -rf "$STAGE"
        return 1
    fi

    NEW_VERSION="$("$_found/tailscale" version 2>/dev/null | sed -n '1p' | tr -d '\r ')"
    if [ -z "$NEW_VERSION" ]; then
        err "新 tailscale 二进制无法运行。"
        rm -rf "$STAGE"
        return 1
    fi

    if [ "$NEW_VERSION" != "$_ver" ]; then
        err "版本不匹配: 请求 $_ver，实际 $NEW_VERSION"
        rm -rf "$STAGE"
        return 1
    fi

    mv "$_found" "$RUNTIME_NEW" || {
        rm -rf "$STAGE"
        return 1
    }
    rm -rf "$STAGE"

    say "下载包已成功解压，二进制版本验证为 $NEW_VERSION。"
    return 0
}

stop_daemon() {
    if pidof tailscaled >/dev/null 2>&1; then
        killall tailscaled >/dev/null 2>&1
        _n=0
        while pidof tailscaled >/dev/null 2>&1 && [ "$_n" -lt 10 ]; do
            sleep 1
            _n=$((_n + 1))
        done
    fi
}

start_daemon() {
    load_tun || return 1

    if pidof tailscaled >/dev/null 2>&1; then
        return 0
    fi

    if [ ! -x "$TSD" ]; then
        err "运行目录不存在 tailscaled: $TSD"
        return 1
    fi

    nohup "$TSD" --state="$STATE" >"$LOG" 2>&1 </dev/null &
    sleep 2

    if ! pidof tailscaled >/dev/null 2>&1; then
        err "tailscaled 启动失败。最近日志："
        tail -n 30 "$LOG" 2>/dev/null
        return 1
    fi
    return 0
}

activate_staged() {
    stop_daemon

    rm -rf "$RUNTIME_OLD"
    if [ -d "$RUNTIME" ]; then
        mv "$RUNTIME" "$RUNTIME_OLD"
    fi

    if ! mv "$RUNTIME_NEW" "$RUNTIME"; then
        err "切换新版本失败。"
        [ -d "$RUNTIME_OLD" ] && mv "$RUNTIME_OLD" "$RUNTIME"
        return 1
    fi

    TS="$RUNTIME/tailscale"
    TSD="$RUNTIME/tailscaled"

    if start_daemon; then
        rm -rf "$RUNTIME_OLD"
        return 0
    fi

    warn "新版本启动失败，尝试用 /tmp 中的旧运行版本回滚。"
    stop_daemon
    rm -rf "$RUNTIME"
    if [ -d "$RUNTIME_OLD" ]; then
        mv "$RUNTIME_OLD" "$RUNTIME"
        TS="$RUNTIME/tailscale"
        TSD="$RUNTIME/tailscaled"
        start_daemon
    fi
    return 1
}

ensure_runtime_once() {
    if [ -x "$TS" ] && [ -x "$TSD" ]; then
        return 0
    fi

    if [ -z "$VERSION" ]; then
        _ver="$(discover_latest_version)" || return 1
    else
        _ver="$VERSION"
    fi

    stage_version "$_ver" || return 1

    rm -rf "$RUNTIME"
    mv "$RUNTIME_NEW" "$RUNTIME" || return 1
    TS="$RUNTIME/tailscale"
    TSD="$RUNTIME/tailscaled"

    if [ -z "$VERSION" ]; then
        VERSION="$NEW_VERSION"
        save_config
    fi
    return 0
}

ensure_runtime_retry() {
    _try=1
    while [ "$_try" -le 8 ]; do
        if ensure_runtime_once; then
            return 0
        fi
        warn "获取运行文件失败（第 $_try/8 次），15 秒后重试。"
        sleep 15
        _try=$((_try + 1))
    done
    return 1
}

tailscale_ready() {
    [ -x "$TS" ] || return 1
    pidof tailscaled >/dev/null 2>&1 || return 1
    "$TS" status >/dev/null 2>&1
}

apply_nat() {
    get_lan_cidr || return 1

    while iptables -t nat -D POSTROUTING \
        -s "$LAN_CIDR" -o tailscale0 -j MASQUERADE \
        >/dev/null 2>&1
    do
        :
    done

    if [ -n "$EXIT_NODE" ] && ip link show tailscale0 >/dev/null 2>&1; then
        iptables -t nat -I POSTROUTING 1 \
            -s "$LAN_CIDR" -o tailscale0 -j MASQUERADE
    fi
}

remove_nat() {
    get_lan_cidr || return 0
    while iptables -t nat -D POSTROUTING \
        -s "$LAN_CIDR" -o tailscale0 -j MASQUERADE \
        >/dev/null 2>&1
    do
        :
    done
}

apply_ipv6_block() {
    get_lan_if

    while ip6tables -D FORWARD -i "$LAN_IF" -j REJECT \
        >/dev/null 2>&1
    do
        :
    done

    if [ "$BLOCK_IPV6" = "1" ] && [ -n "$EXIT_NODE" ]; then
        ip6tables -I FORWARD 1 -i "$LAN_IF" -j REJECT 2>/dev/null
    fi
}

remove_ipv6_block() {
    get_lan_if
    while ip6tables -D FORWARD -i "$LAN_IF" -j REJECT \
        >/dev/null 2>&1
    do
        :
    done
}

detect_current_exit() {
    [ -x "$TS" ] || return 0
    _current="$("$TS" status 2>/dev/null | \
        awk '/active; exit node/ {print $1; exit}')"
    if [ -n "$_current" ] && [ -z "$EXIT_NODE" ]; then
        EXIT_NODE="$_current"
        save_config
    fi
}

restore_exit() {
    load_config

    if [ -z "$EXIT_NODE" ]; then
        remove_nat
        remove_ipv6_block
        return 0
    fi

    tailscale_ready || return 1

    # Block LAN IPv6 before enabling Exit Mode.
    apply_ipv6_block

    if ! "$TS" set \
        --exit-node="$EXIT_NODE" \
        --exit-node-allow-lan-access=true
    then
        err "恢复 Exit Node $EXIT_NODE 失败。"
        return 1
    fi

    apply_nat
    return 0
}

ensure_exit_forwarding() {
    if ! echo 1 >/proc/sys/net/ipv4/ip_forward; then
        err "无法启用 IPv4 转发。"
        return 1
    fi
    if [ -e /proc/sys/net/ipv6/conf/all/forwarding ]; then
        if ! echo 1 >/proc/sys/net/ipv6/conf/all/forwarding; then
            err "无法启用 IPv6 转发。"
            return 1
        fi
    else
        warn "系统未提供 IPv6 转发开关；请在其他设备上检查 IPv6 出口。"
    fi
}

restore_advertisement() {
    load_config
    tailscale_ready || return 1

    if [ "$ADVERTISE_EXIT" = "1" ]; then
        ensure_exit_forwarding || return 1
        "$TS" set --advertise-exit-node=true
    else
        # State may have retained a previous advertisement across reinstall.
        "$TS" set --advertise-exit-node=false
    fi
}

enable_exit_advertisement() {
    init_base
    tailscale_ready || {
        err "请先安装并登录 Tailscale。"
        return 1
    }
    detect_current_exit
    if [ -n "$EXIT_NODE" ]; then
        err "本路由器正在使用远程 Exit Node，请先在菜单中取消该模式。"
        return 1
    fi
    ensure_exit_forwarding || return 1
    "$TS" set --advertise-exit-node=true || return 1
    ADVERTISE_EXIT="1"
    save_config
    say "路由器已申请提供 Exit Node；请到 Tailscale 管理后台批准出口路由。"
}

disable_exit_advertisement() {
    init_base
    if ! tailscale_ready; then
        err "Tailscale 未运行或未登录，无法确认关闭。请启动后重试。"
        return 1
    fi
    "$TS" set --advertise-exit-node=false || return 1
    ADVERTISE_EXIT="0"
    save_config
    say "路由器已停止提供 Exit Node。"
}

repair_tailscale_rules_if_needed() {
    pidof tailscaled >/dev/null 2>&1 || return 0

    if ! iptables -S ts-forward >/dev/null 2>&1 || \
       ! iptables -t nat -S ts-postrouting >/dev/null 2>&1
    then
        warn "检测到 Tailscale iptables 链缺失，重启 tailscaled 以重建规则。"
        stop_daemon
        start_daemon || return 1
        sleep 2
    fi
    return 0
}

boot_main() {
    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        exit 0
    fi
    trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

    init_base
    detect_arch || exit 1
    load_tun || exit 1

    if ! ensure_runtime_retry; then
        err "启动失败：无法取得 Tailscale 运行文件。"
        syslog "boot failed: cannot obtain runtime binaries"
        exit 1
    fi

    start_daemon || exit 1

    _n=0
    while [ "$_n" -lt 20 ]; do
        if "$TS" status >/dev/null 2>&1; then
            break
        fi
        sleep 2
        _n=$((_n + 1))
    done

    detect_current_exit
    restore_exit >/dev/null 2>&1
    restore_advertisement >/dev/null 2>&1 || syslog "boot: exit-node advertisement restore failed"

    syslog "boot complete version=$VERSION exit=${EXIT_NODE:-off} advertise=$ADVERTISE_EXIT"
    exit 0
}

nat_restore_main() {
    init_base
    load_config
    [ "$ADVERTISE_EXIT" = "1" ] && ensure_exit_forwarding >/dev/null 2>&1
    [ -n "$EXIT_NODE" ] || exit 0
    repair_tailscale_rules_if_needed
    apply_nat >/dev/null 2>&1
}

firewall_restore_main() {
    init_base
    load_config
    [ "$ADVERTISE_EXIT" = "1" ] && ensure_exit_forwarding >/dev/null 2>&1
    [ -n "$EXIT_NODE" ] || exit 0
    repair_tailscale_rules_if_needed
    apply_ipv6_block >/dev/null 2>&1
}

upgrade_latest() {
    init_base
    detect_arch || return 1
    install_hooks
    load_tun || return 1

    _latest="$(discover_latest_version)"
    if [ -z "$_latest" ]; then
        err "无法查询最新 stable 版本。"
        return 1
    fi

    say "当前记录版本: ${VERSION:-未安装}"
    say "最新 stable:   $_latest"

    if [ "$VERSION" = "$_latest" ] && [ -x "$TS" ] && [ -x "$TSD" ]; then
        say "当前运行文件已经是最新版本。"
        start_daemon
        detect_current_exit
        restore_advertisement >/dev/null 2>&1
        return 0
    fi

    say "下载并验证 Tailscale $_latest ..."
    stage_version "$_latest" || return 1

    if ! activate_staged; then
        err "升级/安装未成功。"
        return 1
    fi

    VERSION="$NEW_VERSION"
    save_config

    # Give an already-authenticated state a moment to reconnect.
    sleep 3
    detect_current_exit
    restore_exit >/dev/null 2>&1
    restore_advertisement >/dev/null 2>&1

    say "Tailscale 已安装/升级到 $VERSION。"
    if "$TS" status >/dev/null 2>&1; then
        "$TS" status
    else
        say "当前尚未完成登录，请选择菜单中的“首次登录/重新连接”。"
    fi
}

login_interactive() {
    init_base
    detect_arch || return 1
    install_hooks
    load_tun || return 1

    if ! ensure_runtime_retry; then
        err "没有可运行的 Tailscale。"
        return 1
    fi
    start_daemon || return 1

    echo ""
    say "如果出现认证 URL，请在浏览器完成登录。"
    say "认证完成前不要按 Ctrl+C；等待命令自行返回。"
    echo ""

    "$TS" up
    _rc=$?

    if [ "$_rc" -eq 0 ]; then
        detect_current_exit
        restore_advertisement >/dev/null 2>&1
        say "Tailscale 登录/连接完成。"
        "$TS" status
    fi
    return "$_rc"
}

list_exit_nodes() {
    if ! tailscale_ready; then
        err "Tailscale 尚未登录或未运行。"
        return 1
    fi

    echo ""
    echo "可见 Exit Nodes："
    "$TS" status | awk '
        /offers exit node/ || /active; exit node/ {
            printf "  %-20s %s\n", $2, $1
        }'
    echo ""
}

choose_exit_node() {
    if ! tailscale_ready; then
        err "Tailscale 尚未登录或未运行。"
        return 1
    fi
    if [ "$ADVERTISE_EXIT" = "1" ]; then
        err "本路由器正在提供 Exit Node，请先关闭该功能。"
        return 1
    fi

    _list="/tmp/ts-manager-exitnodes"
    "$TS" status | awk '
        /offers exit node/ || /active; exit node/ {
            print $1, $2
        }' >"$_list"

    if [ ! -s "$_list" ]; then
        err "当前没有发现可用的 Exit Node。"
        rm -f "$_list"
        return 1
    fi

    echo ""
    awk '{printf "  %d) %-20s %s\n", NR, $2, $1}' "$_list"
    echo ""
    printf "请选择 Exit Node 序号: "
    read _choice

    case "$_choice" in
        ''|*[!0-9]*)
            err "无效序号。"
            rm -f "$_list"
            return 1
            ;;
    esac

    _node="$(awk -v n="$_choice" 'NR==n {print $1}' "$_list")"
    _name="$(awk -v n="$_choice" 'NR==n {print $2}' "$_list")"
    rm -f "$_list"

    if [ -z "$_node" ]; then
        err "序号不存在。"
        return 1
    fi

    # Prevent IPv6 from bypassing the IPv4-only V1 gateway path.
    EXIT_NODE="$_node"
    apply_ipv6_block

    if ! "$TS" set \
        --exit-node="$_node" \
        --exit-node-allow-lan-access=true
    then
        EXIT_NODE=""
        remove_ipv6_block
        err "选择 Exit Node 失败。"
        return 1
    fi

    save_config
    apply_nat

    say "Exit Node 已切换为: $_name ($_node)"
    say "主 LAN/Wi-Fi IPv4 将经由该节点；LAN IPv6 转发已阻止。"
}

disable_exit_node() {
    init_base
    load_config

    if [ -x "$TS" ] && pidof tailscaled >/dev/null 2>&1; then
        "$TS" set --exit-node= >/dev/null 2>&1
    fi

    EXIT_NODE=""
    save_config
    remove_nat
    remove_ipv6_block

    say "Exit Node 已取消，主 LAN/Wi-Fi 恢复普通 WAN。"
}

show_status() {
    init_base
    load_config
    detect_arch >/dev/null 2>&1
    get_lan_if
    get_lan_cidr >/dev/null 2>&1

    echo ""
    echo "====== Tailscale Manager v$SCRIPT_VERSION ======"
    echo "CPU 架构:        ${ARCH:-unknown}"
    echo "记录版本:        ${VERSION:-未安装}"
    echo "运行目录:        $RUNTIME"
    echo "State:           $STATE"
    echo "LAN 接口:        ${LAN_IF:-unknown}"
    echo "LAN 网段:        ${LAN_CIDR:-unknown}"
    echo "VPS 镜像:        ${MIRROR_BASE:-未设置}"
    echo "保存 Exit Node:  ${EXIT_NODE:-OFF}"
    echo "本机提供出口:    $ADVERTISE_EXIT"
    echo "Exit 模式挡IPv6: $BLOCK_IPV6"
    echo ""

    if pidof tailscaled >/dev/null 2>&1; then
        echo "tailscaled:      RUNNING"
    else
        echo "tailscaled:      STOPPED"
    fi

    if [ -x "$TS" ]; then
        echo "运行版本:"
        "$TS" version 2>/dev/null | head -n 1
        echo ""
        "$TS" status 2>/dev/null || true
    else
        echo "当前 /tmp 中没有 Tailscale 二进制。"
    fi

    echo ""
    echo "LAN -> tailscale0 NAT:"
    iptables -t nat -S POSTROUTING 2>/dev/null | \
        grep 'tailscale0.*MASQUERADE' || echo "  (none)"

    echo "LAN IPv6 block:"
    ip6tables -S FORWARD 2>/dev/null | \
        grep -- "-i ${LAN_IF:-br0} .*REJECT" || echo "  (none)"
    echo "======================================="
}

set_mirror() {
    init_base
    echo ""
    echo "VPS 镜像目录示例："
    echo "  https://example.com/tailscale"
    echo ""
    echo "目录建议包含："
    echo "  version.txt"
    echo "  tailscale_<version>_arm64.tgz"
    echo ""
    printf "输入镜像 Base URL（直接回车=取消镜像，仅用官方源）: "
    read _m

    MIRROR_BASE="$(echo "$_m" | sed 's:/*$::')"
    save_config
    say "镜像设置已保存: ${MIRROR_BASE:-官方源 only}"
}

restart_tailscale() {
    init_base
    detect_arch || return 1

    if ! ensure_runtime_retry; then
        err "无法准备 Tailscale 运行文件。"
        return 1
    fi

    stop_daemon
    start_daemon || return 1
    sleep 3
    restore_exit
    restore_advertisement || return 1
    say "tailscaled 已重启。"
}

remove_hook_block() {
    _file="$1"
    _marker="$2"
    _expected="$3"
    [ -f "$_file" ] || return 0
    _tmp="${_file}.ts-manager.$$"

    # Remove only a marker followed by the exact command this manager wrote.
    # A changed command is left intact and stops uninstall for manual review.
    if ! awk -v marker="$_marker" -v expected="$_expected" '
        $0 == marker {
            if ((getline following) <= 0) {
                print marker
                bad=1
                next
            }
            if (following == expected) next
            print marker
            print following
            bad=1
            next
        }
        { print }
        END { if (bad) exit 2 }
    ' "$_file" >"$_tmp"; then
        rm -f "$_tmp"
        err "钩子内容已变化，未修改 $_file；请手动检查 $_marker。"
        return 1
    fi
    chmod 755 "$_tmp" && mv -f "$_tmp" "$_file"
}

check_hook_block() {
    _file="$1"
    _marker="$2"
    _expected="$3"
    [ -f "$_file" ] || return 0
    awk -v marker="$_marker" -v expected="$_expected" '
        $0 == marker {
            if ((getline following) <= 0 || following != expected) exit 2
        }
    ' "$_file" || {
        err "钩子内容已变化，已停止卸载；请手动检查 $_file 中的 $_marker。"
        return 1
    }
}

remove_hooks() {
    check_hook_block "/jffs/scripts/services-start" "# ts-manager: boot" \
        "$SELF boot >/tmp/ts-manager-boot.log 2>&1 &" || return 1
    check_hook_block "/jffs/scripts/wan-start" "# ts-manager: wan retry" \
        "$SELF boot >/tmp/ts-manager-wan.log 2>&1 &" || return 1
    check_hook_block "/jffs/scripts/nat-start" "# ts-manager: restore NAT" \
        "$SELF nat-restore >/dev/null 2>&1 &" || return 1
    check_hook_block "/jffs/scripts/firewall-start" "# ts-manager: restore firewall" \
        "$SELF firewall-restore >/dev/null 2>&1 &" || return 1

    remove_hook_block "/jffs/scripts/services-start" "# ts-manager: boot" \
        "$SELF boot >/tmp/ts-manager-boot.log 2>&1 &" || return 1
    remove_hook_block "/jffs/scripts/wan-start" "# ts-manager: wan retry" \
        "$SELF boot >/tmp/ts-manager-wan.log 2>&1 &" || return 1
    remove_hook_block "/jffs/scripts/nat-start" "# ts-manager: restore NAT" \
        "$SELF nat-restore >/dev/null 2>&1 &" || return 1
    remove_hook_block "/jffs/scripts/firewall-start" "# ts-manager: restore firewall" \
        "$SELF firewall-restore >/dev/null 2>&1 &"
}

stop_managed_daemon() {
    _managed=""
    for _pid in $(pidof tailscaled 2>/dev/null); do
        if tr '\000' '\n' <"/proc/$_pid/cmdline" 2>/dev/null |
            grep -Fx -- "--state=$STATE" >/dev/null 2>&1; then
            _managed="$_managed $_pid"
        else
            err "检测到非本脚本管理的 tailscaled (PID $_pid)，已停止卸载。"
            return 1
        fi
    done
    [ -n "$_managed" ] || return 0
    kill $_managed 2>/dev/null || return 1
    _n=0
    while [ "$_n" -lt 10 ]; do
        _alive=0
        for _pid in $_managed; do
            [ -d "/proc/$_pid" ] && _alive=1
        done
        [ "$_alive" = "0" ] && return 0
        sleep 1
        _n=$((_n + 1))
    done
    err "tailscaled 未正常退出，已停止卸载。"
    return 1
}

uninstall_manager() {
    _mode="${1:-keep-state}"
    case "$_mode" in
        keep-state|purge) ;;
        *) err "未知卸载模式: $_mode"; return 1 ;;
    esac
    if [ -d "$LOCKDIR" ]; then
        err "开机恢复任务仍在执行（$LOCKDIR），请稍后重试。"
        return 1
    fi
    # Check daemon ownership before removing any hooks.
    for _pid in $(pidof tailscaled 2>/dev/null); do
        if ! tr '\000' '\n' <"/proc/$_pid/cmdline" 2>/dev/null |
            grep -Fx -- "--state=$STATE" >/dev/null 2>&1; then
            err "检测到非本脚本管理的 tailscaled (PID $_pid)，已停止卸载。"
            return 1
        fi
    done

    remove_hooks || return 1
    if [ -x "$TS" ] && pidof tailscaled >/dev/null 2>&1; then
        "$TS" set --advertise-exit-node=false >/dev/null 2>&1 ||
            warn "未能取消提供 Exit Node；重装后将按新配置关闭。"
        "$TS" set --exit-node= >/dev/null 2>&1 ||
            warn "未能取消使用远程 Exit Node。"
    fi
    stop_managed_daemon || return 1
    remove_nat
    remove_ipv6_block
    rm -rf "$RUNTIME" "$RUNTIME_NEW" "$RUNTIME_OLD" "$STAGE" "$LOCKDIR"
    rm -f "$PKG" "$LOG" /tmp/ts-manager-exitnodes \
        /tmp/ts-manager-boot.log /tmp/ts-manager-wan.log
    rm -f "$CONF" "$SELF"

    if [ "$_mode" = "purge" ]; then
        rm -f "$STATE"
        say "完全卸载完成，本机登录状态已删除；管理后台中的设备记录需自行处理。"
    else
        [ -f "$STATE" ] && chmod 600 "$STATE" 2>/dev/null
        say "安全卸载完成；登录状态保留在 $STATE。"
    fi
    rmdir "$BASE" 2>/dev/null || true
}

uninstall_interactive() {
    echo ""
    echo "1) 安全卸载（保留登录状态）"
    echo "2) 完全卸载（删除本机登录状态）"
    echo "0) 取消"
    printf "请选择: "
    read _choice
    case "$_choice" in
        1) uninstall_manager keep-state ;;
        2)
            printf "输入 DELETE 确认删除 $STATE: "
            read _confirm
            [ "$_confirm" = "DELETE" ] || {
                say "已取消完全卸载。"
                return 1
            }
            uninstall_manager purge
            ;;
        0) return 1 ;;
        *) warn "无效选择。"; return 1 ;;
    esac
}

menu() {
    need_root
    init_base
    detect_arch || exit 1
    install_self

    while :; do
        echo ""
        echo "===== Asuswrt-Merlin Tailscale Manager v$SCRIPT_VERSION ====="
        echo "1) 安装 / 升级到最新 stable"
        echo "2) 首次登录 / 重新连接 Tailscale"
        echo "3) 查看状态"
        echo "4) 查看可用 Exit Nodes"
        echo "5) 选择一个 Exit Node（整个主 LAN/Wi-Fi）"
        echo "6) 取消 Exit Node，恢复普通 WAN"
        echo "7) 设置 VPS 下载镜像"
        echo "8) 重启 Tailscale"
        echo "9) 安装 / 修复 Merlin 开机钩子"
        echo "10) 将本路由器设为 Exit Node"
        echo "11) 关闭本路由器 Exit Node"
        echo "12) 安全卸载 / 完全卸载"
        echo "0) 退出"
        echo ""
        printf "请选择: "
        read _ans

        case "$_ans" in
            1) upgrade_latest ;;
            2) login_interactive ;;
            3) show_status ;;
            4) list_exit_nodes ;;
            5) choose_exit_node ;;
            6) disable_exit_node ;;
            7) set_mirror ;;
            8) restart_tailscale ;;
            9) install_hooks ;;
            10) enable_exit_advertisement ;;
            11) disable_exit_advertisement ;;
            12) uninstall_interactive && exit 0 ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

need_root
init_base
detect_arch >/dev/null 2>&1

case "${1:-menu}" in
    boot) boot_main ;;
    nat-restore) nat_restore_main ;;
    firewall-restore) firewall_restore_main ;;
    status) show_status ;;
    start)
        ensure_runtime_retry && start_daemon && restore_exit && restore_advertisement
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        restart_tailscale
        ;;
    upgrade)
        upgrade_latest
        ;;
    login)
        login_interactive
        ;;
    exit-off)
        disable_exit_node
        ;;
    hooks)
        install_hooks
        ;;
    offer-exit-on)
        enable_exit_advertisement
        ;;
    offer-exit-off)
        disable_exit_advertisement
        ;;
    uninstall)
        uninstall_manager keep-state
        ;;
    menu|'')
        menu
        ;;
    *)
        echo "Usage: $0 [menu|boot|status|start|stop|restart|upgrade|login|exit-off|offer-exit-on|offer-exit-off|hooks|uninstall]"
        exit 1
        ;;
esac
