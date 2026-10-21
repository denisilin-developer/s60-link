import Foundation
import Network

public func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: @escaping @Sendable () async -> Void,
                                      _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            await onTimeout()
            throw PhoneError("The phone did not answer")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

public enum PhoneScanner {
    public static func localSubnets() -> [(address: UInt32, mask: UInt32)] {
        var result: [(UInt32, UInt32)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append((a, m))
        }
        return result
    }

    static func dotted(_ v: UInt32) -> String {
        "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }

    public static func candidates() -> [String] {
        let own = Set(localSubnets().map(\.address))
        var hosts: [String] = []
        var seen = Set<UInt32>()
        for (address, mask) in localSubnets() {
            let wide = max(mask, 0xFFFF_FF00)
            let net = address & wide
            for i in 1..<255 {
                let host = net | UInt32(i)
                if !own.contains(host), seen.insert(host).inserted { hosts.append(dotted(host)) }
            }
        }
        return hosts
    }

    public static func find(port: UInt16 = 5715) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for host in candidates() {
                group.addTask {
                    let client = PhoneClient(host: host, port: port)
                    defer { Task { await client.close() } }
                    do {
                        try await client.open(timeout: 2.5)
                        _ = try await withTimeout(4, onTimeout: { await client.close() }) { try await client.hello() }
                        return host
                    } catch {
                        return nil
                    }
                }
            }
            var found: [String] = []
            for await host in group {
                if let host { found.append(host) }
            }
            return found
        }
    }
}
