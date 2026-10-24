import Foundation
import Darwin

// probe.swift — 只读探测工具（仅读，绝不写）。
//
// 用法:
//   ./probe            已知的 8 个 SMC 键探测（默认，老行为）
//   ./probe keys       SMC 全键枚举（#KEY/KKEY 索引法，含 1 字节键当前值）
//   ./probe fw         固件/身份探测：IOKit 全注册表扫描 + SMC 线缆/端口相关键
//
// 在 M2 Max MacBook Pro 上插上 MagSafe 3 线缆（最好接充电器）运行:
//   ./probe fw   > ~/Desktop/magled_fw.txt
//   ./probe keys >> ~/Desktop/magled_fw.txt
// 把 magled_fw.txt 发回，用于把固件读取对准真实键名。

let client: SMC.Client
do {
    client = try SMC.Client()
    print("SMC: AppleSMC service opened OK (uid=\(getuid()))")
} catch {
    print("SMC: FAILED to open AppleSMC: \(error)")
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first?.lowercased() ?? "default"

// (key, what it is)
let keys: [(String, String)] = [
    ("ACLC", "MagSafe 3 LED control (Apple Silicon) — the one we want"),
    ("BFCL", "Intel-era MagSafe 2 LED-ish key"),
    ("CH0B", "MagSafe 2 connector (Intel)"),
    ("PEVC", "external power connected (bool)"),
    ("PSTR", "power state (on/battery)"),
    ("BAT0", "battery voltage (fpe2, 16-bit)"),
    ("BDIN", "charging current (fpe2)"),
    ("X0MD", "system+LED state on some models"),
    ("PC04", "battery temp (sp78)"),
]

if mode == "default" {
    print("KEY     SIZE    TYPE      MEANING")
    for (key, meaning) in keys {
        do {
            let info = try client.keyInfo(key)
            var valueText = ""
            if info.size >= 1 {
                if let v = try? client.readByte(key) {
                    valueText = "  val=0x" + String(format: "%02x", v)
                }
            }
            print(String(format: "%@  size=%llu  type=%@  %@%@", key as NSString, info.size, info.type as NSString, meaning as NSString, valueText as NSString))
        } catch {
            print(String(format: "%@  NOT FOUND / ERROR: %@", key as NSString, "\(error)"))
        }
    }

    print("\n=== verdict ===")
    if SMC.isLEDKeySupported() {
        let v = (try? client.readByte(SMC.magSafeLEDKey)) ?? 0xFF
        print("ACLC EXISTS on this machine. Current value: 0x" + String(format: "%02x", v))
        print("Note: this is a Mac Studio (no MagSafe 3 port) — value here is informational only.")
    } else {
        print("ACLC key NOT present on this machine (Mac Studio, no MagSafe 3 hardware).")
        print("The M2 Max MacBook Pro target should have it. Probe must be re-run there.")
    }

} else if mode == "keys" {
    print("=== SMC full key enumeration (#KEY/KKEY index trick) ===")
    do {
        let all = try Fw.allSMCKeys(client)
        print("total keys: \(all.count)")
        print("NAME   SIZE  TYPE   VAL")
        for k in all.sorted(by: { $0.name < $1.name }) {
            let v = k.value.map { String(format: "0x%02x", $0) } ?? ""
            let raw = k.raw.map { "  raw=\($0)" } ?? ""
            print(String(format: "%@  size=%d  %-6@ %@%@%@  ", k.name as NSString, k.size, k.type as NSString, v as NSString, v.isEmpty ? "" : " " as NSString, raw as NSString))
        }
    } catch {
        print("key enumeration failed: \(error)")
    }

}