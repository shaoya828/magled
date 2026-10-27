import Foundation
// 只读集成检查：读取实际灯色不能改变守护保存的所选模式。
guard let before = LedSock.send("mode"), before.ok,
      let selected = UInt8(before.payload, radix: 16),
      let actual = LedSock.send("get"), actual.ok,
      let colour = UInt8(actual.payload, radix: 16),
      let after = LedSock.send("mode"), after.ok else {
    fatalError("需要运行支持 mode 命令的 magled-helper")
}
precondition(before.payload == after.payload, "读取灯色改变了所选模式")
print("PASS: 模式=\(LEDModeText.current(selected))，灯色=\(LEDModeText.colour(colour))，两者独立")
let started = Date()
for _ in 0..<4 {
    precondition(LedSock.send("ping")?.ok == true, "守护未响应")
}
let elapsed = Date().timeIntervalSince(started)
precondition(elapsed < 2, "连续请求存在固定等待：\(elapsed) 秒")
print(String(format: "PASS: 四次连续请求 %.3f 秒", elapsed))
