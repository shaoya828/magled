import Foundation
// Hardware regression check: ACLC reads must supply their one-byte size.
do {
    let client = try SMC.Client()
    let info = try client.keyInfo("ACLC")
    precondition(info.size == 1, "Unexpected ACLC data size")
    let value = try client.readByte("ACLC")
    print("PASS: ACLC exists and reads successfully (value \(value))")
} catch {
    fatalError("ACLC read regression: \(error)")
}
