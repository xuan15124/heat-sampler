#!/usr/bin/env python3
# heat-sampler · Mac 侧独立采样服务（本机温度/功耗/风扇 → 统一 metrics.json）
#
# 定位: 设备级基础设施, 与 ZCode 插件(heat-guard)、QQbot 互相独立。
#   - QQbot: 不在本机/没挂载数据文件 → 显示"未接通", 与本服务无关
#   - heat-guard 插件: 本机没装本服务 → 自己用 macmon 兜底轻采样, 也不会动本服务
# 由 root LaunchDaemon(com.xuan.heatsampler)每 120 秒调用一次
# (powermetrics 必须以 root 运行; macOS 27 已封免 root 的 SMC 直读)。
#
# 输出(默认, 可用 ~/.zcode/heat-sampler.json 的 outputs 覆盖):
#   1. /Users/xuan/.cache/heat-sampler/metrics.json   本机规范位置(插件等消费者读这里)
#   2. QQbot hostdata 契约路径(存在才写)
# JSON 契约字段: ts/cpu_temp/gpu_temp/cpu_load(=1分钟负载)/load1/mem_used/mem_total/
#               uptime/power/cpu_power_w/gpu_power_w/all_power_w/fan_rpm/throttle_pct/
#               thermal_pressure/model/temp_src
#
# 原始 powermetrics 输出每次都留在 ~/.cache/heat-sampler/pmetrics_raw.txt, 解析有偏差时对照修。

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def real_user_home():
    """root(LaunchDaemon)运行时 Path.home() 是 /var/root, 由 install.sh 烘焙 --home 指定;
    用户态直接用 $HOME。"""
    args = sys.argv[1:]
    if "--home" in args:
        i = args.index("--home")
        if i + 1 < len(args):
            return Path(args[i + 1])
    return Path.home()


USER_HOME = real_user_home()
CONFIG_FILE = USER_HOME / ".zcode" / "heat-sampler.json"
CANONICAL = USER_HOME / ".cache" / "heat-sampler" / "metrics.json"
RAW_DUMP = USER_HOME / ".cache" / "heat-sampler" / "pmetrics_raw.txt"
# 暂停开关: 存在即跳过采样(用户权限可增删, 菜单栏 HeatBar / ZCode / 手动都行)
PAUSE_FLAG = USER_HOME / ".cache" / "heat-sampler" / "PAUSED"

# 默认只写本机规范位置; 其他消费者(如 QQbot hostdata)在
# ~/.zcode/heat-sampler.json 的 outputs 里追加, 不与任何项目耦合
DEFAULT_OUTPUTS = [str(CANONICAL)]


def load_outputs():
    try:
        cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        outs = cfg.get("outputs")
        if isinstance(outs, list) and outs:
            return [str(p) for p in outs]
    except (OSError, ValueError):
        pass
    return DEFAULT_OUTPUTS


def write_atomic(path_str, obj):
    try:
        p = Path(path_str)
        p.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=p.name + ".")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.chmod(tmp, 0o644)
        os.replace(tmp, str(p))
    except OSError as exc:
        print("write %s failed: %s" % (path_str, exc), file=sys.stderr)


def parse_pmetrics(out):
    """powermetrics 文本 → 温度/功耗/风扇。取最热核(单一传感器常是 max), 正则宁宽勿漏。"""
    cpu_temps, gpu_temps = [], []
    for m in re.finditer(r"(?i)(cpu|gpu)[^\n:]{0,40}?die\s+temperature[s]?:?\s*([\d.]+)", out):
        (cpu_temps if m.group(1).lower() == "cpu" else gpu_temps).append(float(m.group(2)))

    def watt(label):
        m = re.search(r"(?i)%s\s+Power:\s*([\d.]+)\s*(m?W)" % label, out)
        if not m:
            return None
        v = float(m.group(1))
        return round(v / 1000.0 if m.group(2) == "mW" else v, 1)

    fans = []
    for m in re.finditer(r"(?i)fan\s*\d*[^\n\d]{0,24}(\d{3,5})\s*rpm", out):
        fans.append(int(m.group(1)))
    pressure = ""
    m = re.search(r'(?i)thermal\s+pressure:?\s*"?([\w\- ]+)"?', out)
    if m:
        pressure = m.group(1).strip()
    return {
        "cpu_temp": max(cpu_temps) if cpu_temps else None,
        "gpu_temp": max(gpu_temps) if gpu_temps else None,
        "n_cpu_sensors": len(cpu_temps),
        "n_gpu_sensors": len(gpu_temps),
        "cpu_power_w": watt("CPU"),
        "gpu_power_w": watt("GPU"),
        "all_power_w": watt("Package") or watt("System"),
        "fan_rpm": fans,
        "thermal_pressure": pressure,
    }


