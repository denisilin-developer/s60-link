import S60LinkCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct S60LinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("S60 Link") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.connected {
                NavigationSplitView {
                    List(Section.allCases, selection: $model.section) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(section)
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                } detail: {
                    switch model.section {
                    case .device: DeviceView()
                    case .messages: MessagesView()
                    case .files: FilesView()
                    case .install: InstallView()
                    case .screenshot: ScreenshotView()
                    }
                }
            } else {
                ConnectView()
            }
        }
        .alert("S60 Link", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("OK") { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
        .task {
            if !model.host.isEmpty { await model.connect() }
        }
    }
}

final class ConnectState: ObservableObject {
    @Published var address = ""
}

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = ConnectState()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen1.radiowaves.left.and.right")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("Connect your Nokia").font(.title2.bold())
            Text("Open S60 Link on the phone and join the same Wi-Fi network as this Mac.\nThe phone shows the address to type here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                TextField("192.168.1.23", text: $ui.address)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { Task { await model.connect(to: ui.address) } }
                Button("Connect") { Task { await model.connect(to: ui.address) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ui.address.trimmingCharacters(in: .whitespaces).isEmpty || model.link == .connecting)
            }
            Button {
                Task { await model.scan() }
            } label: {
                if model.scanning {
                    HStack { ProgressView().controlSize(.small); Text("Looking for the phone...") }
                } else {
                    Label("Find Phone on Wi-Fi", systemImage: "magnifyingglass")
                }
            }
            .disabled(model.scanning)
            if model.found.count > 1 {
                ForEach(model.found, id: \.self) { host in
                    Button("Connect to \(host)") { Task { await model.connect(to: host) } }
                }
            } else if let message = model.scanMessage, !model.scanning {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.orange).frame(maxWidth: 420)
            }
            switch model.link {
            case .connecting:
                ProgressView("Connecting...").controlSize(.small)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { ui.address = model.host }
    }
}

