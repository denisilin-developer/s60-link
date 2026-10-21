import Foundation
import S60LinkCore

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "127.0.0.1"
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   " : "FAIL ", what)
    if !ok { failures += 1 }
}

let port = UInt16(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "5715") ?? 5715
let client = PhoneClient(host: host, port: port)
try await client.open()
let info = try await client.hello()
check(!info.model.isEmpty, "hello -> \(info.model) \(info.firmware)")

let drives = try await client.drives()
check(drives.contains { $0.letter == "E" }, "drives -> \(drives.map(\.letter))")

let folder = "E:\\S60LinkCheck"
try? await client.delete(folder)
try await client.makeFolder(folder)
check(try await client.list("E:\\").contains { $0.name == "S60LinkCheck" && $0.isFolder }, "mkdir + ls")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s60link-check")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let source = tmp.appendingPathComponent("blob.bin")
let blob = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
try blob.write(to: source)
let remote = PhonePath.join(folder, "blob.bin")
try await client.upload(source, to: remote)
let listed = try await client.list(folder)
check(listed.first?.size == Int64(blob.count), "upload size \(listed.first?.size ?? -1)")

let back = tmp.appendingPathComponent("back.bin")
try await client.download(remote, to: back)
check((try? Data(contentsOf: back)) == blob, "download round trip")

try await client.rename(remote, PhonePath.join(folder, "renamed.bin"))
check(try await client.list(folder).map(\.name) == ["renamed.bin"], "rename")

let shot = try await client.screenshot()
check(shot.prefix(2) == Data("BM".utf8) && shot.count > 54, "screenshot \(shot.count) bytes")

try await client.install(PhonePath.join(folder, "renamed.bin"))
check(true, "install request accepted")

do {
    _ = try await client.list("E:\\does-not-exist")
    check(false, "error for missing folder")
} catch {
    check(error is PhoneError, "error for missing folder -> \(error.localizedDescription)")
}
check(try await client.list(folder).count == 1, "connection still usable after an error")

try await client.delete(folder)
check(!(try await client.list("E:\\")).contains { $0.name == "S60LinkCheck" }, "delete folder")
check(PhonePath.parent("E:\\Images\\2024\\") == "E:\\Images\\" && PhonePath.parent("E:\\") == nil, "path helpers")

let texts = try await client.messages()
check(texts.contains { $0.body.contains("\n") } && texts.contains { $0.body.contains("\t") && $0.body.contains("\\") },
      "sms list keeps newlines, tabs and backslashes (\(texts.count) messages)")
let convs = SMS.group(texts)
check(convs.count == 3 && convs.first?.title == "Мама" && convs.first?.messages.count == 3, "sms grouped into conversations")
check(SMS.key("+38 (050) 111-22-33") == SMS.key("0501112233"), "phone numbers match across formats")
let unreadId = texts.first { $0.unread && !$0.outgoing }!.id
try await client.markRead(unreadId)
check(try await client.messages().first { $0.id == unreadId }?.unread == false, "mark as read")
try await client.sendText(to: "+380501112233", "Line one\nLine two \\ done")
let sent = try await client.messages().last!
check(sent.outgoing && sent.body == "Line one\nLine two \\ done", "send text round trip")
try await client.deleteMessage(sent.id)
check(!(try await client.messages()).contains { $0.id == sent.id }, "delete text")
check(SMS.parts("Hello").parts == 1 && SMS.parts(String(repeating: "a", count: 161)).parts == 2
      && SMS.parts("Привет").left == 64 && SMS.parts("{}").left == 156, "sms part counter")
check(SMS.unescape(SMS.escape("a\\n\tb\nc")) == "a\\n\tb\nc", "escape round trip")

let silent = try Socket.silentServer()
let mute = PhoneClient(host: "127.0.0.1", port: silent)
try await mute.open()
let started = Date()
do {
    _ = try await withTimeout(1, onTimeout: { await mute.close() }) { try await mute.hello() }
    check(false, "timeout on a silent phone")
} catch {
    check(Date().timeIntervalSince(started) < 3, "timeout on a silent phone (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
}

let slowTask = Task { try await client.messages() }
try await Task.sleep(for: .milliseconds(5))
slowTask.cancel()
_ = try? await slowTask.value
check((try? await client.request("PING")) != nil, "cancelling a screen's request keeps the connection")

await client.close()
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)

enum Socket {
    static func silentServer() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }
}
