// Fw.swift — 通用 SMC / 机器身份助手（只读）。
//
// 2026-10-24：线缆/电源口固件读取功能已移除（MagLED 不再展示固件版本）。
// 本文件保留通用助手，供 probe 工具（keys 模式：SMC 全键枚举）使用：
//   fmt()            属性字典 → 文本行
//   hostMachine()    机器型号 + 系统版本
//   KeyEntry / candidateKeys / allSMCKeys()   SMC 全键枚举（#KEY 索引法）
import Foundation
import IOKit

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

}