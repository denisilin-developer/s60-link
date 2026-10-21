import AppKit
import S60LinkCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case device = "Phone"
    case messages = "Messages"
    case files = "Files"
    case install = "Install Apps"
    case screenshot = "Screenshot"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .device: "iphone.gen1"
        case .messages: "message"
        case .files: "folder"
        case .install: "square.and.arrow.down.on.square"
        case .screenshot: "camera.viewfinder"
        }
    }
}

struct InstallItem: Identifiable {
    let id = UUID()
    let name: String
    var status: String
    var failed = false
}

@MainActor
final class AppModel: ObservableObject {
    enum Link: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    @AppStorage("host") var host = ""
    @Published var link: Link = .disconnected
    @Published var scanning = false
    @Published var scanMessage: String?
    @Published var found: [String] = []
    @AppStorage("section") var savedSection: Section = .files
    @Published var section: Section = .files {
        didSet { savedSection = section }
    }

    @Published var info: DeviceInfo?
    @Published var drives: [Drive] = []
    @Published var folder = "E:\\"
    @Published var entries: [Entry] = []
    @Published var selection = Set<Entry.ID>()
    @Published var loading = false

    @Published var transfer: String?
    @Published var progress: Double = 0
    @Published var errorText: String?

    @Published var installs: [InstallItem] = []
    @Published var conversations: [Conversation] = []
    @AppStorage("conversation") var savedConversation = ""
    @Published var openConversation: Conversation.ID? {
        didSet { savedConversation = openConversation ?? "" }
    }
    @Published var messagesLoaded = false
    @Published var sending = false
    @Published var screenshot: NSImage?
    @Published var screenshotData: Data?

    private var client: PhoneClient?
    private var keepAlive: Task<Void, Never>?

    init() {
        section = savedSection
        openConversation = savedConversation.isEmpty ? nil : savedConversation
    }

    var connected: Bool { link == .connected }

