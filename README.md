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
  "temp_src": "powermetrics"   // 或 "macmon"（免授权模式）
}
```

输出位置默认 `~/.cache/heat-sampler/metrics.json`，可在 `~/.zcode/heat-sampler.json` 的 `outputs` 数组里追加任意路径（本机示例把 QQbot 的 hostdata 也加了进去）。

## 安装与启停（安装、运行分离）

```bash
git clone https://github.com/xuan15124/heat-sampler ~/Library/heat-sampler
bash ~/Library/heat-sampler/install.sh          # 安装: 只放文件, 不启动、零权限、必然成功
bash ~/Library/heat-sampler/install.sh start    # 运行: 这一步才需要管理员授权(弹系统授权框)
bash ~/Library/heat-sampler/install.sh stop     # 停止: 同样需要授权(服务是 root 级的)
```

**单一模式，无降级**：本服务只有 root 精准采样一种形态——安装永远成功（只放文件），
运行必须授权；不授权就无法运行，没有免授权的备胎。

- **通知权限**：HeatBar 启动即检测，首次过热预警时系统会问一次「允许通知」；拒绝了菜单里常驻「🔔 开启通知权限」直达系统设置

**为什么必须 root / 数据从哪来**：macOS 27 已封掉免 root 的 SMC 用户态直读（实测 `kIOReturnUnsupported`），且把温度/风扇从 powermetrics 里也移除了（实测 `unrecognized sampler: smc`）。所以本服务以 root 跑 powermetrics（官方口子：CPU/GPU/全机功耗、热压力）+ macmon（经 IOReport，目前唯一还活着的温度/风扇来源）合并产出。装完自动适配，无需关心分工。

## HeatBar · 菜单栏控制

```bash
swiftc -O ~/Library/heat-sampler/HeatBar.swift -o /tmp/HeatBar
mkdir -p ~/Applications/HeatBar.app/Contents/MacOS ~/Applications/HeatBar.app/Contents/Resources
cp /tmp/HeatBar ~/Applications/HeatBar.app/Contents/MacOS/
cp HeatBar.icns ~/Applications/HeatBar.app/Contents/Resources/   # 可选
```

菜单栏显示 SF Symbols 温度计 + 实时 CPU 温度，随明暗自适应；过热（≥80°C）图标变红 + 系统通知（仅状态沿触发一次）。菜单内：

- **▶ 启动采样服务**：没数据时出现，一键补启动（免授权）
- **⚡ 升级精准采样**：免授权模式下出现，弹系统授权框完成 root 升级
- **🔔 开启通知权限**：通知被拒时出现，直达系统设置
- **暂停/恢复采样**：增删 `~/.cache/heat-sampler/PAUSED`（用户权限，不碰服务本体）

## 卸载

```bash
bash ~/Library/heat-sampler/install.sh stop     # 停用户级
sudo launchctl bootout system/com.xuan.heatsampler
sudo rm -f /Library/LaunchDaemons/com.xuan.heatsampler.plist
rm -f ~/Library/LaunchAgents/com.xuan.heatsampler.user.plist
launchctl bootout gui/$(id -u)/com.xuan.heatbar   # 若装了 HeatBar
```

## License

MIT
