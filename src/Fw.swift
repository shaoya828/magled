// Fw.swift — MagSafe 3 cable / port firmware & identity discovery (READ-ONLY).
//
// Shared by the probe tool, ledctl (subcommands "probe"/"fw") and the MagLED app.
// Development machine (M5 Studio) has no MagSafe 3; run on the M2 Max
// MacBook Pro to see the real cable values.
//
// 用法（在 M2 Max MacBook Pro 上，插好 MagSafe 3 线）：
//   ./probe fw        → IOKit 注册表穷举 + SMC 线缆/端口相关键（含原始字节）
//   ./probe keys      → SMC 全键表（#KEY/KKEY 索引法，只读）
// 把输出发回即可把固件读取对准真实键名。
//
// 2026-10 修复（Tahoe SDK / Apple Silicon）：
// 1) IOServiceMatching("") 空类名匹配不到任何节点（旧版 probe 恒为 0 项）。
//    修复：NULL 匹配 = 全部服务；兜底再用 IORegistryCreateIterator 递归遍历平面。
//    （Tahoe SDK 已删除旧的 IORegistryEntryCreateCFIterator 与 Reverse 选项，
//     改用新签名：IORegistryGetRootEntry 单参 + IORegistryCreateIterator。）
// 2) Apple Silicon 上 #KEY 枚举返回垃圾（表偏移变化）：
//    加 count 合理性校验，判垃圾即改用固定候选表（电源/LED/连接器家族）+ keyInfo 探测。
//
// 2026-10-23 修订（版本语义对齐）—— 三个来源、三种含义，互不冒充：
// a) 线缆固件（hpmdiagnose 0x49 行 bcdDevice）—— 真正可读的线缆版本（3.1.12 → 3.2.0）。
//    从已识别 A2363 的诊断记录读取 bcdDevice；无有效记录时不推断版本。
// b) 电源口固件（IOKit "FW Version"，4 字节）—— HPM 电源口控制器内部固件，
//    Apple 未公布编码格式（M5 Studio 00 14 31 00 / M5 Pro 00 82 20 00 / M5 Air 00 02 31 00，
//    同机各口可同值）→ 仅展示原始字节，不推断线缆版本或更新状态。
// c) AppleHPM 驱动版本（Info.plist，如 3.4.4）—— 驱动自身版本，辅助参考。

import Foundation
import IOKit

struct FwSource {
    var channel: String      // "IOKit" / "AppleHPM" / "SMC"
    var node: String         // 类名@节点名 或 SMC 键名
    var label: String        // 属性键 / 键类型
    var value: String
    var strength: Int        // 3 = magsafe 口已接线，2 = magsafe 口，1 = 已接线/USB 相关，0 = 兜底
    var extra: String? = nil // 补充细节（原始字节 / 驱动版本 / 线缆状态）

    var line: String {
        let e = extra.map { "  \($0)" } ?? ""
        return "[\(channel)] \(node)  \(label) = \(value)\(e)"
    }
    /// 简短标题（菜单栏项用，超长截断）
    var short: String {
        if value.count > 28 { return String(value.prefix(28)) + "…" }
        return value
    }
    /// 详情文本（弹窗用）
    var text: String {
        let e = extra.map { "\n  \($0)" } ?? ""
        return "[\(channel)] \(node)\n  \(label) = \(value)\(e)"
    }
}

enum Fw {
    // MARK: 格式化

    static func fmt(_ v: Any?, dataLimit: Int = 24) -> String {
        if v == nil { return "(nil)" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return "\(n)" }
        if let d = v as? Data {
            let trimmed = d.filter { $0 != 0 }
            if let s = String(data: trimmed.isEmpty ? d : trimmed, encoding: .utf8),
               trimmed.allSatisfy({ $0 == 0 || ($0 >= 0x20 && $0 < 0x7f) }) {
                return "\"\(s)\""
            }
            let hex = d.prefix(dataLimit).map { String(format: "%02x", $0) }.joined(separator: " ")
            return d.count > dataLimit ? "<\(d.count)B hex> \(hex)…" : "<\(d.count)B hex> \(hex)"
        }
        if let arr = v as? [Any] {
            let parts = arr.prefix(8).map {
                if let s = $0 as? String { return s }
                if let i = $0 as? Int { return "\(i)" }
                return "?"
            }
            return "[\(parts.joined(separator: ", "))(\(arr.count))]"
        }
        if let cf = v as? CFTypeRef { return "(CFType: \(CFGetTypeID(cf)))" }
        return "(\(type(of: v!)))"
    }

