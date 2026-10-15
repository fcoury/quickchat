import SwiftUI
import AppKit
import ImageIO
import QuickChatCore

enum Theme {
    static let background = Color(red: 0.081, green: 0.091, blue: 0.090)
    static let surface = Color(red: 0.135, green: 0.146, blue: 0.145)
    static let border = Color.white.opacity(0.10)
    static let muted = Color.white.opacity(0.48)
}

@MainActor final class WindowState: ObservableObject {
    @Published var historyVisible = false
    @Published var settingsVisible = false
    var toggleHistory: (() -> Void)?
    var dismiss: (() -> Void)?
}

struct RootView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var auth: AuthService
    @ObservedObject var window: WindowState
    @ObservedObject var hotkey: GlobalShortcut
    var body: some View {
        HStack(spacing: 0) {
            if window.historyVisible {
                HistoryView(store: store, window: window).frame(width: 222)
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Theme.border).frame(height: 1)
                if store.current?.messages.isEmpty != false {
                    welcome
                } else { TranscriptView(store: store, auth: auth) }
                if let error = store.error ?? auth.error ?? hotkey.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { store.error = nil; auth.error = nil; hotkey.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss message")
                    }.padding(12).background(.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 18).padding(.bottom, 10)
                }
                composer
                footer
            }.frame(minWidth: 560)
        }
        .foregroundStyle(Color.white.opacity(0.92)).background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Theme.border, lineWidth: 1))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $window.settingsVisible) { SettingsView(auth: auth, store: store, hotkey: hotkey) }
        .alert("You’re using your ChatGPT plan", isPresented: $auth.showPlanWelcome) {
            Button("Got it") { UserDefaults.standard.set(true, forKey: "planWelcomeShown") }
        } message: { Text("Eligible requests in QuickChat use your ChatGPT plan or available credits. You can manage app usage in ChatGPT settings.") }
        .task { await store.load(); await store.refreshModels(auth: auth) }
        .onChange(of: "\(auth.vault.activeID ?? ""):\(auth.connected)") { _, _ in
            if auth.connected { Task { await store.refreshModels(auth: auth) } } else { store.models = []; store.stop() }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 15) {
            if !window.historyVisible { IconButton("sidebar.left", help: "History (⌘B)") { window.toggleHistory?() } }
            Menu {
                if store.models.isEmpty { Text(auth.connected ? "Loading available models…" : "Sign in to see available models") }
                ForEach(store.models) { model in
                    Button { store.setModel(model.slug) } label: {
                        if model.slug == store.current?.model { Label(model.display_name, systemImage: "checkmark") } else { Text(model.display_name) }
                    }
                }
                Divider()
                Button("Refresh models") { Task { await store.refreshModels(auth: auth) } }.disabled(!auth.connected)
            } label: {
                HStack(spacing: 8) { Text(store.loadingModels ? "Loading models…" : store.selectedModelName).font(.system(size: 14, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted) }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(store.busy)
            Spacer()
            IconButton("square.and.pencil", help: "New chat (⌘N)") { store.newChat() }
            IconButton("gearshape", help: "Settings (⌘,)") { window.settingsVisible = true }
        }.padding(.horizontal, 22).frame(height: 52)
    }
    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Theme.muted)
            Text("A quick question. A clearer thought.").font(.system(size: 20, weight: .medium))
            Text("Ask anything, rewrite some text, or paste a screenshot.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            if !auth.connected && !store.demo {
                Button(auth.signingIn ? "Waiting for your browser…" : "Continue with ChatGPT") { auth.signIn(account: auth.active ?? auth.vault.accounts.first) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.large).disabled(auth.signingIn)
                if auth.signingIn { Button("Cancel sign-in") { auth.cancelSignIn() }.buttonStyle(.plain).foregroundStyle(Theme.muted) }
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachments = store.current?.draftAttachments, !attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentThumbnail(attachment: attachment, history: store.history).frame(width: 64, height: 48)
                            .overlay(alignment: .topTrailing) {
                                Button { store.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black) }.buttonStyle(.plain).offset(x: 5, y: -5).help("Remove screenshot")
                            }
                    }
                }.padding(.top, 2)
            }
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if store.current?.draft.isEmpty != false { Text("Ask anything, or paste a screenshot…").foregroundStyle(Theme.muted).font(.system(size: 15)).padding(.top, 4).allowsHitTesting(false) }
                    ComposerEditor(text: Binding(get: { store.current?.draft ?? "" }, set: store.setDraft), focus: store.focusRequest,
                        onSend: { store.send(auth: auth) }, onImage: store.attach, onPasteError: { store.error = $0 })
                }.frame(height: composerHeight)
                Button { if store.busy { store.stop() } else { store.send(auth: auth) } } label: {
                    Image(systemName: store.busy ? "stop.fill" : "arrow.up").font(.system(size: store.busy ? 13 : 18, weight: .semibold))
                        .foregroundStyle(Theme.background).frame(width: 32, height: 32).background(.white.opacity(canSend || store.busy ? 0.94 : 0.32)).clipShape(Circle())
                }.buttonStyle(.plain).disabled(!canSend && !store.busy).help(store.busy ? "Stop response" : "Send (Return)").accessibilityLabel(store.busy ? "Stop response" : "Send message")
            }
        }.padding(15).background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1)).padding(.horizontal, 18)
    }
    private var canSend: Bool { (!((store.current?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !(store.current?.draftAttachments.isEmpty ?? true)) && (auth.connected || store.demo) && !store.models.isEmpty }
    private var composerHeight: CGFloat { min(132, max(46, CGFloat((store.current?.draft.components(separatedBy: "\n").count ?? 1) * 20 + 8))) }
    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(store.demo ? Color.orange : (auth.connected ? Color.green : Theme.muted)).frame(width: 6, height: 6)
            Button { window.settingsVisible = true } label: { Text(store.demo ? "Preview · no network" : auth.connected ? "Using ChatGPT plan" : "Connect ChatGPT") }.buttonStyle(.plain)
            Menu {
                Button { store.setSearch(true) } label: { Label("Auto", systemImage: store.current?.searchEnabled == true ? "checkmark" : "globe") }
                Button { store.setSearch(false) } label: { Label("Off", systemImage: store.current?.searchEnabled == false ? "checkmark" : "minus") }
            } label: { Label(store.current?.searchEnabled == true ? "Auto" : "Off", systemImage: "globe") }
                .menuStyle(.borderlessButton).fixedSize().help("Web search").disabled(store.busy)
            Spacer(minLength: 4)
            Text("⌘N").font(.system(size: 10, design: .monospaced)).padding(.horizontal, 4).padding(.vertical, 2).background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 3))
            Text("New chat")
            Text("esc").font(.system(size: 10, design: .monospaced)).padding(.horizontal, 4).padding(.vertical, 2).background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 3))
            Text("Close")
        }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.horizontal, 23).frame(height: 38)
    }
}

