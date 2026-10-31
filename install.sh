#!/bin/bash
# heat-sampler 安装/启停脚本（安装与运行分离）
#
#   bash install.sh          安装: 只放置文件与服务定义, 不启动、不采样、不要密码
#   bash install.sh start    启动: 确保已安装 → 启动服务 → 立即试跑一次
#   bash install.sh stop     停止: 卸载当前服务(文件保留)
#   bash install.sh --root   精准模式: 弹系统授权框 → root 服务(powermetrics 最热核/真实功耗)
#
# 说明: 用户级服务装好后, 开机登录时 launchd 会自动拉起(无需手动 start);
#       start 只是想立刻用、不等重启时用。两个模式互斥, 后装的顶掉先装的。
set -e
MODE="${1:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --root 且尚未提权时, 弹 macOS 图形授权框后以 root 重跑
if [ "$MODE" = "--root" ] && [ "$(id -u)" -ne 0 ] && [ "${2:-}" != "--elevated" ]; then
    SELF="${SELF_DIR}/$(basename "${BASH_SOURCE[0]}")"
    echo "==> 即将弹出系统授权框（输入开机密码）…"
    exec /usr/bin/osascript -e "do shell script \"bash '${SELF}' --root --elevated\" with administrator privileges"
fi

REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_HOME=$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory | awk '{print $2}')
CACHE_DIR="${USER_HOME}/.cache/heat-sampler"
UID_NUM=$(id -u "${REAL_USER}")
USER_PLIST="/Users/${REAL_USER}/Library/LaunchAgents/com.xuan.heatsampler.user.plist"
mkdir -p "$CACHE_DIR"

if [ ! -f "${SELF_DIR}/sampler.py" ]; then
    echo "错误: 请把仓库 clone 到 ~/Library/heat-sampler 再运行（当前: ${SELF_DIR}）" >&2
    exit 1
fi

# ── 子命令: stop / start 先处理 ──
if [ "$MODE" = "stop" ]; then
    launchctl bootout "gui/${UID_NUM}/com.xuan.heatsampler.user" 2>/dev/null || true
    echo "已停止(采样停了, 数据会自然过期; 文件都还在, start 可再启)"
    exit 0
fi

echo "==> 用户: ${REAL_USER} (${USER_HOME})"

install_files() {
    # 放置文件 + 渲染 plist(不启动)。幂等, 重复跑无害。
    echo "==> 安装文件"
    sed "s|__USER_HOME__|${USER_HOME}|g" "${SELF_DIR}/com.xuan.heatsampler.user.plist" > "$USER_PLIST"
    echo "    plist -> $USER_PLIST"
}

retire_user_agents() {
    launchctl bootout "gui/${UID_NUM}/com.xuan.heatguard" 2>/dev/null || true
    rm -f "/Users/${REAL_USER}/Library/LaunchAgents/com.xuan.heatguard.plist" 2>/dev/null || true
    launchctl bootout "gui/${UID_NUM}/com.xuan.heatsampler.user" 2>/dev/null || true
}

if [ "$MODE" = "--root" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "--root 需要 root 权限（sudo bash install.sh --root，或在 HeatBar 菜单点升级）" >&2
        exit 1
    fi
    echo "==> 退役用户级采样, 安装 root 精准采样"
    launchctl bootout "gui/${UID_NUM}/com.xuan.heatsampler.user" 2>/dev/null || true
    launchctl bootout "system/com.xuan.heatsampler" 2>/dev/null || true
    sed "s|__USER_HOME__|${USER_HOME}|g" "${SELF_DIR}/com.xuan.heatsampler.plist" > "/Library/LaunchDaemons/com.xuan.heatsampler.plist"
    chmod 644 "/Library/LaunchDaemons/com.xuan.heatsampler.plist"
    chown root:wheel "/Library/LaunchDaemons/com.xuan.heatsampler.plist"
    launchctl bootstrap system "/Library/LaunchDaemons/com.xuan.heatsampler.plist"
    sleep 6
    MODE_DESC="root 精准采样(powermetrics 最热核/真实功耗)"
    echo "── 最近一次采样:"
    tail -3 "${CACHE_DIR}/daemon.out.log" 2>/dev/null || true
    SHOW_PERM_TIPS=1
else
    # 用户模式: --root daemon 已装则提示无需降级
    if [ -f "/Library/LaunchDaemons/com.xuan.heatsampler.plist" ] && launchctl print "system/com.xuan.heatsampler" >/dev/null 2>&1; then
        echo "检测到 root 精准采样正在运行, 用户模式不再启动。"
        echo "如确实要降级: sudo launchctl bootout system/com.xuan.heatsampler && sudo rm /Library/LaunchDaemons/com.xuan.heatsampler.plist"
        exit 0
    fi
    install_files
    if [ "$MODE" = "start" ]; then
        echo "==> 启动"
        launchctl bootstrap "gui/${UID_NUM}" "$USER_PLIST" 2>/dev/null || launchctl kickstart -k "gui/${UID_NUM}/com.xuan.heatsampler.user"
        sleep 5
        echo "── 试跑结果:"
        /usr/bin/python3 - "$CACHE_DIR/metrics.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("    CPU %s°C · GPU %s°C (来源 %s)" % (d.get("cpu_temp"), d.get("gpu_temp"), d.get("temp_src")))
except Exception:
    print("    尚未出数, 排查: ~/.cache/heat-sampler/agent.err.log")
PYEOF
    else
        echo "==> 已安装（未启动）。"
        echo "    登录时 launchd 会自动拉起; 想现在就用: bash install.sh start"
    fi
    MODE_DESC="用户级免授权采样(macmon 平均口径)"
    SHOW_PERM_TIPS=1
fi

if [ "${SHOW_PERM_TIPS:-0}" = "1" ]; then
    echo ""
    echo "── 权限说明（启动后按需辅助获取, 不用提前准备） ──"
    echo "ℹ️  当前模式: ${MODE_DESC}"
    echo "ℹ️  精准采样升级: HeatBar 菜单会出现「⚡ 升级精准采样」, 点一下弹授权框即可;"
    echo "   没装 HeatBar 就跑: bash install.sh --root（管理员授权仅此一次）"
    echo "ℹ️  通知权限: HeatBar 首次过热预警时系统会问一次「允许通知」;"
    echo "   拒绝了也没关系, 菜单里会常驻「🔔 开启通知权限」直达系统设置"
fi
