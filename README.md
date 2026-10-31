# heat-sampler · Mac 侧温度/功耗采样服务

本机温度、功耗、风扇的**独立采样服务**：launchd 定时（默认 120 秒）采一次，写成一份数字契约 JSON，供多个互不耦合的消费者读取。

**与消费者解耦**：

- [heat-guard](https://github.com/xuan15124/zcode-heat-guard)（ZCode 插件）：本机装了本服务就读它的数据；没装则该插件用 macmon 兜底，互不依赖
- QQbot 等任何程序：把 `metrics.json` 的路径挂载/读取即可，本服务不感知任何消费者

## 数据契约（metrics.json）

```json
{
  "ts": 1793411247,            // 采样时刻 unix 秒
  "model": "Apple M2 Pro",
  "cpu_temp": 45.2,            // 最热 CPU 传感器 (°C)
  "gpu_temp": 48.7,            // 最热 GPU 传感器 (°C)
  "cpu_load": 3.45,            // 1 分钟负载
  "mem_used": 12897992704,     // 字节
  "mem_total": 17179869184,
  "uptime": 326490,            // 开机秒数
  "power": "CPU 2.5W · GPU 0.3W · 全机 4.6W",
  "fan_rpm": [1942, 2056],
  "throttle_pct": null,        // pmset 节流百分比, null=未记录
  "thermal_pressure": "Nominal",
  "temp_src": "powermetrics"   // 或 "macmon"（过渡模式）
}
```

输出位置默认 `~/.cache/heat-sampler/metrics.json`，可在 `~/.zcode/heat-sampler.json` 的 `outputs` 数组里追加任意路径（本机示例把 QQbot 的 hostdata 也加了进去）。

## 安装（需要 sudo 一次）

```bash
git clone https://github.com/xuan15124/heat-sampler ~/Library/heat-sampler
sudo bash ~/Library/heat-sampler/install.sh
```

`install.sh` 会：渲染 plist 模板（自动适配你的用户目录）→ 装 root LaunchDaemon（`com.xuan.heatsampler`）→ 立即试跑一次。

**为什么 root**：macOS 27 已封掉免 root 的 SMC 用户态直读（实测 `kIOReturnUnsupported`），powermetrics 是官方唯一开放全部传感器（单核温度/真实功耗）的口子。

**为什么取最热核**：单传感器峰值比多传感器平均更接近真实最热处（对齐 Stats 的口径）。

## HeatBar · 菜单栏控制

```bash
swiftc -O ~/Library/heat-sampler/HeatBar.swift -o /tmp/HeatBar
mkdir -p ~/Applications/HeatBar.app/Contents/MacOS ~/Applications/HeatBar.app/Contents/Resources
cp /tmp/HeatBar ~/Applications/HeatBar.app/Contents/MacOS/
cp HeatBar.icns ~/Applications/HeatBar.app/Contents/Resources/   # 可选
```

菜单栏显示 SF Symbols 温度计 + 实时 CPU 温度；**暂停/恢复采样**一键切换。暂停机制是增删 `~/.cache/heat-sampler/PAUSED` 标记文件（用户权限，不碰 root 服务）——采样器每次运行前检查该标记，跳过即暂停。

## 暂停的其他方式

```bash
touch ~/.cache/heat-sampler/PAUSED    # 暂停
rm ~/.cache/heat-sampler/PAUSED       # 恢复
```

暂停期间数据自然过期，各消费者自行降级（插件回退 macmon 兜底，面板显示"数据过期"）。

## 卸载

```bash
sudo launchctl bootout system/com.xuan.heatsampler
sudo rm /Library/LaunchDaemons/com.xuan.heatsampler.plist
launchctl bootout gui/$(id -u)/com.xuan.heatbar   # 若装了 HeatBar
```

## License

MIT
