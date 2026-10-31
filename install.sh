#!/bin/bash
# heat-sampler 安装脚本（需要 sudo，因为 powermetrics 必须 root 运行）
#   sudo bash install.sh
# 做四件事：
#   1. 渲染 plist 模板（__USER_HOME__ → 真实用户目录，采样脚本带 --home 参数）
#   2. 安装 root LaunchDaemon（com.xuan.heatsampler，每 120 秒采样一次）
#   3. 立即试跑一次验证
# 卸载：
#   sudo launchctl bootout system/com.xuan.heatsampler
#   sudo rm /Library/LaunchDaemons/com.xuan.heatsampler.plist

set -e
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.xuan.heatsampler.plist"
REAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_HOME=$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory | awk '{print $2}')

echo "==> 用户: ${REAL_USER} (${USER_HOME})"
if [ ! -f "${SRC_DIR}/sampler.py" ]; then
    echo "错误: 请把本仓库 clone/present 到 ~/Library/heat-sampler 后再运行（当前: ${SRC_DIR}）" >&2
    exit 1
fi

echo "==> 退役同职责的旧服务（如有）"
launchctl bootout "gui/$(id -u "${REAL_USER}")/com.xuan.heatguard" 2>/dev/null || true
rm -f "/Users/${REAL_USER}/Library/LaunchAgents/com.xuan.heatguard.plist" 2>/dev/null || true
launchctl bootout "system/com.xuan.heatsampler" 2>/dev/null || true

echo "==> 渲染并安装 root LaunchDaemon"
mkdir -p "${USER_HOME}/.cache/heat-sampler"
sed "s|__USER_HOME__|${USER_HOME}|g" "${SRC_DIR}/${PLIST_NAME}" > "/Library/LaunchDaemons/${PLIST_NAME}"
chmod 644 "/Library/LaunchDaemons/${PLIST_NAME}"
chown root:wheel "/Library/LaunchDaemons/${PLIST_NAME}"

echo "==> 立即试跑一次"
launchctl bootstrap system "/Library/LaunchDaemons/${PLIST_NAME}"
sleep 6
echo "==> 最近一次采样输出："
tail -3 "${USER_HOME}/.cache/heat-sampler/daemon.out.log" 2>/dev/null
echo "==> 数据文件："
ls -l "${USER_HOME}/.cache/heat-sampler/metrics.json" 2>/dev/null || {
    echo "还没有 metrics.json，排查: cat ${USER_HOME}/.cache/heat-sampler/daemon.err.log"
    echo "原始 powermetrics 输出对照: ${USER_HOME}/.cache/heat-sampler/pmetrics_raw.txt"
}
echo "完成。状态: sudo launchctl print system/com.xuan.heatsampler"