struct DeviceView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let info = model.info {
                SwiftUI.Section("Phone") {
                    LabeledContent("Model", value: modelName(info.model))
                    LabeledContent("Firmware", value: "\(info.firmware) (\(info.date))")
                    LabeledContent("Address", value: model.host)
                }
            }
            SwiftUI.Section("Storage") {
                ForEach(model.drives) { drive in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(drive.letter): \(drive.name.isEmpty ? driveName(drive) : drive.name)")
                            Spacer()
                            Text("\(bytes(drive.free)) free of \(bytes(drive.size))").foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(drive.size - drive.free), total: Double(max(drive.size, 1)))
                    }
                }
            }
            SwiftUI.Section {
                Button("Disconnect") { Task { await model.disconnect() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Phone")
    }

    func modelName(_ code: String) -> String {
        code == "RM-530" ? "Nokia E72 (RM-530)" : code
    }

    func driveName(_ drive: Drive) -> String {
        switch drive.letter {
        case "C": "Phone memory"
        case "E": "Memory card"
        case "Z": "Firmware (read-only)"
        default: "Drive"
        }
    }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

final class FilesState: ObservableObject {
    @Published var newFolder = ""
    @Published var askFolder = false
    @Published var renaming: Entry?
    @Published var newName = ""
    @Published var confirmDelete = false
    @Published var dropTarget = false
}

struct FilesView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = FilesState()

    var body: some View {
        VStack(spacing: 0) {
            Table(model.entries, selection: $model.selection) {
                TableColumn("Name") { entry in
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(systemName: entry.isFolder ? "folder.fill" : entry.isPackage ? "shippingbox" : "doc")
                            .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                    }
                }
                TableColumn("Size") { entry in
                    Text(entry.isFolder ? "--" : bytes(entry.size)).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Modified") { entry in
                    Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
                .width(min: 130, ideal: 160, max: 200)
            }
            .contextMenu(forSelectionType: Entry.ID.self) { ids in
                let items = model.entries.filter { ids.contains($0.id) }
                if items.count == 1, let item = items.first {
                    Button(item.isFolder ? "Open" : item.isPackage ? "Install on Phone" : "Download...") {
                        Task { await model.open(item) }
                    }
                    Button("Rename...") { ui.newName = item.name; ui.renaming = item }
                }
                if !items.isEmpty {
                    if items.contains(where: { !$0.isFolder }) {
                        Button("Download...") { Task { await model.download(items) } }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        model.selection = Set(ids)
                        ui.confirmDelete = true
                    }
                }
            } primaryAction: { ids in
                if let item = model.entries.first(where: { ids.contains($0.id) }) {
                    Task { await model.open(item) }
                }
            }
            .overlay {
                if model.loading && model.entries.isEmpty { ProgressView() }
                if ui.dropTarget {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $ui.dropTarget) { providers in
                Task {
                    var urls: [URL] = []
                    for p in providers {
                        if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                           let u = URL(dataRepresentation: url, relativeTo: nil) {
                            urls.append(u)
                        }
                    }
                    await model.upload(urls)
                }
                return true
            }
            TransferBar()
        }
        .navigationTitle(model.folder)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { Task { await model.up() } } label: { Label("Up", systemImage: "chevron.left") }
                    .disabled(PhonePath.parent(model.folder) == nil)
                Menu {
                    ForEach(model.drives) { drive in
                        Button("\(drive.letter):  \(drive.letter == "C" ? "Phone memory" : drive.letter == "E" ? "Memory card" : drive.name)") {
                            Task { await model.go(to: drive.root) }
                        }
                    }
                } label: {
                    Label("Drive", systemImage: "internaldrive")
                }
            }
            ToolbarItemGroup {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { ui.newFolder = ""; ui.askFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { Task { await model.chooseUpload() } } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                Button { Task { await model.download(model.selectedEntries) } } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.selectedEntries.contains { !$0.isFolder })
                Button(role: .destructive) { ui.confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
            }
        }
        .alert("New Folder", isPresented: $ui.askFolder) {
            TextField("Name", text: $ui.newFolder)
            Button("Create") { Task { await model.makeFolder(named: ui.newFolder) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
            TextField("Name", text: $ui.newName)
            Button("Rename") {
                if let item = ui.renaming { Task { await model.rename(item, to: ui.newName) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: $ui.confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(model.selectedEntries) } }
        } message: {
            Text("This permanently deletes it from the phone.")
        }
    }

    var deleteTitle: String {
        let items = model.selectedEntries
        return items.count == 1 ? "Delete \(items[0].name)?" : "Delete \(items.count) items?"
    }
}

struct TransferBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let text = model.transfer {
            HStack {
                Text(text).lineLimit(1)
                ProgressView(value: model.progress).frame(maxWidth: 220)
                Text("\(Int(model.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

final class DropState: ObservableObject {
    @Published var dropTarget = false
    @Published var busy = false
}

struct InstallView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = DropState()

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(.tint)
                Text("Drop .sis or .sisx files here").font(.title3.bold())
                Text("They're copied to \(model.installFolder) and the installer opens on the phone.")
                    .foregroundStyle(.secondary)
                Button("Choose Files...") { Task { await model.chooseInstall() } }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(ui.dropTarget ? 1 : 0.4)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ui.dropTarget ? Color.accentColor : .secondary.opacity(0.4),
                                                                      style: StrokeStyle(lineWidth: 2, dash: [6])))
            .onDrop(of: [.fileURL], isTargeted: $ui.dropTarget) { providers in
                Task {
                    var urls: [URL] = []
                    for p in providers {
                        if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                    }
                    await model.install(urls)
                }
                return true
            }
            if !model.installs.isEmpty {
                List(model.installs.reversed()) { item in
                    HStack {
                        Image(systemName: item.failed ? "xmark.octagon" : "checkmark.circle")
                            .foregroundStyle(item.failed ? .red : .green)
                        Text(item.name)
                        Spacer()
                        Text(item.status).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
        }
        .padding(20)
        .navigationTitle("Install Apps")
    }
}

struct ScreenshotView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = DropState()

    var body: some View {
        VStack(spacing: 16) {
            if let image = model.screenshot {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width * 2, maxHeight: image.size.height * 2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 4)
            } else {
                ContentUnavailableView("No Screenshot Yet", systemImage: "camera.viewfinder",
                                       description: Text("Captures exactly what's on the phone's screen right now."))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Screenshot")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    ui.busy = true
                    Task { await model.takeScreenshot(); ui.busy = false }
                } label: {
                    Label("Take Screenshot", systemImage: "camera")
                }
                .disabled(ui.busy)
                .keyboardShortcut("r", modifiers: .command)
                Button { model.copyScreenshot() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(model.screenshot == nil)
                Button { model.saveScreenshot() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(model.screenshot == nil)
            }
        }
    }
}
