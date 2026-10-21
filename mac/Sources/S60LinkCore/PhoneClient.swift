import Foundation
import Network

public struct PhoneError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Drive: Identifiable, Hashable, Sendable {
    public let letter: String
    public let free: Int64
    public let size: Int64
    public let name: String
    public let readOnly: Bool
    public var id: String { letter }
    public var root: String { letter + ":\\" }
}

public struct Entry: Identifiable, Hashable, Sendable {
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let modified: Date
    public var id: String { name }
    public var isPackage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "sis" || ext == "sisx"
    }
}

public struct DeviceInfo: Sendable {
    public let firmware: String
    public let date: String
    public let model: String
}

public enum PhonePath {
    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("\\") ? folder + name : folder + "\\" + name
    }

    public static func parent(_ path: String) -> String? {
        var p = path
        if p.hasSuffix("\\") { p.removeLast() }
        guard let cut = p.lastIndex(of: "\\") else { return nil }
        return String(p[...cut])
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

public actor PhoneClient {
    public nonisolated let host: String
    private nonisolated let connection: NWConnection
    private let queue = DispatchQueue(label: "s60link.client")
    private var buffer = Data()
    private var busy = false
    private var lastActivity = Date()

    public var idleSeconds: TimeInterval {
        busy || !waiters.isEmpty ? 0 : Date().timeIntervalSince(lastActivity)
    }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(host: String, port: UInt16 = 5715) {
        self.host = host
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    public func open(timeout: TimeInterval = 4) async throws {
        let once = ResumeOnce()
        let connection = self.connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                case .waiting(let error):
                    if once.claim() {
                        connection.cancel()
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: PhoneError("Connection cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    connection.cancel()
                    cont.resume(throwing: PhoneError("The phone did not answer"))
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }


    private func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func unlock() {
        lastActivity = Date()
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func send(_ data: Data) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receiveMore() async throws {
        let connection = self.connection
        let data: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: PhoneError("The phone closed the connection"))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        buffer.append(data)
    }

    private func readLine() async throws -> String {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            try await receiveMore()
        }
    }

    private func readBody(_ count: Int, into sink: (Data) throws -> Void, progress: ((Double) -> Void)?) async throws {
        var left = count
        while left > 0 {
            if buffer.isEmpty { try await receiveMore() }
            let take = min(left, buffer.count)
            try sink(buffer.prefix(take))
            buffer.removeFirst(take)
            left -= take
            progress?(Double(count - left) / Double(max(count, 1)))
        }
    }

    private func readHeader() async throws -> Int {
        let head = try await readLine()
        if head.hasPrefix("ERR\t") { throw PhoneError(String(head.dropFirst(4))) }
        guard head.hasPrefix("OK\t"), let n = Int(head.dropFirst(3)), n >= 0 else {
            throw PhoneError("Unexpected answer from the phone")
        }
        return n
    }

    private func command(_ parts: [String]) -> Data {
        Data((parts.joined(separator: "\t") + "\n").utf8)
    }

    public func request(_ parts: String...) async throws -> Data {
        await lock()
        defer { unlock() }
        try await send(command(parts))
        let n = try await readHeader()
        var out = Data()
        try await readBody(n, into: { out.append($0) }, progress: nil)
        return out
    }


    public func hello() async throws -> DeviceInfo {
        let text = String(decoding: try await request("HELLO"), as: UTF8.self)
        let fields = text.components(separatedBy: "\t")
        guard fields.first == "S60Link" else { throw PhoneError("This is not S60 Link") }
        let sw = (fields.count > 2 ? fields[2] : "").components(separatedBy: "|")
        func at(_ i: Int) -> String { i < sw.count ? sw[i].trimmingCharacters(in: .whitespaces) : "" }
        return DeviceInfo(firmware: at(0), date: at(1), model: at(2))
    }

    public func drives() async throws -> [Drive] {
        lines(try await request("DRIVES")).compactMap { f in
            guard f.count >= 5, let free = Int64(f[1]), let size = Int64(f[2]) else { return nil }
            return Drive(letter: f[0], free: free, size: size, name: f[3], readOnly: f[4] == "1")
        }
    }

    public func list(_ folder: String) async throws -> [Entry] {
        lines(try await request("LS", folder)).compactMap { f in
            guard f.count >= 4, let size = Int64(f[1]), let time = Double(f[2]) else { return nil }
            return Entry(name: f[3], isFolder: f[0] == "d", size: size, modified: Date(timeIntervalSince1970: time))
        }
    }

    public func makeFolder(_ path: String) async throws { _ = try await request("MKDIR", path) }
    public func delete(_ path: String) async throws { _ = try await request("DEL", path) }
    public func rename(_ from: String, _ to: String) async throws { _ = try await request("REN", from, to) }
    public func install(_ path: String) async throws { _ = try await request("INSTALL", path) }
    public func screenshot() async throws -> Data { try await request("SHOT") }

    public func download(_ path: String, to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        await lock()
        defer { unlock() }
        try await send(command(["GET", path]))
        let n = try await readHeader()
        let part = url.appendingPathExtension("part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        do {
            try await readBody(n, into: { try handle.write(contentsOf: $0) }, progress: progress)
            try handle.close()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: part, to: url)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    public func upload(_ url: URL, to path: String, progress: ((Double) -> Void)? = nil) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        await lock()
        defer { unlock() }
        try await send(command(["PUT", path, String(size)]))
        var sent = 0
        while sent < size {
            let chunk = try handle.read(upToCount: min(65536, size - sent)) ?? Data()
            if chunk.isEmpty { throw PhoneError("Could not read \(url.lastPathComponent)") }
            try await send(chunk)
            sent += chunk.count
            progress?(Double(sent) / Double(max(size, 1)))
        }
        _ = try await readHeader()
    }

    private func lines(_ data: Data) -> [[String]] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: "\t") }
    }
}
