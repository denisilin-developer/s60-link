import S60LinkCore
import SwiftUI

final class ComposeState: ObservableObject {
    @Published var draft = ""
    @Published var newNumber = ""
    @Published var newText = ""
    @Published var composing = false
}

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = ComposeState()

    var body: some View {
        HSplitView {
            List(model.conversations, selection: $model.openConversation) { conv in
                ConversationRow(conv: conv).tag(conv.id)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            .overlay {
                if !model.messagesLoaded {
                    ProgressView()
                } else if model.conversations.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "message")
                }
            }
            Group {
                if let conv = model.conversations.first(where: { $0.id == model.openConversation }) {
                    ChatView(conv: conv, ui: ui)
                } else {
                    ContentUnavailableView("Choose a Conversation", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Or start a new one with the compose button."))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Messages")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.loadMessages() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { ui.newNumber = ""; ui.newText = ""; ui.composing = true } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $ui.composing) { NewMessageSheet(ui: ui) }
        .task {
            await model.loadMessages()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if !model.sending { await model.loadMessages() }
            }
        }
        .onChange(of: model.openConversation) { _, id in
            ui.draft = ""
            if let id { Task { await model.markConversationRead(id) } }
        }
    }
}

struct ConversationRow: View {
    let conv: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(conv.unread > 0 ? Color.accentColor : .clear).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conv.title).fontWeight(conv.unread > 0 ? .semibold : .regular).lineLimit(1)
                    Spacer()
                    Text(shortDate(conv.last.date)).font(.caption).foregroundStyle(.secondary)
                }
                Text((conv.last.outgoing ? "You: " : "") + conv.last.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

func shortDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(.dateTime.day().month(.abbreviated).year())
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let conv: Conversation
    @ObservedObject var ui: ComposeState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(conv.title).font(.headline)
                    if conv.title != conv.address { Text(conv.address).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(conv.messages.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || !Calendar.current.isDate(m.date, inSameDayAs: conv.messages[i - 1].date) {
                                Text(m.date.formatted(date: .complete, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            }
                            Bubble(message: m).id(m.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(conv.last.id, anchor: .bottom) }
                .onChange(of: conv.messages.count) { _, _ in proxy.scrollTo(conv.last.id, anchor: .bottom) }
            }
            Divider()
            ComposeBar(text: $ui.draft, sending: model.sending) {
                let text = ui.draft
                Task { if await model.sendText(to: conv.address, text) { ui.draft = "" } }
            }
        }
    }
}

struct Bubble: View {
    @EnvironmentObject var model: AppModel
    let message: TextMessage

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 60) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(message.outgoing ? Color.accentColor : Color.gray.opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(message.outgoing ? .white : .primary)
                Text(message.date.formatted(date: .omitted, time: .shortened) + (message.pending ? " · not sent yet" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
                Button("Delete from Phone", role: .destructive) { Task { await model.deleteText(message) } }
            }
            if !message.outgoing { Spacer(minLength: 60) }
        }
    }
}

struct ComposeBar: View {
    @Binding var text: String
    let sending: Bool
    let send: () -> Void

    var body: some View {
        let count = SMS.parts(text)
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Text Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.4)))
                .onSubmit(send)
            VStack(spacing: 2) {
                if !text.isEmpty {
                    Text(count.parts > 1 ? "\(count.left)/\(count.parts)" : "\(count.left)")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                Button(action: send) {
                    if sending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
    }
}

struct NewMessageSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ui: ComposeState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message").font(.headline)
            TextField("Phone number, e.g. +380501234567", text: $ui.newNumber)
                .textFieldStyle(.roundedBorder)
            ComposeBar(text: $ui.newText, sending: model.sending) {
                let number = ui.newNumber, text = ui.newText
                Task { if await model.sendText(to: number, text) { ui.composing = false } }
            }
            HStack {
                Spacer()
                Button("Cancel") { ui.composing = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
