import Foundation

public struct TextMessage: Identifiable, Hashable, Sendable {
    public let id: Int
    public let folder: String
    public let date: Date
    public var unread: Bool
    public let address: String
    public let name: String
    public let body: String
    public var outgoing: Bool { folder != "in" }
    public var pending: Bool { folder == "out" || folder == "draft" }
}

public struct Conversation: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let address: String
    public let messages: [TextMessage]
    public var last: TextMessage { messages[messages.count - 1] }
    public var unread: Int { messages.filter { $0.unread && !$0.outgoing }.count }
}

public enum SMS {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "")
    }

    public static func unescape(_ text: String) -> String {
        var out = ""
        var it = text.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else {
                out.append(c)
                continue
            }
            out.append(n == "n" ? "\n" : n == "t" ? "\t" : n)
        }
        return out
    }

    public static func key(_ address: String) -> String {
        let digits = address.filter(\.isNumber)
        if digits.count >= 9 { return String(digits.suffix(9)) }
        return address.lowercased().trimmingCharacters(in: .whitespaces)
    }

    public static func group(_ messages: [TextMessage]) -> [Conversation] {
        let byKey = Dictionary(grouping: messages) { key($0.address) }
        return byKey.map { key, items in
            let sorted = items.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
            let named = sorted.last { !$0.name.isEmpty && $0.name != $0.address }
            let address = sorted.last { $0.address.contains { $0.isNumber } }?.address ?? sorted.last!.address
            return Conversation(id: key, title: named?.name ?? address, address: address, messages: sorted)
        }
        .sorted { $0.last.date > $1.last.date }
    }

    private static let gsm7: Set<Character> = Set(
        "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
    private static let gsm7Extended: Set<Character> = Set("^{}\\[~]|€")

    public static func parts(_ text: String) -> (parts: Int, left: Int) {
        if text.isEmpty { return (0, 160) }
        var units = 0
        var unicode = false
        for c in text {
            if gsm7.contains(c) { units += 1 } else if gsm7Extended.contains(c) { units += 2 } else { unicode = true; break }
        }
        if unicode { units = text.utf16.count }
        let single = unicode ? 70 : 160
        let multi = unicode ? 67 : 153
        if units <= single { return (1, single - units) }
        let parts = (units + multi - 1) / multi
        return (parts, parts * multi - units)
    }
}

extension PhoneClient {
    public func messages() async throws -> [TextMessage] {
        let text = String(decoding: try await request("SMSLIST"), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 7, let id = Int(f[0]), let time = Double(f[2]) else { return nil }
            return TextMessage(id: id, folder: f[1], date: Date(timeIntervalSince1970: time), unread: f[3] == "1",
                               address: SMS.unescape(f[4]), name: SMS.unescape(f[5]), body: SMS.unescape(f[6]))
        }
    }

    public func sendText(to number: String, _ body: String) async throws {
        _ = try await request("SMSSEND", number.replacingOccurrences(of: "\t", with: ""), SMS.escape(body))
    }

    public func markRead(_ id: Int) async throws { _ = try await request("SMSREAD", String(id)) }
    public func deleteMessage(_ id: Int) async throws { _ = try await request("SMSDEL", String(id)) }
}
