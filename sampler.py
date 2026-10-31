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
    """powermetrics 文本 → 功耗/热压力(温度在 macOS 27 已被苹果移出 powermetrics, 见 main)。"""
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
    # macOS 27: "Current pressure level: Nominal"; 旧版: "Thermal pressure: Nominal"
    m = re.search(r'(?i)pressure\s+level:?\s*"?([\w\-]+)"?', out) or re.search(
        r'(?i)thermal\s+pressure:?\s*"?([\w\-]+)"?', out
    )
    if m and m.group(1):
        pressure = m.group(1).strip()
    m = re.search(r"(?i)Combined\s+Power[^:]*:\s*([\d.]+)\s*(m?W)", out)
    combined = None
    if m:
        v = float(m.group(1))
        combined = round(v / 1000.0 if m.group(2) == "mW" else v, 1)
    return {
        "cpu_temp": None,   # 温度由 macmon 补(macOS 27 powermetrics 已无传感器输出)
        "gpu_temp": None,
        "cpu_power_w": watt("CPU"),
        "gpu_power_w": watt("GPU"),
        "all_power_w": watt("Package") or watt("System") or combined,
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


def macmon_once():
    """macmon 单次采样(用户态 IOReport): macOS 27 上仅存的温度/风扇来源。"""
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


def power_line(p):
    bits = []
    if p.get("cpu_power_w") is not None:
        bits.append("CPU %sW" % p["cpu_power_w"])
    if p.get("gpu_power_w") is not None:
        bits.append("GPU %sW" % p["gpu_power_w"])
    if p.get("all_power_w") is not None:
        bits.append("全机 %sW" % p["all_power_w"])
    return " · ".join(bits)


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

    try:
        r = subprocess.run(
            # macOS 27: "smc" 采样器已移除, 温度并入 thermal
            ["/usr/bin/powermetrics", "-n", "1", "-i", "200", "-s", "cpu_power,gpu_power,ane_power,thermal"],
            capture_output=True, text=True, timeout=30,
        )
        out, err = r.stdout, r.stderr
    except (OSError, subprocess.SubprocessError) as exc:
        print("powermetrics failed: %s" % exc, file=sys.stderr)
        return 1
    if not out.strip():
        # 诊断: stderr 留痕(采样器参数错误/权限问题都在这里)
        print("powermetrics rc=%s stderr=%r" % (r.returncode, err[:500]), file=sys.stderr)
        try:
            Path(str(RAW_DUMP) + ".err").write_text(err or "(empty stderr)", encoding="utf-8")
        except OSError:
            pass
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

    # 温度与风扇: macOS 27 把它们移出了 powermetrics, macmon(用户态 IOReport)是目前唯一来源
    cpu_temp = gpu_temp = None
    fans = p["fan_rpm"]
    m = macmon_once()
    if m:
        t = m.get("temp") or {}
        if t.get("cpu_temp_avg") is not None:
            cpu_temp = round(float(t["cpu_temp_avg"]), 1)
        if t.get("gpu_temp_avg") is not None:
            gpu_temp = round(float(t["gpu_temp_avg"]), 1)
        if not fans and m.get("fans"):
            # root 下 macmon 风扇可能读 0(权限不叠加), 0 视为无数据
            fans = [f.get("rpm") for f in m.get("fans") or [] if f.get("rpm")]

    temp_src = "powermetrics+macmon" if cpu_temp is not None else "powermetrics"
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
        "fan_rpm": fans,
        "throttle_pct": throttle_pct(),
        "thermal_pressure": p["thermal_pressure"],
        "cpu_temp": cpu_temp,
        "gpu_temp": gpu_temp,
        "temp_src": temp_src,
    }
    outs = load_outputs()
    for path_str in outs:
        write_atomic(path_str, metrics)
    ok = cpu_temp is not None or metrics["cpu_power_w"] is not None
    print("sampled: cpu=%s gpu=%s power=%r fans=%s pressure=%r src=%s outputs=%d" % (
        cpu_temp, gpu_temp, metrics["power"], fans, p["thermal_pressure"], temp_src, len(outs)))
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