struct HistoryView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var window: WindowState
    @State private var query = ""
    @State private var deleting: Conversation?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("History").font(.system(size: 14, weight: .medium)); Spacer(); IconButton("sidebar.left", help: "Hide history (⌘B)") { window.toggleHistory?() } }.padding(.horizontal, 18).frame(height: 52)
            HStack { Image(systemName: "magnifyingglass"); TextField("Search chats", text: $query).textFieldStyle(.plain) }
                .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(9).background(Theme.surface.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 12).padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(groups, id: \.0) { group in
                        Text(group.0).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 18).padding(.bottom, 5).padding(.leading, 10)
                        ForEach(group.1) { chat in
                            Button { store.select(chat.id) } label: {
                                HStack { Text(chat.title).lineLimit(1); Spacer(minLength: 0); if store.runningID == chat.id { ProgressView().controlSize(.mini) } }
                                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                                    .background(store.selectedID == chat.id ? Theme.surface : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).contextMenu { Button("Delete chat", role: .destructive) { deleting = chat }.disabled(store.runningID == chat.id) }
                        }
                    }
                    if groups.isEmpty { Text("No matching chats").font(.system(size: 12)).foregroundStyle(Theme.muted).padding() }
                }.padding(.horizontal, 10)
            }
            Button { store.newChat() } label: { Label("New chat", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 10).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border)) }.buttonStyle(.plain).padding(14)
        }.background(.black.opacity(0.06))
            .alert("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) { if let deleting { store.delete(deleting.id) }; deleting = nil }
            } message: { Text("The conversation and its screenshots will be removed from this Mac.") }
    }
    private var groups: [(String, [Conversation])] {
        let filtered = store.chats.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(query) } }.sorted { $0.updatedAt > $1.updatedAt }
        let calendar = Calendar.current
        let today = filtered.filter { calendar.isDateInToday($0.updatedAt) }
        let yesterday = filtered.filter { calendar.isDateInYesterday($0.updatedAt) }
        let earlier = filtered.filter { !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt) }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.1.isEmpty }
    }
}