    static func hostMachine() -> String {
        var u = utsname(); uname(&u)
        let b = withUnsafeBytes(of: &u.machine) { Array($0.prefix(while: { $0 != 0 })) }
        return String(bytes: b, encoding: .ascii) ?? "?"
    }

    // MARK: IOKit 穷举（纯 C 底层 API，只读）
    // 本 SDK 的 IOKit 主模块是 [extern_c]，无 IORegistryEntry 类，
    // 统一走 mach-port 句柄 + IORegistryEntryGetName / CreateCFProperties。

    static func sweep() -> [FwSource] {
        var out: [FwSource] = []
        let port = kIOMainPortDefault

        func ingest(_ obj: io_object_t) {
            let entry = io_registry_entry_t(obj)
            var nameBuf = [CChar](repeating: 0, count: 256)
            var node = "?"
            if IORegistryEntryGetName(entry, &nameBuf) == kIOReturnSuccess {
                node = String(cString: nameBuf)
            }

            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(entry, &props, nil, 0) == kIOReturnSuccess,
                  let p = props?.takeRetainedValue() as? [String: Any] else { return }

            let cls = (p["IOClass"] as? String) ?? "?"
            let nodeL = (node + " " + cls).lowercased()
            let hot = nodeL.contains("magsafe") || nodeL.contains("usb") || nodeL.contains("ioapdc")

            let fwSub = ["firmware", "fw", "version", "rev"]
            for (k, v) in p {
                let kl = k.lowercased()
                let valueS = fmt(v)
                let nameHot = kl.contains("magsafe") || valueS.lowercased().contains("magsafe")
                let fwHit = fwSub.contains(where: { kl.contains($0) })
                let idHit = kl.contains("product") || kl.contains("vendor")
                        || kl.contains("manufacturer") || kl.contains("serial")

                var strength = -1
                if nameHot { strength = 2 }
                else if hot && (fwHit || idHit) { strength = 1 }
                else if hot { strength = 0 }
                else if fwHit { strength = 0 }
                else { continue }

                let display = cls == "?" ? node : "\(cls)@\(node)"
                out.append(FwSource(channel: "IOKit", node: display, label: k, value: valueS, strength: strength))
            }
        }

        // 路径 1：NULL 匹配 —— 遍历全部服务（修复旧版空类名 0 项 bug）
        var iter: io_iterator_t = 0
        var visited = 0
        if IOServiceGetMatchingServices(port, nil, &iter) == kIOReturnSuccess {
            while true {
                let obj = IOIteratorNext(iter)
                if obj == 0 { break }
                visited += 1
                if visited > 8000 { break }   // 安全上限
                ingest(obj)
                IOObjectRelease(obj)
            }
            IOObjectRelease(iter)
        }

        // 路径 2（兜底）：递归遍历 IOService 平面（Tahoe 新签名）
        if visited == 0 {
            let root = IORegistryGetRootEntry(port)
            guard root != 0 else { return out }
            defer { IOObjectRelease(root) }
            var rit: io_iterator_t = 0
            if IORegistryCreateIterator(port, kIOServicePlane,
                                        IOOptionBits(kIORegistryIterateRecursively), &rit) == kIOReturnSuccess {
                var v = 0
                while true {
                    let obj = IOIteratorNext(rit)
                    if obj == 0 { break }
                    v += 1
                    if v > 8000 { break }
                    ingest(obj)
                    IOObjectRelease(obj)
                }
                IOObjectRelease(rit)
            }
        }
        return out.sorted { $0.strength > $1.strength }
    }

    // MARK: SMC 全键枚举（#KEY / KKEY 索引法，只读）

    struct KeyEntry {
        var name: String
        var size: Int
        var type: String
        var value: UInt8?
        var raw: String?     // 原始字节 hex（最多 8 字节，固件字段识别用）
    }

