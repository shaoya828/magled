import Foundation
import IOKit

// SMC.swift — minimal AppleSMC client (IOKit).
// Struct layout mirrors the kernel's SMCParamStruct (80 bytes).
// Adapted from MagSleep (github.com/realAbitbol/MagSleep, MIT License) —
// added readByte(); verified against macOS Apple Silicon.

public enum SMC {
    public enum SMCError: Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case smcResult(UInt8)
        case unexpectedLayout(Int)
        case invalidKey(String)

        public var description: String {
            switch self {
            case .serviceNotFound: return "AppleSMC service not found"
            case .openFailed(let kr): return "IOServiceOpen failed (0x\(String(kr, radix: 16)))"
            case .callFailed(let kr): return "IOConnectCallStructMethod failed (0x\(String(kr, radix: 16)))"
            case .smcResult(let r):
                return r == 0x84
                    ? "SMC key not found"
                    : r == 0x53
                    ? "SMC denied access (write likely requires root)"
                    : "SMC returned error 0x\(String(r, radix: 16))"
            case .unexpectedLayout(let size): return "SMCParamStruct has unexpected size \(size)"
            case .invalidKey(let key): return "SMC key '\(key)' is not exactly 4 characters"
            }
        }
    }

    struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    static let kSMCHandleYPCEvent: UInt32 = 2
    static let kSMCReadKey: UInt8 = 5
    static let kSMCWriteKey: UInt8 = 6
    static let kSMCGetKeyInfo: UInt8 = 9

    public static func fourCC(_ code: String) throws -> UInt32 {
        guard code.utf8.count == 4 else { throw SMCError.invalidKey(code) }
        return code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public final class Client {
        var connection: io_connect_t
        var service: io_service_t

        public init() throws {
            guard MemoryLayout<SMCParamStruct>.stride == 80 else {
                throw SMCError.unexpectedLayout(MemoryLayout<SMCParamStruct>.stride)
            }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { throw SMCError.serviceNotFound }
            var conn: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
            guard kr == kIOReturnSuccess else {
                IOObjectRelease(service)
                throw SMCError.openFailed(kr)
            }
            self.connection = conn
            self.service = service
        }

        deinit {
            if connection != 0 { IOServiceClose(connection) }
            IOObjectRelease(service)
        }

        /// Raw pass-through (used for SMC key enumeration via the #KEY/KKEY index trick).
        func rawCall(_ input: SMCParamStruct) throws -> SMCParamStruct {
            try call(input)
        }

        private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
            var input = input
            var output = SMCParamStruct()
            var outputSize = MemoryLayout<SMCParamStruct>.stride
            let kr = IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                               &input, MemoryLayout<SMCParamStruct>.stride,
                                               &output, &outputSize)
            guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
            guard output.result == 0 else { throw SMCError.smcResult(output.result) }
            return output
        }

        /// Key info: (dataSize, 4cc type). Throws SMCError.smcResult(0x84) when the key does not exist.
        public func keyInfo(_ key: String) throws -> (size: UInt32, type: String) {
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCGetKeyInfo
            let reply = try call(request)
            let t = reply.keyInfo.dataType
            let type = String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff),
                                      UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], encoding: .ascii) ?? "????"
            return (reply.keyInfo.dataSize, type)
        }

        public func readByte(_ key: String) throws -> UInt8 {
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCReadKey
            request.keyInfo.dataSize = 1
            let reply = try call(request)
            return reply.bytes.0
        }

        /// Reads raw key bytes (READ-ONLY). Returns up to `count` bytes (max 32).
        public func readRaw(_ key: String, _ count: Int) throws -> Data {
            let n = max(0, min(count, 32))
            guard n > 0 else { return Data() }
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCReadKey
            request.keyInfo.dataSize = UInt32(n)
            let reply = try call(request)
            var data = Data()
            withUnsafeBytes(of: reply.bytes) { data.append(contentsOf: $0.prefix(n)) }
            return data
        }

        /// Writes a single-byte SMC key. On Apple Silicon this requires root.
        public func writeByte(_ key: String, _ value: UInt8) throws {
            let info = try keyInfo(key)
            var request = SMCParamStruct()
            request.key = try fourCC(key)
            request.data8 = kSMCWriteKey
            request.keyInfo.dataSize = info.size
            request.bytes.0 = value
            _ = try call(request)
        }
    }

    // One-shot convenience API.
    private static func withConnection<T>(_ body: (Client) throws -> T) throws -> T {
        let client = try Client()
        return try body(client)
    }

    public static func keyInfo(_ key: String) throws -> (size: UInt32, type: String) {
        try withConnection { try $0.keyInfo(key) }
    }
    public static func readByte(_ key: String) throws -> UInt8 {
        try withConnection { try $0.readByte(key) }
    }
    public static func writeByte(_ key: String, _ value: UInt8) throws {
        try withConnection { try $0.writeByte(key, value) }
    }

    // MagSafe 3 LED control key (Apple Silicon, MagSafe 3-equipped Macs).
    //   0x00 = system-controlled (default: amber while charging, green when full)
    //   0x01 = off
    //   0x03 = always green
    //   0x04 = always amber
    //   0x06 = slow blink
    //   0x07 = fast blink
    //   0x19 (25) = blink then off
    public static let magSafeLEDKey = "ACLC"

    public static func isLEDKeySupported() -> Bool {
        (try? keyInfo(magSafeLEDKey)) != nil
    }
}
