// HeatBar · 菜单栏温度图标 + heat-sampler 暂停/恢复控制
// 编译: swiftc -O HeatBar.swift -o HeatBar
// 职责: 读 ~/.cache/heat-sampler/metrics.json 显示 CPU 温度;
//       暂停 = 创建 ~/.cache/heat-sampler/PAUSED(用户权限, 不碰 root 服务本身)。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "读取中…", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "暂停采样", action: #selector(togglePause), keyEquivalent: "")
    var metricsPath: String { Self.home + "/.cache/heat-sampler/metrics.json" }
    var pausePath: String { Self.home + "/.cache/heat-sampler/PAUSED" }
    static var home: String { NSHomeDirectory() }
    var paused = false
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 菜单栏常驻, 不上 Dock
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 HeatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        paused = FileManager.default.fileExists(atPath: pausePath)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in self.refresh() }
    }

    @objc func togglePause() {
        paused.toggle()
        if paused {
            FileManager.default.createFile(atPath: pausePath, contents: nil)
        } else {
            try? FileManager.default.removeItem(atPath: pausePath)
        }
        refresh()
    }

    func refresh() {
        pauseItem.title = paused ? "恢复采样" : "暂停采样"
        if paused {
            item.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "已暂停")
            item.button?.image?.isTemplate = true
            item.button?.title = ""
            statusLine.title = "采样已暂停（恢复后 2 分钟内出数）"
            return
        }
        guard
            let d = FileManager.default.contents(atPath: metricsPath),
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else {
            item.button?.image = NSImage(systemSymbolName: "thermometer.medium.slash", accessibilityDescription: "无数据")
            item.button?.image?.isTemplate = true
            item.button?.title = ""
            statusLine.title = "没有采样数据（heat-sampler 未安装？）"
            return
        }
        let ts = (j["ts"] as? Double) ?? ((j["ts"] as? Int).map { Double($0) } ?? 0)
        let c = j["cpu_temp"] as? Double
        let g = j["gpu_temp"] as? Double
        let age = Int(Date().timeIntervalSince1970 - ts)
        let show = c ?? g ?? -1
        item.button?.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "温度")
        item.button?.image?.isTemplate = true
        item.button?.title = show >= 0 ? String(format: "%.0f°", show) : "–"
        var line = String(format: "CPU %.0f° · GPU %.0f°", c ?? -1, g ?? -1)
        if let p = j["power"] as? String, !p.isEmpty { line += " · " + p }
        line += String(format: " · 数据 %d 秒前", age)
        if age > 300 { line += "（可能已断供或暂停）" }
        statusLine.title = line
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