    /// 固定候选表：#KEY 在 Apple Silicon 上返回垃圾时的兜底。
    /// 电源 / 适配器 / 电池 / 连接器 / LED 家族（已知有效键 + 社区 SMC 键库）。
    static let candidateKeys: [String] = [
        // 本项目已知键
        "ACLC", "BFCL", "CH0B", "PEVC", "PSTR", "BAT0", "BDIN", "PC04", "X0MD",
        // AC / 适配器
        "AACL", "AACL2", "ACCP", "ACCE", "ACCH", "ACCB", "ACCN", "ACSS", "ACRB",
        "ACRC", "ACRF", "ACRG", "ACSA", "ACSB", "ACSC", "ACSD", "ACSL", "ACSO",
        "ACSP", "ACSQ", "ACSR", "ACST", "ACSU", "ACSV", "ACSW", "ACSY",
        // 电池 / 充电
        "BAT1", "BATP", "BATT", "BFPP", "BACM", "BACO", "BCLM", "BDST", "BRID",
        "BRST", "BCTL", "BUDF", "GBLT", "LBCN", "LRDP", "NRFC", "NTFC", "NTHC",
        "NTSM", "NPVB", "NPMV", "PS1P", "PS1P1", "PS1P2", "PSBK", "PSBR", "RCTI", "RPLE",
        // 电源状态 / 端口查询
        "PSOK", "PFPT", "P0QT", "P1QT", "P2QT", "P3QT", "P4QT",
        // 连接器 / 通道
        "CH0C", "CH01", "CH02", "CH03", "CH04", "CH05", "CH06", "CH07", "CH08",
        // 温度 / 保护
        "PTKR", "PLKD", "PPCM",
    ]

    static func allSMCKeys(_ client: SMC.Client) throws -> [KeyEntry] {
        var keys: [KeyEntry] = []
        var seen = Set<String>()

        // 1) #KEY 表大小（Intel 上为真实表大小）
        var count = -1
        var req = SMC.SMCParamStruct()
        req.key = try SMC.fourCC("#KEY")
        req.data8 = SMC.kSMCReadKey
        req.keyInfo.dataSize = 4
        if let reply = try? client.rawCall(req) {
            var n4 = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: reply.bytes) { p in n4 = Array(p.prefix(4)) }
            count = Int(n4[0]) | Int(n4[1]) << 8 | Int(n4[2]) << 16 | Int(n4[3]) << 24
        }
        // Apple Silicon：#KEY 返回垃圾偏移 → count 越界即判枚举不可用
        let enumerationUsable = (1...4096).contains(count)

        if enumerationUsable {
            for i in 0..<count {
                var req2 = SMC.SMCParamStruct()
                req2.key = try SMC.fourCC("KKEY")
                req2.data8 = SMC.kSMCReadKey
                req2.keyInfo.dataSize = 4
                var idx = UInt32(i).littleEndian
                withUnsafeMutableBytes(of: &req2.bytes) { p in
                    if let b = p.baseAddress { b.copyMemory(from: &idx, byteCount: 4) }
                }
                guard let reply = try? client.rawCall(req2) else { continue }
                var n4 = [UInt8](repeating: 0, count: 4)
                withUnsafeBytes(of: reply.bytes) { p in n4 = Array(p.prefix(4)) }
                // SMC 键名必须是可打印 ASCII；过滤表越界后的垃圾
                guard n4.allSatisfy({ $0 == 0 || ($0 >= 0x21 && $0 <= 0x7e) }) else { continue }
                guard !n4.contains(0) else { continue }
                let name = String(bytes: n4, encoding: .ascii) ?? ""
                guard !seen.contains(name), let info = try? client.keyInfo(name) else { continue }
                seen.insert(name)
                let v = (try? client.readByte(name)).map { $0 }
                keys.append(KeyEntry(name: name, size: Int(info.size), type: info.type, value: v, raw: nil))
            }
            // 枚举可用但命中过少（<20）→ 大概率也是垃圾，回退候选表
            if keys.count < 20 { keys.removeAll() }
        }