    func connect(to address: String? = nil) async {
        let target = (address ?? host).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        let parts = target.split(separator: ":")
        let name = String(parts.first ?? "")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 5715 : 5715
        link = .connecting
        let candidate = PhoneClient(host: name, port: port)
        do {
            try await candidate.open()
            info = try await withTimeout(6, onTimeout: { await candidate.close() }) { try await candidate.hello() }
            client = candidate
            host = target
            drives = try await candidate.drives()
            link = .connected
            startKeepAlive()
            folder = drives.contains { $0.letter == "E" } ? "E:\\" : "C:\\"
            await refresh()
        } catch {
            await candidate.close()
            link = .failed(error.localizedDescription)
        }
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let client = self.client, !Task.isCancelled else { return }
                guard await client.idleSeconds >= 30 else { continue }
                do {
                    _ = try await withTimeout(45, onTimeout: { await client.close() }) { try await client.request("PING") }
                } catch {
                    await self.disconnect()
                    self.link = .failed("Lost connection to the phone")
                    return
                }
            }
        }
    }

    func disconnect() async {
        keepAlive?.cancel()
        keepAlive = nil
        await client?.close()
        client = nil
        info = nil
        drives = []
        conversations = []
        messagesLoaded = false
        entries = []
        link = .disconnected
    }

    func scan() async {
        scanning = true
        scanMessage = nil
        found = await PhoneScanner.find()
        scanning = false
        if found.count == 1 {
            await connect(to: found[0])
        } else if found.isEmpty {
            scanMessage = "No phone found. Check that S60 Link is open on the phone and shows an address, and that the Mac is on the same Wi-Fi."
        }
    }

    private func run(_ what: String, _ body: (PhoneClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await body(client)
        } catch {
            errorText = "\(what): \(error.localizedDescription)"
            if error is PhoneError == false {
                await disconnect()
                link = .failed("Lost connection to the phone")
            }
        }
    }

    func refresh() async {
        loading = true
        await run("Could not open \(folder)") { client in
            entries = try await client.list(folder)
            drives = try await client.drives()
        }
        selection = selection.filter { id in entries.contains { $0.id == id } }
        loading = false
    }

    func open(_ entry: Entry) async {
        if entry.isFolder {
            folder = PhonePath.join(folder, entry.name) + "\\"
            selection = []
            await refresh()
        } else if entry.isPackage {
            await installRemote(PhonePath.join(folder, entry.name), name: entry.name)
        } else {
            await download([entry])
        }
    }

    func go(to path: String) async {
        folder = path
        selection = []
        await refresh()
    }

    func up() async {
        if let parent = PhonePath.parent(folder) { await go(to: parent) }
    }

    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }

    func makeFolder(named name: String) async {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        await run("Could not create \(clean)") { try await $0.makeFolder(PhonePath.join(folder, clean)) }
        await refresh()
    }

    func rename(_ entry: Entry, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != entry.name else { return }
        await run("Could not rename \(entry.name)") {
            try await $0.rename(PhonePath.join(folder, entry.name), PhonePath.join(folder, clean))
        }
        await refresh()
    }

    func delete(_ items: [Entry]) async {
        for item in items {
            await run("Could not delete \(item.name)") { try await $0.delete(PhonePath.join(folder, item.name)) }
        }
        selection = []
        await refresh()
    }

    func download(_ items: [Entry]) async {
        let files = items.filter { !$0.isFolder }
        guard !files.isEmpty else {
            errorText = "Folders can't be downloaded yet. Open the folder and select the files."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save \(files.count == 1 ? files[0].name : "\(files.count) files")"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var saved: [URL] = []
        for file in files {
            let url = dest.appendingPathComponent(file.name)
            transfer = "Downloading \(file.name)"
            progress = 0
            await run("Could not download \(file.name)") { client in
                try await client.download(PhonePath.join(folder, file.name), to: url) { p in
                    Task { @MainActor in self.progress = p }
                }
                saved.append(url)
            }
        }
        transfer = nil
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    func upload(_ urls: [URL], into target: String? = nil) async {
        let dest = target ?? folder
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                errorText = "Folders can't be uploaded yet: \(url.lastPathComponent)"
                continue
            }
            transfer = "Uploading \(url.lastPathComponent)"
            progress = 0
            await run("Could not upload \(url.lastPathComponent)") { client in
                try await client.upload(url, to: PhonePath.join(dest, url.lastPathComponent)) { p in
                    Task { @MainActor in self.progress = p }
                }
            }
        }
        transfer = nil
        if dest == folder { await refresh() }
    }

    func chooseUpload() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        panel.message = "Choose files to copy to \(folder)"
        guard panel.runModal() == .OK else { return }
        await upload(panel.urls)
    }

    var installFolder: String {
        drives.contains { $0.letter == "E" } ? "E:\\Others\\S60Link\\" : "C:\\Data\\Others\\S60Link\\"
    }

    func install(_ urls: [URL]) async {
        let packages = urls.filter { ["sis", "sisx"].contains($0.pathExtension.lowercased()) }
        if packages.count < urls.count { errorText = "Only .sis and .sisx files can be installed." }
        guard !packages.isEmpty, let client else { return }
        try? await client.makeFolder(installFolder)
        for url in packages {
            let index = installs.count
            installs.append(InstallItem(name: url.lastPathComponent, status: "Copying to the phone..."))
            let remote = PhonePath.join(installFolder, url.lastPathComponent)
            do {
                try await client.upload(url, to: remote) { p in
                    Task { @MainActor in self.installs[index].status = "Copying to the phone... \(Int(p * 100))%" }
                }
                try await client.install(remote)
                installs[index].status = "Confirm the installation on the phone"
            } catch {
                installs[index].status = error.localizedDescription
                installs[index].failed = true
            }
        }
    }

    func installRemote(_ path: String, name: String) async {
        installs.append(InstallItem(name: name, status: "Confirm the installation on the phone"))
        let index = installs.count - 1
        await run("Could not install \(name)") { try await $0.install(path) }
        if errorText != nil { installs[index].failed = true }
    }

    func chooseInstall() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "sis")!, .init(filenameExtension: "sisx")!]
        panel.prompt = "Install"
        guard panel.runModal() == .OK else { return }
        await install(panel.urls)
    }

    func loadMessages() async {
        await run("Could not read messages") { client in
            conversations = SMS.group(try await client.messages())
            messagesLoaded = true
        }
    }

    func markConversationRead(_ id: Conversation.ID) async {
        guard let conv = conversations.first(where: { $0.id == id }), conv.unread > 0 else { return }
        await run("Could not mark as read") { client in
            for m in conv.messages where m.unread && !m.outgoing { try await client.markRead(m.id) }
        }
        await loadMessages()
    }

    func sendText(to number: String, _ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = number.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !to.isEmpty else { return false }
        sending = true
        defer { sending = false }
        var ok = false
        await run("Could not send the text") { client in
            try await client.sendText(to: to, text)
            ok = true
        }
        try? await Task.sleep(for: .seconds(1))
        await loadMessages()
        if ok { openConversation = SMS.key(to) }
        return ok
    }

    func deleteText(_ message: TextMessage) async {
        await run("Could not delete the message") { try await $0.deleteMessage(message.id) }
        await loadMessages()
    }

    func takeScreenshot() async {
        await run("Could not take a screenshot") { client in
            let data = try await client.screenshot()
            screenshotData = data
            screenshot = NSImage(data: data)
        }
    }

    func saveScreenshot() {
        guard let image = screenshot, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        panel.nameFieldStringValue = "E72 \(stamp.replacingOccurrences(of: ":", with: "-")).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    func copyScreenshot() {
        guard let image = screenshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
