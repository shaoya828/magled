import AppKit
import Foundation
import ServiceManagement

// MagLED — menu bar app: one-click switch for the MagSafe 3 cable LED.
// All SMC writes go through the magled-helper root daemon (Unix socket).
// Reads are done directly (no root needed).

let kNightStartHour = 23
let kNightEndHour = 7
let kNightPrefKey = "NightScheduleEnabled"
let kLastModeKey = "LastMode"

final class MagLEDController: NSObject, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var sMC: SMC.Client?

    // menu item references
    var statusItem2: NSMenuItem!
    var itemOff: NSMenuItem!
    var itemSystem: NSMenuItem!
    var itemGreen: NSMenuItem!
    var itemAmber: NSMenuItem!
    var itemNight: NSMenuItem!
    var itemLogin: NSMenuItem!
    var itemHelperStatus: NSMenuItem!
    var itemInstall: NSMenuItem!
    var itemFirmware: NSMenuItem!
    var itemAbout: NSMenuItem!

    var current: UInt8 = 0
    var supported = false
    var helperUp = false
    var nightEnabled = false {
        didSet { UserDefaults.standard.set(nightEnabled, forKey: kNightPrefKey) }
    }
    var nightApplied = false   // whether "night off" is currently in effect by the schedule
    var firmwareTimer: Timer?
    var firmwareConnected: Bool?
    var firmwareGeneration = 0
    var timer: Timer?
    var refreshWorkItem: DispatchWorkItem?

    func bootstrap() {
        let defaultItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = defaultItem
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        statusItem2 = NSMenuItem()
        let night = UserDefaults.standard.bool(forKey: kNightPrefKey)
        nightEnabled = night
        let saved = UserDefaults.standard.object(forKey: kLastModeKey) as? String
        if let s = saved, let v = UInt8(s, radix: 16), [0, 1, 3, 4].contains(v) {
            current = v
        }

        let header = NSMenuItem(title: "MagSafe 灯", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusItem2.title = "…"
        statusItem2.isEnabled = false
        menu.addItem(statusItem2)
        menu.addItem(.separator())

        itemSystem = NSMenuItem(title: "跟随系统（默认）", action: #selector(setSystem), keyEquivalent: "")
        itemSystem.target = self
        menu.addItem(itemSystem)

        itemOff = NSMenuItem(title: "关闭灯光", action: #selector(setOff), keyEquivalent: "o")
        itemOff.target = self
        menu.addItem(itemOff)

        itemGreen = NSMenuItem(title: "常亮绿", action: #selector(setGreen), keyEquivalent: "")
        itemGreen.target = self
        menu.addItem(itemGreen)

        itemAmber = NSMenuItem(title: "常亮橙", action: #selector(setAmber), keyEquivalent: "")
        itemAmber.target = self
        menu.addItem(itemAmber)

        menu.addItem(.separator())
        itemNight = NSMenuItem(title: "夜间自动关灯（23:00–07:00）", action: #selector(toggleNight), keyEquivalent: "")
        itemNight.target = self
        menu.addItem(itemNight)

        itemLogin = NSMenuItem(title: "开机时启动", action: #selector(toggleLogin), keyEquivalent: "")
        itemLogin.target = self
        menu.addItem(itemLogin)

        menu.addItem(.separator())
        itemHelperStatus = NSMenuItem(title: "后台守护: …", action: nil, keyEquivalent: "")
        itemHelperStatus.isEnabled = false
        menu.addItem(itemHelperStatus)
        itemInstall = NSMenuItem(title: "安装后台守护（需要密码）", action: #selector(installHelper), keyEquivalent: "")
        itemInstall.target = self
        menu.addItem(itemInstall)

        itemFirmware = NSMenuItem(title: "固件: …", action: #selector(showFirmware), keyEquivalent: "")
        itemFirmware.target = self
        menu.addItem(itemFirmware)

        itemAbout = NSMenuItem(title: "关于 MagLED", action: #selector(showAbout), keyEquivalent: "")
        itemAbout.target = self
        menu.addItem(itemAbout)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MagLED", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // wake/sleep re-assertion
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(handleWake), name: NSNotification.Name("com.apple.notice.powersaved"), object: nil)
        dnc.addObserver(self, selector: #selector(handleWake), name: NSNotification.Name("com.apple.coreservices.daemon.isTerminalDetected"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)

        updateLoginCheck()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
        refresh()

        // 连接状态检查很轻；只在接入时运行较慢的固件查询。
        firmwareTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshFirmware()
        }
        RunLoop.main.add(firmwareTimer!, forMode: .common)
        refreshFirmware()
    }

    func refreshFirmware(force: Bool = false) {
        let connected = Fw.isCableConnected()
        guard force || firmwareConnected != connected else { return }
        firmwareConnected = connected
        firmwareGeneration += 1
        let generation = firmwareGeneration
        itemFirmware.title = connected ? "线缆固件: 读取中…" : "线缆未连接（查看端口信息）"
        guard connected else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = Fw.display()
            DispatchQueue.main.async {
                guard let self, self.firmwareGeneration == generation else { return }
                guard Fw.isCableConnected() else { self.refreshFirmware(); return }
                self.itemFirmware.title = "\(Fw.kind(d)): " + (d?.short ?? "未检测到")
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshFirmware()
    }

    // ---- state I/O ----

    func readCurrent() -> UInt8? {
        if helperUp, let r = LedSock.send("get"), r.ok, let v = UInt8(r.payload, radix: 16) {
            return v
        }
        if SMC.isLEDKeySupported() {
            if sMC == nil { sMC = try? SMC.Client() }
            if let c = sMC { return try? c.readByte(SMC.magSafeLEDKey) }
        }
        return nil
    }

    func writeCurrent(_ v: UInt8) -> Bool {
        guard helperUp, let r = LedSock.send("set \(String(format: "%02x", v))"), r.ok else {
            return false
        }
        return true
    }

    func refresh() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.helperUp = LedSock.helperRunning()
            self.supported = SMC.isLEDKeySupported()
            if let v = self.readCurrent() { self.current = v }
            self.rebuildMenu()
            if self.nightEnabled { self.tick() }
        }
        refreshWorkItem?.cancel()
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func rebuildMenu() {
        var titles: [String]
        if !supported {
            titles = ["这台 Mac 没有 MagSafe 3，无灯可关"]
            itemSystem.title = "跟随系统（默认）"
            itemOff.title = "关闭灯光（不可用）"
            itemGreen.title = "常亮绿（不可用）"
            itemAmber.title = "常亮橙（不可用）"
            itemSystem.isEnabled = false
            itemOff.isEnabled = false
            itemGreen.isEnabled = false
            itemAmber.isEnabled = false
        } else {
            itemSystem.isEnabled = true
            itemOff.isEnabled = true
            itemGreen.isEnabled = true
            itemAmber.isEnabled = true
            titles = [
                "当前: \(LEDModeText.current(current))",
                "跟随系统（默认）",
                "关闭灯光",
                "常亮绿",
                "常亮橙"
            ]
            itemSystem.title = titles[1]
            itemOff.title = titles[2]
            itemGreen.title = titles[3]
            itemAmber.title = titles[4]
            if helperUp {
                statusItem2.title = "当前: \(LEDModeText.current(current))"
            } else {
                statusItem2.title = "当前: \(LEDModeText.current(current))（守护离线，重启后不保持）"
            }
        }

        let states: [(NSMenuItem, UInt8)] = [(itemSystem, 0), (itemOff, 1), (itemGreen, 3), (itemAmber, 4)]
        for (item, v) in states where supported {
            item.state = (current == v) ? .on : .off
        }
        itemNight.state = nightEnabled ? .on : .off
        itemHelperStatus.title = helperUp ? "后台守护: 运行中 ✓" : "后台守护: 未安装"
        itemInstall.isHidden = helperUp
        updateIcon()
    }

    func updateIcon() {
        let off = !supported || current == 1
        let symbol = off ? "lightbulb.slash" : "lightbulb.fill"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "MagSafe LED")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // ---- actions ----

    @objc func setSystem() { applyMode(0, title: "跟随系统") }
    @objc func setOff() { applyMode(1, title: "已关闭") }
    @objc func setGreen() { applyMode(3, title: "常亮绿") }
    @objc func setAmber() { applyMode(4, title: "常亮橙") }

    func applyMode(_ v: UInt8, title: String) {
        guard supported else { flash(title: "这台 Mac 没有 MagSafe 3 硬件") ; return }
        guard helperUp else {
            flash(title: "后台守护未安装 — 请先安装（输入密码）")
            installHelper()
            return
        }
        current = v
        UserDefaults.standard.set(String(format: "%02x", v), forKey: kLastModeKey)
        nightApplied = false
        let ok = writeCurrent(v)
        flash(title: ok ? "已\(title)" : "设置失败 — 守护异常？")
        rebuildMenu()
        refresh()
    }

    func flash(title: String) {
        statusItem2.title = title
        statusItem2.isEnabled = false
        let work = DispatchWorkItem { [weak self] in self?.rebuildMenu() }
        refreshWorkItem?.cancel()
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    @objc func toggleNight() {
        nightEnabled.toggle()
        itemNight.state = nightEnabled ? .on : .off
        if nightEnabled { tick() } else {
            // restore to system when disabling
            if helperUp { _ = writeCurrent(0); current = 0 }
            nightApplied = false
            rebuildMenu()
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            flash(title: "开机自启设置失败: \(error.localizedDescription)")
        }
        updateLoginCheck()
    }

    func updateLoginCheck() {
        itemLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func installHelper() {
        let resources = Bundle.main.resourcePath ?? ""
        let script = (resources as NSString).appendingPathComponent("install.sh")
        guard FileManager.default.fileExists(atPath: script) else {
            flash(title: "找不到 install.sh（应用包不完整？）")
            return
        }
        let esc = script.replacingOccurrences(of: "\"", with: "\"\"")
        let appleScript = "do shell script \"sh \(esc)\" with prompt \"安装 magled 后台守护\" with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]
        task.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.flash(title: t.terminationStatus == 0 ? "后台守护已安装 ✓" : "安装被取消或失败")
            }
        }
        do { try task.run() } catch { flash(title: "无法启动安装: \(error.localizedDescription)") }
    }

    @objc func showFirmware() {
        refreshFirmware(force: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = Fw.display()
            var detail: String
            if let d = d {
                detail = d.text
                if d.channel == "AppleHPM" {
                    detail += "\n\n当前显示 Mac 端口信息，非线缆版本。接入线缆后自动读取其固件版本。"
                    detail += "\n“driver”为 AppleHPM 驱动版本。"
                } else if d.channel == "CableFW" {
                    detail = "Apple A2363 MagSafe 3 线缆\n固件版本：\(d.value)"
                    detail += "\n\n通过系统 hpmdiagnose 读取。"
                } else {
                    detail += "\n\n说明: SMC/IOKit 兜底渠道（原始值，未经厂商文档确认）。"
                }
            } else {
                detail = "未找到固件版本信息。\n\n本机（\(Fw.hostMachine())）的电源口未暴露 FW Version 属性。"
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "MagSafe 3 端口与固件信息"
                alert.informativeText = detail
                alert.addButton(withTitle: "好")
                alert.runModal()
                self?.refreshFirmware(force: true)
            }
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MagLED 1.1"
        alert.informativeText = """
        MagSafe 3 充电线 LED 开关。

        原理: Mac 的 SMC 系统管理控制器（ACLC 密钥）控制线缆指示灯。
        - 00 系统 / 01 关闭 / 03 常亮绿 / 04 常亮橙
        - 写入 SMC 需要 root，因此配合一个小型后台守护（magled-helper）。
        - 守护会在重启、拔插、睡眠唤醒后自动保持你选的灯态。

        灯是纯装饰，关掉不影响充电、电池和任何功能。
        仅供技术研究，非 Apple 官方工具。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }

    @objc func handleWake() {
        refreshFirmware(force: true)
        // SMC can reset on wake; re-assert current mode if the helper is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.helperUp, self.supported else { return }
            if self.nightEnabled && !inNight() { self.nightApplied = false }
            if self.current != 0 {
                _ = self.writeCurrent(self.current)
            }
        }
        self.refresh()
    }

    // ---- night schedule ----

    func inNight() -> Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= kNightStartHour || h < kNightEndHour
    }

    func tick() {
        guard nightEnabled, supported, helperUp else { return }
        let shouldOff = inNight()
        guard shouldOff != nightApplied else { return }
        nightApplied = shouldOff
        let v: UInt8 = shouldOff ? 1 : 0
        if writeCurrent(v) {
            current = v
            rebuildMenu()
            flash(title: shouldOff ? "夜间模式：灯已关闭" : "夜间结束：恢复系统")
        }
    }
}

final class App: NSObject, NSApplicationDelegate {
    var controller: MagLEDController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = MagLEDController()
        c.bootstrap()
        controller = c
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
