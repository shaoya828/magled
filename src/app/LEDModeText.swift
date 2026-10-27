import Foundation

// LEDModeText — human-readable labels (shared by the app; the CLI has its own copy).
enum LEDModeText {
    static func colour(_ value: UInt8?) -> String {
        switch value {
        case 0x01: return "关闭"
        case 0x03: return "绿色"
        case 0x04: return "橙色"
        default: return "未知"
        }
    }

    static func current(_ v: UInt8) -> String {
        switch v {
        case 0x00: return "跟随系统"
        case 0x01: return "已关闭"
        case 0x03: return "常亮绿"
        case 0x04: return "常亮橙"
        case 0x06: return "慢速闪烁"
        case 0x07: return "快速闪烁"
        case 0x19: return "闪烁后关闭"
        default: return "未知 0x\(String(format: "%02x", v))"
        }
    }
}
