#!/bin/bash
# heat-sampler 安装/运行脚本（安装与运行彻底分离）
#
#   bash install.sh          安装: 只检查/放置文件, 不启动、零权限、必然成功
#   bash install.sh start    运行: 需要管理员权限 → 弹一次系统授权框;
#                            不授权就无法运行(本服务只有 root 精准采样一种模式, 无降级)
#   bash install.sh stop     停止: 同样需要授权(服务是 root 级的)
#
# 为什么运行必须 root: macOS 27 已封免 root 的 SMC 用户态直读, powermetrics 是官方
# 唯一开放全部传感器(单核最热核温度/真实功耗)的口子。没有备胎, 不给权限就不跑。
set -e
MODE="${1:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SELF_DIR}/$(basename "${BASH_SOURCE[0]}")"
DAEMON_PLIST="/Library/LaunchDaemons/com.xuan.heatsampler.plist"

# ── start/stop 需要 root: 未提权时弹 macOS 图形授权框, 以 root 重跑本脚本 ──
case "$MODE" in
    start|stop)
        if [ "$(id -u)" -ne 0 ] && [ "${2:-}" != "--elevated" ]; then
            echo "==> 运行需要管理员权限，弹出系统授权框（输入开机密码）…"
            exec /usr/bin/osascript -e "do shell script \"bash '${SELF}' '${MODE}' --elevated\" with administrator privileges"
        fi
        ;;
    "")
        # 安装: 零权限, 只检查与就位文件
        if [ ! -f "${SELF_DIR}/sampler.py" ] || [ ! -f "${SELF_DIR}/com.xuan.heatsampler.plist" ]; then
            echo "错误: 文件不全, 请完整 clone 仓库到 ~/Library/heat-sampler（当前: ${SELF_DIR}）" >&2
            exit 1
        fi
        /usr/bin/python3 -m py_compile "${SELF_DIR}/sampler.py" 2>/dev/null || true
        mkdir -p "${HOME}/.cache/heat-sampler"
        echo "✅ 已安装（未授权、未运行）。"
        echo "   启动: bash install.sh start  ← 启动那一刻才需要授权, 会弹系统授权框"
        echo "   不授权就无法运行: 本服务只有 root 精准采样一种模式, 无降级。"
        exit 0
        ;;
    *)
        echo "用法: bash install.sh [start|stop]" >&2
        exit 1
        ;;
esac

# ── 以下都以 root 执行（经授权框或 sudo）──
REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_HOME=$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory | awk '{print $2}')
CACHE_DIR="${USER_HOME}/.cache/heat-sampler"
mkdir -p "$CACHE_DIR"

echo "==> 用户: ${REAL_USER} (${USER_HOME})"

retire_user_agents() {
    # 兼容清理: 早期版本的用户级服务(现已不存在用户模式)
    UID_NUM=$(id -u "${REAL_USER}")
    launchctl bootout "gui/${UID_NUM}/com.xuan.heatguard" 2>/dev/null || true
    rm -f "/Users/${REAL_USER}/Library/LaunchAgents/com.xuan.heatguard.plist" 2>/dev/null || true
    launchctl bootout "gui/${UID_NUM}/com.xuan.heatsampler.user" 2>/dev/null || true
    rm -f "/Users/${REAL_USER}/Library/LaunchAgents/com.xuan.heatsampler.user.plist" 2>/dev/null || true
}

if [ "$MODE" = "stop" ]; then
    launchctl bootout "system/com.xuan.heatsampler" 2>/dev/null || true
    echo "已停止。文件都在, bash install.sh start 可再启(会再要一次授权)。"
    exit 0
fi

# MODE = start: 确保服务定义就位并启动
echo "==> 启动 root 精准采样服务"
retire_user_agents
launchctl bootout "system/com.xuan.heatsampler" 2>/dev/null || true
sed "s|__USER_HOME__|${USER_HOME}|g" "${SELF_DIR}/com.xuan.heatsampler.plist" > "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"
chown root:wheel "$DAEMON_PLIST"
launchctl bootstrap system "$DAEMON_PLIST"
sleep 6

echo "── 数据文件: ${CACHE_DIR}/metrics.json"
/usr/bin/python3 - "$CACHE_DIR/metrics.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("── 已出数: CPU %s°C · GPU %s°C (来源 %s)" % (d.get("cpu_temp"), d.get("gpu_temp"), d.get("temp_src")))
except Exception:
    print("── 尚未出数, 排查: ~/.cache/heat-sampler/daemon.err.log 与 daemon.out.log")
PYEOF
echo ""
echo "── 权限说明 ──"
echo "ℹ️  管理员授权: 刚才授权框里已完成, 仅启动/停止时需要"
echo "ℹ️  通知权限: HeatBar 启动时检测, 首次过热预警系统会问一次「允许通知」;"
echo "   拒绝了也没关系, 菜单常驻「🔔 开启通知权限」直达系统设置"