struct TranscriptView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var auth: AuthService
    @State private var atBottom = true
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(store.current?.messages ?? []) { message in
                        MessageView(message: message, history: store.history, canRetry: message.id == store.current?.messages.last?.id && !store.busy,
                            searching: store.searching && store.runningID == store.selectedID) { store.retry(auth: auth) }
                    }
                    Color.clear.frame(height: 1).id("bottom").onAppear { atBottom = true }.onDisappear { atBottom = false }
                }.padding(26)
            }.onChange(of: store.current?.messages.last?.text) { _, _ in if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: store.current?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.selectedID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct MessageView: View {
    let message: Message
    let history: HistoryStore
    let canRetry: Bool
    let searching: Bool
    var retry: () -> Void
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 12) {
                if !message.attachments.isEmpty {
                    HStack { ForEach(message.attachments) { image in
                        AttachmentThumbnail(attachment: image, history: history).frame(maxWidth: 180, maxHeight: 120).onTapGesture { NSWorkspace.shared.open(history.imageURL(image)) }
                    } }
                }
                if !message.text.isEmpty { MarkdownText(text: message.displayText) }
                if message.status == .streaming {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(searching ? "Searching the web…" : message.text.isEmpty ? "Thinking…" : "Writing…").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }
                if let error = message.error { Text(error).font(.system(size: 12)).foregroundStyle(message.status == .stopped ? Theme.muted : .orange).textSelection(.enabled) }
                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(message.citations.enumerated()), id: \.element.id) { i, source in
                            if let url = source.safeURL { Link("\(i + 1). \(source.title)", destination: url).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.muted) }
                        }
                    }
                }
                if message.role == "assistant", message.status != .streaming {
                    HStack(spacing: 20) {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string); copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false } } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "square.on.square") }.disabled(message.text.isEmpty)
                        if canRetry { Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") } }
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 2)
                }
            }.padding(message.role == "user" ? 14 : 0)
                .background(message.role == "user" ? Theme.surface : .clear).clipShape(RoundedRectangle(cornerRadius: 14))
            if message.role != "user" { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    let history: HistoryStore
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(.black.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Screenshot, \(attachment.width) by \(attachment.height)")
            .task(id: attachment.id) {
                let url = history.imageURL(attachment)
                image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 360,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) else { return NSImage?.none }
                    return NSImage(cgImage: cg, size: .zero)
                }.value
            }
    }
}

struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    let lines = part.components(separatedBy: "\n")
                    let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(lines.first ?? "code"); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy code") }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                        ScrollView(.horizontal) { Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true) }
                    }.padding(12).background(.black.opacity(0.23)).clipShape(RoundedRectangle(cornerRadius: 8))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text((try? AttributedString(markdown: part.trimmingCharacters(in: .newlines), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part))
                        .font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).tint(Color(red: 0.58, green: 0.76, blue: 0.95)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    init(_ symbol: String, help: String, action: @escaping () -> Void) { self.symbol = symbol; self.help = help; self.action = action }
    var body: some View { Button(action: action) { Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(width: 24, height: 26).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.75)).help(help).accessibilityLabel(help) }
}

struct SettingsView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var store: ChatStore
    @ObservedObject var hotkey: GlobalShortcut
    @Environment(\.dismiss) private var dismiss
    @State private var signingOut = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("QuickChat settings").font(.system(size: 20, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            VStack(alignment: .leading, spacing: 10) {
                Text("GLOBAL SHORTCUT").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                HStack { Text("Show or hide QuickChat"); Spacer(); ShortcutRecorder(hotkey: hotkey).frame(width: 160, height: 28) }
                Text("Press Return to send, Shift-Return for a new line, and Escape to return to your previous app.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let error = hotkey.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("CHATGPT ACCOUNT").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                if !auth.vault.accounts.isEmpty {
                    Picker("Account", selection: Binding(get: { auth.vault.activeID ?? auth.vault.accounts.first!.id }, set: { auth.select($0) })) {
                        ForEach(auth.vault.accounts) { account in Text(account.label).tag(account.id) }
                    }.disabled(store.busy || auth.signingIn || signingOut)
                }
                Text(auth.connected ? "Using ChatGPT plan" : "Use your ChatGPT plan for eligible requests.").font(.system(size: 13))
                HStack {
                    if auth.connected {
                        Button("Sign out") { store.stop(); signingOut = true; Task { await auth.signOut(); signingOut = false } }.disabled(signingOut)
                    } else {
                        Button(auth.signingIn ? "Waiting for your browser…" : "Continue with ChatGPT") { auth.signIn(account: auth.active ?? auth.vault.accounts.first) }.disabled(auth.signingIn || store.demo)
                    }
                    Button("Add account") { auth.signIn() }.disabled(auth.signingIn || store.busy || store.demo)
                    if auth.signingIn { Button("Cancel") { auth.cancelSignIn() } }
                    Spacer()
                    Link("Manage usage ↗", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }
                if let error = auth.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("ON THIS MAC").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                Text("Chats and screenshots are saved locally. Credentials are stored in Keychain. Sending a message shares its conversation and attached screenshots with OpenAI.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("Show saved chats in Finder") { NSWorkspace.shared.open(store.history.root) }
            }
            Text("QuickChat 0.1 · Native macOS app").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(26).frame(width: 510).background(Theme.background).preferredColorScheme(.dark)
    }
}
