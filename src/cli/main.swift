import Foundation
import Darwin

// ledctl — command-line control for the MagSafe 3 LED (SMC key ACLC).
//
//   ledctl status                 查看当前状态（无需 root）
//   ledctl off                    关灯（需 helper 或 sudo）
//   ledctl system                 交回系统控制
//   ledctl green | amber          强制常亮绿 / 橙
//   ledctl blinkslow | blinkfast | blinkoff
//   ledctl probe                  探测本机 SMC 密钥表
//   ledctl install | uninstall    安装/卸载后台守护
//
// LED values: 00=system 01=off 03=green 04=amber 06=slow-blink 07=fast-blink 19=blink-then-off

enum LEDMode: String {
    case off, system, green, amber, blinkslow, blinkfast, blinkoff
    var value: UInt8 {
        switch self {
        case .system: return 0x00
        case .off: return 0x01
        case .green: return 0x03
        case .amber: return 0x04
        case .blinkslow: return 0x06
        case .blinkfast: return 0x07
        case .blinkoff: return 0x19
        }
    }
    static func fromValue(_ v: UInt8) -> String {
        switch v {
        case 0x00: return "系统控制（充电橙、满电绿）"
        case 0x01: return "已关闭"
        case 0x03: return "常亮绿"
        case 0x04: return "常亮橙"
        case 0x06: return "慢速闪烁"
        case 0x07: return "快速闪烁"
        case 0x19: return "闪烁后关闭"
        default: return "未知状态 0x\(String(format: "%02x", v))"
        }
    }
}

func modeName(_ name: String) -> LEDMode? {
    switch name.lowercased() {
    case "off", "关灯": return .off
    case "system", "sys", "恢复": return .system
    case "green", "绿": return .green
    case "amber", "orange", "橙": return .amber
    case "blinkslow", "慢闪": return .blinkslow
    case "blinkfast", "快闪": return .blinkfast
    case "blinkoff": return .blinkoff
    default: return nil
    }
}

func directRead() -> UInt8? {
    return try? SMC.readByte(SMC.magSafeLEDKey)
}

func printStatus(supported: Bool, value: UInt8?) {
    if !supported {
        print("⚠️  这台 Mac 没有 MagSafe 3 硬件（SMC 无 ACLC 密钥）。")
        print("    本机是: \(hostInfo())")
        print("    请在带 MagSafe 3 的 MacBook Pro（M 系列，2021+）上使用。")
        return
    }
    guard let v = value else {
        print("ACLC 密钥存在，但读取失败（SMC 异常？）")
        return
    }
    print("MagSafe 3 LED: \(LEDMode.fromValue(v))  (SMC ACLC = 0x\(String(format: "%02x", v)))")
    if LedSock.helperRunning() {
        print("后台守护: 运行中 (magled-helper) — 状态会在重启/拔插后自动保持")
    } else {
        print("后台守护: 未运行 — 手动设置重启后会丢失。建议: sh install.sh")
    }
}

func hostInfo() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafeBytes(of: &sysinfo.machine) { p in
        let bytes = p.prefix(while: { $0 != 0 })
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
    return machine
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = (args.first ?? "status").lowercased()

if cmd == "help" || cmd == "--help" || cmd == "-h" {
    print("""
    ledctl — MagSafe 3 LED 开关（SMC ACLC）
      ledctl status                查看当前 LED 状态
      ledctl off                   关灯（01）
      ledctl system                恢复系统控制（00）
      ledctl green | amber         强制常亮（03 / 04）
      ledctl blinkslow | blinkfast | blinkoff
      ledctl probe                 探测本机 SMC 密钥
      ledctl install               安装后台守护（需要管理员密码）
      ledctl uninstall             卸载后台守护（需要管理员密码）
    """)
    exit(0)
}

if cmd == "probe" {
    print("SMC probe on \(hostInfo()):")
    for key in ["ACLC", "BFCL", "CH0B", "PEVC", "PSTR", "BAT0", "BDIN", "PC04"] {
        if let info = try? SMC.keyInfo(key) {
            let v = (try? SMC.readByte(key)).map { " val=0x\(String(format: "%02x", $0))" } ?? ""
            print("  \(key)  size=\(info.size) type=\(info.type)\(v)")
        } else {
            print("  \(key)  — 不存在")
        }
    }
    exit(0)
}

if cmd == "install" {
    runScript("install.sh", confirm: "安装 magled 后台守护？")
    exit(0)
}
if cmd == "uninstall" {
    runScript("uninstall.sh", confirm: "卸载 magled？")
    exit(0)
}

if let mode = modeName(cmd) {
    let hex = String(format: "%02x", mode.value)
    if let reply = LedSock.send("set \(hex)") {
        if reply.ok {
            print("OK — MagSafe 3 LED 已设为: \(LEDMode.fromValue(mode.value))")
        } else {
            if reply.payload == "aclc-key-missing" {
                print("⚠️  这台 Mac 没有 MagSafe 3 硬件，无法控制 LED。")
            } else {
                print("helper 拒绝: \(reply.payload)")
            }
            exit(1)
        }
        exit(0)
    }
    // helper 没跑：尝试直接写（需要 root）
    if geteuid() == 0 {
        do {
            try SMC.writeByte(SMC.magSafeLEDKey, mode.value)
            print("OK (direct, root) — LED 已设为: \(LEDMode.fromValue(mode.value))")
            print("提示: 重启后会丢失。建议 sh install.sh 装后台守护。")
        } catch {
            print("直接写入失败: \(error)")
            exit(1)
        }
        exit(0)
    }
    print("后台守护未运行，且当前不是 root。")
    print("  方案 A: 用菜单栏 MagLED 应用（推荐）")
    print("  方案 B: sudo ledctl \(cmd)")
    print("  方案 C: sh install.sh 安装后台守护后重试")
    exit(1)
}

// default: status
let supported = SMC.isLEDKeySupported()
if let reply = LedSock.send("get") {
    if reply.ok, let v = UInt8(reply.payload, radix: 16) {
        printStatus(supported: true, value: v)
    } else if reply.payload == "aclc-key-missing" {
        printStatus(supported: false, value: nil)
    } else {
        print("helper 异常: \(reply.payload)；直接读取: \(directRead().map { LEDMode.fromValue($0) } ?? "读取失败")")
    }
} else if supported {
    printStatus(supported: true, value: directRead())
} else {
    printStatus(supported: false, value: nil)
}

func runScript(_ name: String, confirm: String) {
    let here = FileManager.default.currentDirectoryPath
    let exeDir = ((CommandLine.arguments.first ?? "") as NSString).deletingLastPathComponent as String
    var scriptPath = ""
    for base in [here, "/Applications/MagLED.app/Contents/Resources", exeDir] {
        let p = (base as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: p) { scriptPath = p; break }
    }
    guard !scriptPath.isEmpty else {
        print("找不到 \(name)（脚本应与 ledctl 放在同一目录，或在解压包根目录运行）")
        exit(1)
    }
    let esc = scriptPath.replacingOccurrences(of: "\"", with: "\"\"")
    let prompt = confirm.replacingOccurrences(of: "\"", with: "\"\"")
    let appleScript = "do shell script \"sh \(esc)\" with prompt \"\(prompt)\" with administrator privileges"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", appleScript]
    task.launch()
    task.waitUntilExit()
    let ok = task.terminationStatus == 0
    print(ok ? "完成。" : "安装过程被取消或失败（若输入密码时按了取消键属正常）。")
    exit(ok ? 0 : 1)
}