def sysctl(key):
    try:
        return subprocess.run(
            ["/usr/sbin/sysctl", "-n", key],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def mem_usage():
    """近似用量: 总量 - (空闲 + 投机) 页, 字节。"""
    try:
        out = subprocess.run(
            ["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    m = re.search(r"page size of (\d+) bytes", out)
    ps = int(m.group(1)) if m else 16384

    def pages(label):
        mm = re.search(label + r":\s+(\d+)", out)
        return int(mm.group(1)) if mm else 0

    total_str = sysctl("hw.memsize")
    try:
        total = int(total_str)
    except ValueError:
        total = None
    used = None if total is None else max(0, total - (pages("Pages free") + pages("Pages speculative")) * ps)
    return used, total


def throttle_pct():
    try:
        out = subprocess.run(
            ["/usr/bin/pmset", "-g", "therm"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        m = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", out)
        if m:
            return int(m.group(1))
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def power_line(p):
    bits = []
    if p.get("cpu_power_w") is not None:
        bits.append("CPU %sW" % p["cpu_power_w"])
    if p.get("gpu_power_w") is not None:
        bits.append("GPU %sW" % p["gpu_power_w"])
    if p.get("all_power_w") is not None:
        bits.append("全机 %sW" % p["all_power_w"])
    return " · ".join(bits)


def macmon_once():
    """用户态兜底采样(macmon, 温度为多传感器平均口径)。--macmon 模式用。"""
    exe = None
    for c in ("/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"):
        try:
            if os.path.isfile(c) and os.access(c, os.X_OK):
                exe = c
                break
        except OSError:
            continue
    if exe is None:
        return None
    try:
        if exe == "/opt/homebrew/bin/macmon":
            out = subprocess.run(
                ["/opt/homebrew/bin/macmon", "pipe", "-s", "1", "-i", "300"],
                capture_output=True, text=True, timeout=10,
            ).stdout
        else:
            out = subprocess.run(
                ["/usr/local/bin/macmon", "pipe", "-s", "1", "-i", "300"],
                capture_output=True, text=True, timeout=10,
            ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            data = json.loads(line)
            if isinstance(data, dict):
                return data
    return None


def main():
    if PAUSE_FLAG.exists():
        print("sampler paused (%s exists), skip" % PAUSE_FLAG)
        return 0
    now = int(time.time())
    load1 = round(os.getloadavg()[0], 2)
    boot = re.search(r"sec\s*=\s*(\d+)", sysctl("kern.boottime"))
    mem_used, mem_total = mem_usage()
    tp = throttle_pct()
    model = sysctl("machdep.cpu.brand_string")

    if "--macmon" in sys.argv[1:]:
        # 用户态兜底模式: macmon 平均温度 + 系统级负载/内存, 供还没装 root daemon 时过渡
        m = macmon_once()
        t = (m.get("temp") or {}) if m else {}

        def watt(key):
            try:
                v = float((m or {}).get(key))
                return round(v, 1) if v > 0 else None
            except (TypeError, ValueError):
                return None

        metrics = {
            "ts": now,
            "model": model,
            "cpu_load": load1,
            "load1": load1,
            "cpu_usage_pct": None,
            "mem_used": mem_used,
            "mem_total": mem_total,
            "uptime": now - int(boot.group(1)) if boot else None,
            "power": "",
            "cpu_power_w": watt("cpu_power"),
            "gpu_power_w": watt("gpu_power"),
            "all_power_w": watt("all_power"),
            "fan_rpm": [f.get("rpm") for f in (m or {}).get("fans") or []],
            "throttle_pct": tp,
            "cpu_temp": round(t["cpu_temp_avg"], 1) if t.get("cpu_temp_avg") is not None else None,
            "gpu_temp": round(t["gpu_temp_avg"], 1) if t.get("gpu_temp_avg") is not None else None,
            "temp_src": "macmon",
        }
        outs = load_outputs()
        for path_str in outs:
            write_atomic(path_str, metrics)
        print("sampled(macmon): cpu=%s gpu=%s" % (metrics["cpu_temp"], metrics["gpu_temp"]))
        return 0 if metrics["cpu_temp"] is not None else 2

    try:
        out = subprocess.run(
            ["/usr/bin/powermetrics", "-n", "1", "-i", "200", "-s", "smc,cpu_power,gpu_power,thermal"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        print("powermetrics failed: %s" % exc, file=sys.stderr)
        return 1
    if not out.strip():
        print("powermetrics empty output", file=sys.stderr)
        return 1
    try:
        RAW_DUMP.write_text(out, encoding="utf-8")
    except OSError:
        pass

    p = parse_pmetrics(out)
    mem_used, mem_total = mem_usage()
    now = int(time.time())
    load1 = round(os.getloadavg()[0], 2)
    boot = re.search(r"sec\s*=\s*(\d+)", sysctl("kern.boottime"))

    metrics = {
        "ts": now,
        "model": sysctl("machdep.cpu.brand_string"),
        # QQbot 契约: cpu_load = 1 分钟负载
        "cpu_load": load1,
        "load1": load1,
        "mem_used": mem_used,
        "mem_total": mem_total,
        "uptime": now - int(boot.group(1)) if boot else None,
        "power": power_line(p),
        "cpu_power_w": p["cpu_power_w"],
        "gpu_power_w": p["gpu_power_w"],
        "all_power_w": p["all_power_w"],
        "fan_rpm": p["fan_rpm"],
        "throttle_pct": throttle_pct(),
        "thermal_pressure": p["thermal_pressure"],
        # 取最热核而非平均: 精度对标 Stats 的单传感器口径
        "cpu_temp": p["cpu_temp"],
        "gpu_temp": p["gpu_temp"],
        "n_temp_sensors": [p["n_cpu_sensors"], p["n_gpu_sensors"]],
        "temp_src": "powermetrics",
    }
    outs = load_outputs()
    for path_str in outs:
        write_atomic(path_str, metrics)
    ok = metrics["cpu_temp"] is not None or metrics["gpu_temp"] is not None
    print("sampled: cpu=%s gpu=%s sensors=%s power=%r fans=%s pressure=%r outputs=%d" % (
        metrics["cpu_temp"], metrics["gpu_temp"], metrics["n_temp_sensors"],
        metrics["power"], metrics["fan_rpm"], metrics["thermal_pressure"], len(outs)))
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