        // 2) 候选表兜底（枚举失败 / Apple Silicon 常规路径）
        if keys.isEmpty || !enumerationUsable {
            for name in candidateKeys {
                guard !seen.contains(name), let info = try? client.keyInfo(name) else { continue }
                seen.insert(name)
                let v = (try? client.readByte(name)).map { $0 }
                let raw = (try? client.readRaw(name, 8)).map { d in
                    d.map { String(format: "%02x", $0) }.joined(separator: " ")
                }
                keys.append(KeyEntry(name: name, size: Int(info.size), type: info.type, value: v, raw: raw))
            }
        }
        return keys
    }

    static func cableRelatedKeys(_ keys: [KeyEntry]) -> [KeyEntry] {
        let subs = ["pwr", "pd", "usb", "magsafe", "safe", "led", "aclc", "bfcl", "ch0", "port", "psrc", "efi", "charger", "pevc", "pstr", "bat", "bdin", "bctl", "x0md"]
        let fwSub = ["fw", "ver", "rev"]
        return keys.filter { k in
            let n = k.name.lowercased()
            let hot = subs.contains(where: { n.contains($0) })
            let fw = fwSub.contains(where: { n.contains($0) })
            return hot || fw
        }
    }

    // MARK: 电源口固件（AppleHPM 驱动，Apple Silicon 电源口管理，只读）
    // “FW Version”（4 字节）= HPM 电源口控制器内部固件。Apple 未公布编码格式：
    // 实测 M5 Studio 00 14 31 00、M5 Pro 00 82 20 00、M5 Air 00 02 31 00，同机各口恒同值，
    // 各家 M5 机器互不相同 → 只展示原始字节，不推断线缆固件版本。

    /// AppleHPM.kext 驱动版本（语义化版本，如 3.4.4；读 Info.plist，不碰驱动）
    static func driverVersion() -> String? {
        let path = "/System/Library/Extensions/AppleHPM.kext/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: path) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// 仅读取 MagSafe 端口连接状态，不依赖可能残留的 hpmdiagnose 记录。
    static func isCableConnected() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("AppleHPMInterfaceType11"), &iterator) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            let active = IORegistryEntryCreateCFProperty(entry, "ConnectionActive" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if active as? Bool == true { return true }
        }
        return false
    }

    // MARK: 线缆固件（hpmdiagnose 0x49 行，只读）
    // 与实测 awk 命令一致：bcdDevice = byte[10]:byte[9]，PID = byte[13]:byte[12]。
    // 仅识别 Apple A2363（VID 05ac / PID 4078），避免把其他端口状态当作线缆版本。
    static func bcdFromLine(_ bytes: [UInt8]) -> (String, String)? {
        guard bytes.count >= 14, bytes[0] != 0,
              bytes[1] == 0xac, bytes[2] == 0x05,
              bytes[12] == 0x78, bytes[13] == 0x40 else { return nil }
        let low = bytes[9], high = bytes[10]
        guard high >> 4 > 0,
              [high >> 4, high & 0xf, low >> 4, low & 0xf].allSatisfy({ $0 <= 9 }) else { return nil }
        let patch = Int(low >> 4) * 10 + Int(low & 0xf)
        return ("\(high >> 4).\(high & 0xf).\(patch)", String(format: "%02x%02x", high, low))
    }

    /// 所有已识别的 A2363 线缆版本；未连接、格式异常或未知设备返回空数组。
    static func cableFirmware() -> [FwSource] {
        guard isCableConnected() else { return [] }
        let task = Process()
        task.launchPath = "/usr/bin/hpmdiagnose"
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return cableFirmware(from: text, connected: isCableConnected())
    }

    static func cableFirmware(from text: String, connected: Bool = true) -> [FwSource] {
        guard connected else { return [] }
        var out: [FwSource] = []
        var port = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("HPM at ") {
                port = String(line)
                continue
            }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard !port.isEmpty, parts.count == 3, parts[0] == "0x49",
                  parts[1].hasPrefix("0x"), let length = Int(parts[1].dropFirst(2), radix: 16),
                  parts[2].hasPrefix("0x") else { continue }
            let hex = Array(parts[2].dropFirst(2))
            guard length >= 14, hex.count == length * 2 else { continue }
            var bytes = [UInt8]()
            for i in stride(from: 0, to: hex.count, by: 2) {
                guard let b = UInt8(String(hex[i...i+1]), radix: 16) else { break }
                bytes.append(b)
            }
            guard bytes.count == length, let (v, bcdHex) = bcdFromLine(bytes) else { continue }
            out.append(FwSource(channel: "CableFW", node: "Apple A2363 MagSafe 3 线缆",
                                label: "线缆固件版本", value: v, strength: 3,
                                extra: "bcdDevice 0x\(bcdHex) · VID 0x05ac · PID 0x4078\n  \(port)"))
        }
        return out
    }

    /// 所有电源口固件候选（IOKit 只读遍历，携带 “FW Version” 的 AppleHPMInterface 节点）。
    /// 排序：MagSafe 3 口已接线 > MagSafe 3 口 > 已接线 > 其余电源口。
    static func allPortFirmware() -> [FwSource] {
        struct Cand { var src: FwSource; var rank: Int }
        var cands: [Cand] = []
        let port = kIOMainPortDefault

        func ingest(_ obj: io_object_t) {
            let entry = io_registry_entry_t(obj)
            var nameBuf = [CChar](repeating: 0, count: 256)
            var node = "?"
            if IORegistryEntryGetName(entry, &nameBuf) == kIOReturnSuccess { node = String(cString: nameBuf) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(entry, &props, nil, 0) == kIOReturnSuccess,
                  let p = props?.takeRetainedValue() as? [String: Any],
                  let fw = p["FW Version"] as? Data, !fw.isEmpty else { return }

            let desc = (p["Description"] as? String) ?? (p["PortDescription"] as? String) ?? node
            let ptype = (p["PortTypeDescription"] as? String) ?? "?"
            let isMagsafe = (desc + " " + ptype).lowercased().contains("magsafe")
            let active = (p["ActiveCable"] as? Bool) == true || (p["ConnectionActive"] as? Bool) == true

            var rank = 0
            if isMagsafe { rank = 2 }
            if active { rank += 1 }

            let rawHex = Array(fw).map { String(format: "%02x", $0) }.joined()
            var extras = ["type=" + ptype]
            if let dv = driverVersion() { extras.append("driver " + dv) }
            extras.append(active ? "cable=已接入" : "cable=未接入")
            let src = FwSource(channel: "AppleHPM", node: desc, label: "FW Version",
                               value: "<" + rawHex + ">", strength: rank,
                               extra: extras.joined(separator: "  "))
            cands.append(Cand(src: src, rank: rank))
        }

        var iter: io_iterator_t = 0
        var visited = 0
        if IOServiceGetMatchingServices(port, nil, &iter) == kIOReturnSuccess {
            while true {
                let obj = IOIteratorNext(iter)
                if obj == 0 { break }
                visited += 1
                if visited > 8000 { break }
                ingest(obj)
                IOObjectRelease(obj)
            }
            IOObjectRelease(iter)
        }
        if visited == 0 {
            // 兜底：递归遍历 IOService 平面
            let root = IORegistryGetRootEntry(port)
            guard root != 0 else { return [] }
            defer { IOObjectRelease(root) }
            var rit: io_iterator_t = 0
            if IORegistryCreateIterator(port, kIOServicePlane,
                                        IOOptionBits(kIORegistryIterateRecursively), &rit) == kIOReturnSuccess {
                var v = 0
                while true {
                    let obj = IOIteratorNext(rit)
                    if obj == 0 { break }
                    v += 1
                    if v > 8000 { break }
                    ingest(obj)
                    IOObjectRelease(obj)
                }
                IOObjectRelease(rit)
            }
        }
        return cands.sorted { $0.rank > $1.rank }.map { $0.src }
    }

    /// 最优电源口固件候选（无 "FW Version" 属性时返回 nil → 回退 SMC）
    static func portFirmware() -> FwSource? { allPortFirmware().first }

    /// 展示用标题前缀：线缆固件 > MagSafe 3 口 > 普通电源口
    static func kind(_ d: FwSource?) -> String {
        guard let d = d else { return "未检测到" }
        if d.channel == "CableFW" { return "线缆固件" }
        if d.channel == "AppleHPM" {
            return d.node.lowercased().contains("magsafe") ? "电源口固件(MagSafe 3)" : "电源口固件"
        }
        return d.channel == "SMC" ? "电源口固件(SMC)" : "电源口固件"
    }

    // MARK: 展示选择

    /// 展示候选：
    /// 1) hpmdiagnose 0x49 中已识别 A2363 的 bcdDevice；
    /// 2) AppleHPM “FW Version” 原始字节（不推断线缆固件版本）；
    /// 3) IOKit 兜底扫描（只认版本类属性，绝不把节点名/Description 当版本号 —— 旧版 bug）。
    static func iokitDisplay() -> FwSource? {
        if let best = cableFirmware().first { return best }
        if let best = portFirmware() { return best }
        let hits = sweep()
        func fwLike(_ h: FwSource) -> Bool {
            let l = h.label.lowercased()
            return ["firmware", "fw", "version", "rev"].contains(where: { l.contains($0) })
        }
        if let best = hits.first(where: { $0.strength == 2 && fwLike($0) }) { return best }
        if let best = hits.first(where: fwLike) { return best }
        return nil
    }

    static func display() -> FwSource? {
        if let d = iokitDisplay() { return d }
        // IOKit 侧没有 → 用 SMC 候选表兜底：只展示名字真正像固件/线缆的键
        guard let client = try? SMC.Client() else { return nil }
        let keys = (try? allSMCKeys(client)) ?? []
        for k in keys {
            let n = k.name.lowercased()
            guard ["fw", "ver", "rev", "magsafe"].contains(where: { n.contains($0) }) else { continue }
            guard let v = k.raw ?? k.value.map({ String(format: "0x%02x", $0) }) else { continue }
            // 全 0 的值不展示（未接线时的默认态）
            let bytes = v.split(separator: " ").map(String.init)
            guard bytes.allSatisfy({ $0 == "00" || $0.hasPrefix("0x00") }) == false || k.size == 1 else { continue }
            return FwSource(channel: "SMC", node: k.name, label: "raw(\(k.size)B \(k.type))", value: v, strength: 1)
        }
        return nil
    }
}
