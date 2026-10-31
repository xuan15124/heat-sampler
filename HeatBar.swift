// HeatBar · 菜单栏温度图标 + heat-sampler 控制/权限辅助
// 编译: swiftc -O HeatBar.swift -o HeatBar
// 职责: 显示实时温度; 暂停/恢复采样(PAUSED 标记文件);
//       未启用 root 精准采样时提供「升级」入口(弹授权框); 通知权限启动时检测, 缺就引导。
// 暂停/升级都不需要预先授权: 升级用系统授权框, 通知走系统首次询问。

import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "读取中…", action: nil, keyEquivalent: "")
    let startItem = NSMenuItem(title: "▶ 启动采样服务", action: #selector(startSampler), keyEquivalent: "")
    let notifyItem = NSMenuItem(title: "🔔 开启通知权限", action: #selector(openNotifySettings), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "暂停采样", action: #selector(togglePause), keyEquivalent: "")
    var metricsPath: String { Self.home + "/.cache/heat-sampler/metrics.json" }
    var pausePath: String { Self.home + "/.cache/heat-sampler/PAUSED" }
    var paused = false
    var wasHot = false
    var notifyGranted = true  // 授权结果回来前先隐藏, 免得没弹过授权框就挂引导项
    var timer: Timer?
    let hotThreshold: Double = 80  // 与 heat-guard 默认 hot_temp_c 一致

    static var home: String { NSHomeDirectory() }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 菜单栏常驻, 不上 Dock
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        startItem.target = self
        menu.addItem(startItem)
        notifyItem.target = self
        menu.addItem(notifyItem)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 HeatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        paused = FileManager.default.fileExists(atPath: pausePath)
        requestNotifyAuth()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in self.refresh() }
    }

    // ── 通知权限: 启动即检测, 没决定就弹系统询问, 拒绝了给直达设置的入口 ──
    func requestNotifyAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notifyGranted = granted
                self?.refresh()
            }
        }
    }

    @objc func openNotifySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    @objc func startSampler() {
        // 服务没在跑时的一键补启动(免授权): install.sh start = 确保已安装 + 启动
        runInstallArg("start")
    }

    func runInstallArg(_ arg: String) {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["\(Self.home)/Library/heat-sampler/install.sh", arg]
        do {
            try task.run()
            statusLine.title = "正在\(arg == "start" ? "启动采样服务" : "升级精准采样")…"
            DispatchQueue.global().async {
                task.waitUntilExit()
                DispatchQueue.main.async { self.refresh() }
            }
        } catch {
            statusLine.title = "执行失败: \(error.localizedDescription)"
        }
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

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { [weak self] err in
            if err != nil { self?.osascriptNotify(title, body) }  // 未授权时的兜底
        }
    }

    func osascriptNotify(_ title: String, _ body: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
        try? task.run()
    }

    func refresh() {
        pauseItem.title = paused ? "恢复采样" : "暂停采样"
        if paused {
            item.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "已暂停")
            item.button?.image?.isTemplate = true
            item.button?.title = ""
            statusLine.title = "采样已暂停（恢复后 2 分钟内出数）"
            startItem.isHidden = true
            notifyItem.isHidden = true
            return
        }
        guard
            let d = FileManager.default.contents(atPath: metricsPath),
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else {
            item.button?.image = NSImage(systemSymbolName: "thermometer.medium.slash", accessibilityDescription: "无数据")
            item.button?.image?.isTemplate = true
            item.button?.title = ""
            statusLine.title = "没有采样数据（服务没启动？）"
            startItem.isHidden = false  // 一键补启动(会按需弹授权框)
            notifyItem.isHidden = notifyGranted
            return
        }
        let ts = (j["ts"] as? Double) ?? ((j["ts"] as? Int).map { Double($0) } ?? 0)
        let c = j["cpu_temp"] as? Double
        let g = j["gpu_temp"] as? Double
        let src = j["temp_src"] as? String ?? ""
        let age = Int(Date().timeIntervalSince1970 - ts)
        let show = c ?? g ?? -1

        // 权限辅助: 非 powermetrics 来源 = 还在免授权模式 → 显示升级入口
        startItem.isHidden = true  // 有数据 = 服务在跑
        notifyItem.isHidden = notifyGranted

        item.button?.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "温度")
        item.button?.image?.isTemplate = true
        item.button?.title = show >= 0 ? String(format: "%.0f°", show) : "–"
        // 主动预警: 过热图标变红 + 状态沿触发一次系统通知, 回落后自动恢复
        let hot = show >= hotThreshold
        item.button?.contentTintColor = hot ? NSColor.systemRed : nil
        if hot && !wasHot {
            notify(
                "本机过热 🔥",
                String(format: "CPU %.0f° / GPU %.0f° 达到预警线 %.0f°——建议缓一缓重活，注意散热", c ?? g ?? -1, g ?? -1, hotThreshold)
            )
        }
        wasHot = hot
        var line = String(format: "CPU %.0f° · GPU %.0f°", c ?? -1, g ?? -1)
        if let p = j["power"] as? String, !p.isEmpty { line += " · " + p }
        line += String(format: " · 数据 %d 秒前", age)
        if hot { line += " —— 🔴 过热预警中" }
        if age > 300 { line += "（可能已断供或暂停）" }
        statusLine.title = line
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
