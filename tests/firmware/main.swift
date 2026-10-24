import Foundation

let header = "HPM at RID 0x5 Route 0x0 Address 0x08 :\n"
// 实机 A2363 记录前 14 字节；后续无关字段不参与版本解析。
let prefix: [UInt8] = [0x54, 0xac, 0x05, 0, 0x1c, 0, 0, 0, 0, 0, 0x32, 0, 0x78, 0x40]
func record(_ bytes: [UInt8]) -> String {
    header + String(format: "0x49\t0x%02X\t0x", bytes.count) + bytes.map { String(format: "%02X", $0) }.joined()
}
func version(_ bytes: [UInt8]) -> String? { Fw.cableFirmware(from: record(bytes)).first?.value }
assert(version(prefix) == "3.2.0")
assert(Fw.cableFirmware(from: record(prefix), connected: false).isEmpty)
assert(Fw.cableFirmware(from: record(prefix), connected: true).first?.value == "3.2.0")
var old = prefix; old[9] = 0x12; old[10] = 0x31
assert(version(old) == "3.1.12")
var invalid = prefix; invalid[9] = 0xfa
assert(version(invalid) == nil)
var otherDevice = prefix; otherDevice[12] = 0x1e
assert(version(otherDevice) == nil)
assert(version(Array(repeating: 0, count: 61)) == nil)
assert(version(Array(prefix.prefix(10))) == nil)
assert(Fw.cableFirmware(from: record(prefix).replacingOccurrences(of: "0x0E", with: "0x3D")).isEmpty)
assert(Fw.cableFirmware(from: record(prefix).replacingOccurrences(of: "54AC", with: "ZZAC")).isEmpty)
assert(Fw.cableFirmware(from: "0x49\t0x0D\t0x54AC05001C000000000032007840").isEmpty)
assert(Fw.cableFirmware(from: record(otherDevice) + "\n" + record(old)).map(\.value) == ["3.1.12"])
print("PASS: 3200 / 3112、未知设备、空记录、截断及损坏记录")
if CommandLine.arguments.count > 1 {
    let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let found = Fw.cableFirmware(from: text)
    precondition(!found.isEmpty, "实机记录未识别到 A2363")
    found.forEach { print($0.text) }
}
