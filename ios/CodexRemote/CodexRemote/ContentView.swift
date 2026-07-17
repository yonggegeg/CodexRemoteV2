import SwiftUI
import UIKit

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private func reasoningLabel(_ effort: String?) -> String {
    switch (effort ?? "").lowercased() {
    case "low": return "低"
    case "medium": return "中"
    case "high": return "高"
    case "xhigh": return "极高"
    case "max": return "最大"
    case "ultra": return "Ultra"
    default: return effort ?? "高"
    }
}

private func permissionLabel(_ mode: String?) -> String {
    switch mode {
    case "ask": return "请求批准"
    case "auto": return "替我审批"
    case "full": return "完全访问"
    default: return "请求批准"
    }
}


struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        TabView {
            ThreadsView()
                .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right.fill") }
            WindowsMonitorView()
                .tabItem { Label("窗口", systemImage: "rectangle.on.rectangle") }
            FilesPlaceholderView()
                .tabItem { Label("文件", systemImage: "folder.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .task { client.startPolling(settings: settings) }
    }
}

struct HeaderCard: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(client.isConnected ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                    .frame(width: 54, height: 54)
                Image(systemName: client.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(client.isConnected ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex Remote v2")
                    .font(.headline)
                Text(client.agentText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(settings.serverURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ThreadsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient
    @State private var inputText: String = ""
    @State private var guideMode: Bool = false
    @State private var selectedModel: String = "gpt-5.5"
    @State private var selectedReasoning: String = "high"
    @State private var permissionMode: String = "full"
    @State private var showActionDrawer: Bool = false
    @State private var showTaskSwitcher: Bool = false
    @State private var followLatest: Bool = true
    @State private var hasNewMessages: Bool = false

    private let sampleMessages: [(String, String, Bool)] = [
        ("user", "我需要手机 App 能同步电脑 Codex 当前对话，并且可以随时发送引导消息纠正操作。", false),
        ("codex", "收到。这个 v2 界面会做成类似桌面版，支持上下文同步、图片发送和窗口截图。", false),
        ("codex", "打开窗口 Tab 可以选择两个电脑窗口，双指放大后再把截图发给 Codex。", true)
    ]
    private let latestMessageAnchor = "latest-message-anchor"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HeaderCard()
                            workspaceHeader
                            if client.threadItems.isEmpty {
                                ForEach(Array(sampleMessages.enumerated()), id: \.offset) { index, message in
                                    ChatMessageCard(role: message.0, text: message.1, compact: message.2, assistantName: assistantDisplayName)
                                        .id(index)
                                }
                            } else {
                                ForEach(client.threadItems) { item in
                                    ThreadItemCard(item: item, assistantName: assistantDisplayName)
                                        .id(item.id)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(latestMessageAnchor)
                            if let sendStatus = client.lastSendStatus {
                                Label(sendStatus, systemImage: "paperplane.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 4)
                            }
                            if let error = client.lastError {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(16)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if value.translation.height > 6 {
                                    followLatest = false
                                }
                            }
                    )
                    if hasNewMessages && !followLatest {
                        Button {
                            followLatest = true
                            hasNewMessages = false
                            scrollToLatest(proxy, delay: 0)
                        } label: {
                            Label("跳到最新", systemImage: "arrow.down.circle.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(.bottom, 10)
                    }
                    }
                    .background(Color(.systemGroupedBackground))
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { hideKeyboard() }
                    .onAppear { scrollToLatest(proxy, animated: false) }
                    .onChange(of: client.threadItems.count) { _ in handleNewContent(proxy) }
                    .onChange(of: client.threadItems.last?.id) { _ in handleNewContent(proxy) }
                    .onChange(of: client.threadItems.last?.text) { _ in handleNewContent(proxy) }
                    .onChange(of: client.selectedThreadId) { _ in
                        followLatest = true
                        hasNewMessages = false
                        scrollToLatest(proxy, delay: 0.35)
                    }
                }
                DesktopComposer(
                    text: $inputText,
                    guideMode: $guideMode,
                    selectedModel: $selectedModel,
                    selectedReasoning: $selectedReasoning,
                    permissionMode: $permissionMode,
                    onSend: sendText,
                    onImage: { }
                )
            }
            .navigationTitle("iOS Codex 控制器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTaskSwitcher = true } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("切换任务")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showActionDrawer = true } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
            .sheet(isPresented: $showActionDrawer) {
                ActionDrawerView()
            }
            .sheet(isPresented: $showTaskSwitcher) {
                TaskSwitcherView()
            }
            .onReceive(client.$codexSettings) { settings in
                if let model = settings.model { selectedModel = model }
                if let effort = settings.reasoningEffort { selectedReasoning = effort }
                if let permission = settings.permissionMode { permissionMode = permission }
            }
        }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前任务")
                        .font(.headline)
                    Text("同步 Codex 会话、图片和引导消息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(client.isConnected ? "在线" : "离线")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((client.isConnected ? Color.green : Color.orange).opacity(0.16), in: Capsule())
                    .foregroundStyle(client.isConnected ? .green : .orange)
            }
            Text("这里后续会显示完整上下文：Codex 输出、终端日志、图片附件和引导消息。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
    }

    private var assistantDisplayName: String {
        let modelName = client.modelCatalog.first(where: { $0.id == selectedModel })?.title ?? selectedModel
        return "\(modelName) \(reasoningLabel(selectedReasoning))"
    }

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let outgoing = text
        inputText = ""
        hideKeyboard()
        followLatest = true
        Task {
            if guideMode {
                await client.sendGuideMessage(outgoing, settings: settings)
            } else {
                await client.sendGuideMessage(outgoing, settings: settings)
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true, delay: Double = 0.12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(latestMessageAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(latestMessageAnchor, anchor: .bottom)
            }
        }
    }

    private func handleNewContent(_ proxy: ScrollViewProxy) {
        if followLatest {
            hasNewMessages = false
            scrollToLatest(proxy, delay: 0.05)
        } else {
            hasNewMessages = true
        }
    }
}



struct ActionDrawerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Button { } label: { Label("Image", systemImage: "gearshape") }
                            .buttonStyle(.borderedProminent)
                    }
                    drawerGroup {
                        DrawerRow(icon: "square.and.pencil", title: "新建任务", subtitle: "从手机创建新的 Codex 任务")
                        DrawerRow(icon: "clock", title: "定时任务", subtitle: "查看自动化和计划任务")
                        DrawerRow(icon: "powerplug", title: "插件", subtitle: "管理 Codex 插件")
                        DrawerRow(icon: "point.3.connected.trianglepath.dotted", title: "Pull Request", subtitle: "查看 Pull Request 工作流")
                    }
                    drawerSectionTitle("Image")
                    drawerGroup {
                        DrawerRow(icon: "folder", title: "文件功能预留", subtitle: "后续显示文件、diff 和日志")
                        DrawerRow(icon: "link", title: "连接桌面端", subtitle: "绑定电脑 Codex 远程控制")
                    }
                    drawerSectionTitle("Image")
                    drawerGroup {
                        DrawerRow(icon: "bubble.left.and.bubble.right", title: "iOS Codex 控制器", subtitle: "当前任务", selected: true)
                    }
                    drawerSectionTitle("窗口工具")
                    drawerGroup {
                        DrawerRow(icon: "rectangle.on.rectangle", title: "双窗口监看", subtitle: "同时查看两个电脑窗口")
                        DrawerRow(icon: "camera.viewfinder", title: "发送截图", subtitle: "把软件窗口作为图片发给 Codex")
                        DrawerRow(icon: "arrow.triangle.turn.up.right.circle", title: "引导消息", subtitle: "纠正正在运行的 Codex")
                        DrawerRow(icon: "shield.lefthalf.filled", title: "权限 / 模型", subtitle: "调整模型和审批模式")
                    }
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Image") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func drawerGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(.separator).opacity(0.18), lineWidth: 1))
    }

    private func drawerSectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, -8)
    }
}

struct DrawerRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(selected ? .blue : .primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(selected ? Color.blue.opacity(0.12) : Color.clear)
    }
}

struct ChatMessageCard: View {
    let role: String
    let text: String
    let compact: Bool
    var assistantName: String = "GPT-5.5 高"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(role == "user" ? "你" : assistantName)
                    .font(.caption.bold())
                    .foregroundStyle(role == "user" ? .blue : .secondary)
                Spacer()
                if compact {
                    Text("提示")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
            RichMessageText(text: text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(role == "user" ? Color.blue.opacity(0.12) : Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
        )
    }
}

struct ThreadItemCard: View {
    let item: RemoteThreadItem
    let assistantName: String

    var body: some View {
        if item.isStatus {
            StatusItemView(item: item)
        } else if item.isFileChange {
            FileChangeItemView(item: item)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.isUser ? "你" : assistantName)
                        .font(.caption.bold())
                        .foregroundStyle(item.isUser ? .blue : .secondary)
                    Spacer()
                    if let type = item.type, !type.isEmpty {
                        Text(typeLabel(type))
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                if !item.text.isEmpty {
                    RichMessageText(text: item.text)
                }
                ImageStrip(images: item.images ?? [])
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(item.isUser ? Color.blue.opacity(0.12) : Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(.separator).opacity(0.25), lineWidth: 1))
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "usermessage": return "消息"
        case "agentmessage": return "回复"
        default: return type
        }
    }
}

struct RichMessageText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    markdownText(value)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    private var blocks: [RichBlock] {
        parseRichBlocks(text)
    }

    @ViewBuilder
    private func markdownText(_ value: String) -> some View {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            if let attributed = try? AttributedString(markdown: cleaned, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
                    .font(.subheadline)
                    .textSelection(.enabled)
            } else {
                Text(cleaned)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
    }
}

enum RichBlock {
    case text(String)
    case code(language: String, code: String)
}

private func parseRichBlocks(_ text: String) -> [RichBlock] {
    let lines = text.components(separatedBy: .newlines)
    var result: [RichBlock] = []
    var normal: [String] = []
    var code: [String] = []
    var inCode = false
    var language = "text"

    func flushNormal() {
        let value = normal.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { result.append(.text(value)) }
        normal.removeAll()
    }

    func flushCode() {
        let value = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
        result.append(.code(language: language.isEmpty ? "text" : language, code: value))
        code.removeAll()
        language = "text"
    }

    for line in lines {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            if inCode {
                flushCode()
                inCode = false
            } else {
                flushNormal()
                inCode = true
                language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if inCode {
            code.append(line)
        } else {
            normal.append(line)
        }
    }
    if inCode { flushCode() }
    flushNormal()
    return result
}

struct CodeBlockView: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.isEmpty ? "text" : language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StatusItemView: View {
    let item: RemoteThreadItem

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.72)
            Text(item.text.isEmpty ? "正在处理" : item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

struct FileChangeItemView: View {
    let item: RemoteThreadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.gearshape")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("文件变更")
                    .font(.subheadline.bold())
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator).opacity(0.22), lineWidth: 1))
    }
}

struct ImageStrip: View {
    let images: [RemoteThreadImage]

    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        if let uiImage = image.image {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(.separator).opacity(0.3), lineWidth: 1))
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .font(.title3)
                                Text(image.error ?? image.fileName ?? "图片")
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: 96, height: 96)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}

struct TaskSwitcherView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        NavigationStack {
            List {
                Section("任务") {
                    ForEach(client.threads) { thread in
                        Button {
                            Task {
                                await client.selectThread(thread, settings: settings)
                                dismiss()
                            }
                        } label: {
                            ThreadRow(thread: thread, selected: thread.id == client.selectedThreadId)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("切换任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ModelReasoningMenu: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient
    @Binding var selectedModel: String
    @Binding var selectedReasoning: String

    private var selectedModelTitle: String {
        client.modelCatalog.first(where: { $0.id == selectedModel })?.title ?? selectedModel
    }

    private var selectedEfforts: [CodexReasoningEffort] {
        client.modelCatalog.first(where: { $0.id == selectedModel })?.supportedReasoningEfforts ?? [
            CodexReasoningEffort(id: "low", description: nil),
            CodexReasoningEffort(id: "medium", description: nil),
            CodexReasoningEffort(id: "high", description: nil)
        ]
    }

    var body: some View {
        Menu {
            Menu("模型") {
                if client.modelCatalog.isEmpty {
                    Text("等待电脑端模型列表")
                } else {
                    ForEach(client.modelCatalog) { model in
                        Button {
                            selectedModel = model.id
                            let effort = model.supportedReasoningEfforts?.contains(where: { $0.id == selectedReasoning }) == true
                                ? selectedReasoning
                                : (model.defaultReasoningEffort ?? model.supportedReasoningEfforts?.first?.id ?? selectedReasoning)
                            selectedReasoning = effort
                            Task { await client.updateCodexSettings(model: model.id, reasoningEffort: effort, permissionMode: nil, settings: settings) }
                        } label: {
                            if model.id == selectedModel {
                                Label(model.title, systemImage: "checkmark")
                            } else {
                                Text(model.title)
                            }
                        }
                    }
                }
            }

            Menu("推理强度") {
                ForEach(selectedEfforts) { effort in
                    Button {
                        selectedReasoning = effort.id
                        Task { await client.updateCodexSettings(model: selectedModel, reasoningEffort: effort.id, permissionMode: nil, settings: settings) }
                    } label: {
                        if effort.id == selectedReasoning {
                            Label(reasoningLabel(effort.id), systemImage: "checkmark")
                        } else {
                            Text(reasoningLabel(effort.id))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(selectedModelTitle) \(reasoningLabel(selectedReasoning))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }
}

struct PermissionMenu: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient
    @Binding var permissionMode: String

    var body: some View {
        Menu {
            Text("如何批准 ChatGPT 操作？")
                .font(.caption)
            Button {
                set("ask")
            } label: {
                if permissionMode == "ask" {
                    Label("请求批准", systemImage: "checkmark")
                } else {
                    Label("请求批准", systemImage: "hand.raised")
                }
            }
            Button {
                set("auto")
            } label: {
                if permissionMode == "auto" {
                    Label("替我审批", systemImage: "checkmark")
                } else {
                    Label("替我审批", systemImage: "shield")
                }
            }
            Button {
                set("full")
            } label: {
                if permissionMode == "full" {
                    Label("完全访问", systemImage: "checkmark")
                } else {
                    Label("完全访问", systemImage: "exclamationmark.shield.fill")
                }
            }
        } label: {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(permissionMode == "full" ? .orange : .primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func set(_ mode: String) {
        permissionMode = mode
        Task { await client.updateCodexSettings(model: nil, reasoningEffort: nil, permissionMode: mode, settings: settings) }
    }
}

struct DesktopComposer: View {
    @Binding var text: String
    @Binding var guideMode: Bool
    @Binding var selectedModel: String
    @Binding var selectedReasoning: String
    @Binding var permissionMode: String
    let onSend: () -> Void
    let onImage: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextEditor(text: $text)
                .frame(minHeight: 42, maxHeight: 76)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("继续输入，或添加图片 / 引导消息...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            hideKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                        }
                    }
                }
            HStack(spacing: 8) {
                Button(action: onImage) { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button { guideMode.toggle() } label: {
                    Image(systemName: guideMode ? "shield.lefthalf.filled" : "arrow.triangle.turn.up.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(guideMode ? .orange : .blue)
                PermissionMenu(permissionMode: $permissionMode)
                Spacer()
                ModelReasoningMenu(selectedModel: $selectedModel, selectedReasoning: $selectedReasoning)
                Button {
                    hideKeyboard()
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ThreadRow: View {
    let thread: RemoteThread
    var selected: Bool = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundStyle(selected ? .green : .blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title ?? "未命名会话")
                    .font(.headline)
                    .lineLimit(1)
                Text(thread.cwd ?? thread.updatedAt ?? thread.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(thread.status ?? "空闲")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .padding(12)
        .background(selected ? Color.green.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct WindowsMonitorView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient
    @State private var selectingSlot: String?
    @State private var screenshotNote: String = "这个窗口看起来不对。请查看截图并告诉我下一步怎么处理。"
    @State private var sendAsGuide: Bool = false
    @State private var targetSlot: String = "A"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        HeaderCard()

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("双窗口监看")
                                    .font(.title3.bold())
                                Spacer()
                                Button { Task { await client.refresh(settings: settings) } } label: {
                                    Label("刷新", systemImage: "arrow.clockwise")
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }

                            ForEach(["A", "B"], id: \.self) { slotName in
                                let slot = client.slots.first(where: { $0.slot == slotName })
                                WindowSlotCard(slotName: slotName, slot: slot) {
                                    selectingSlot = slotName
                                } onSendScreenshot: {
                                    targetSlot = slotName
                                    if let slot {
                                        Task { await client.sendWindowScreenshotToCodex(slot: slot, note: screenshotNote, kind: sendAsGuide ? "steer" : "normal", settings: settings) }
                                    }
                                }
                            }

                            if let sendStatus = client.lastSendStatus {
                                Label(sendStatus, systemImage: "paperplane.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(16)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("电脑窗口列表")
                                .font(.title3.bold())
                            ForEach(client.windows.prefix(12)) { window in
                                WindowListRow(window: window) { slot in
                                    Task { await client.selectWindow(slot: slot, window: window, settings: settings) }
                                }
                            }
                            if client.windows.isEmpty {
                                Text("没有发现窗口。请确认 Windows Agent v2 正在运行。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 12)
                            }
                        }
                        .padding(16)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
                    }
                    .padding(16)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemGroupedBackground))
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { hideKeyboard() }

                WindowIssueComposer(
                    note: $screenshotNote,
                    sendAsGuide: $sendAsGuide,
                    targetSlot: $targetSlot,
                    onSend: {
                        if let slot = client.slots.first(where: { $0.slot == targetSlot }) {
                            Task { await client.sendWindowScreenshotToCodex(slot: slot, note: screenshotNote, kind: sendAsGuide ? "steer" : "normal", settings: settings) }
                        }
                    }
                )
            }
            .navigationTitle("窗口")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("选择窗口", isPresented: Binding(get: { selectingSlot != nil }, set: { if !$0 { selectingSlot = nil } }), titleVisibility: .visible) {
                if let slot = selectingSlot {
                    ForEach(client.windows.prefix(20)) { window in
                        Button(window.displayTitle) {
                            Task { await client.selectWindow(slot: slot, window: window, settings: settings) }
                            selectingSlot = nil
                        }
                    }
                    Button("清空窗口 \(slot)", role: .destructive) {
                        Task { await client.selectWindow(slot: slot, window: nil, settings: settings) }
                        selectingSlot = nil
                    }
                }
            }
        }
    }
}

struct WindowIssueComposer: View {
    @Binding var note: String
    @Binding var sendAsGuide: Bool
    @Binding var targetSlot: String
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextEditor(text: $note)
                .frame(minHeight: 42, maxHeight: 76)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("描述窗口问题，截图会一起发送给 Codex...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            hideKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                        }
                    }
                }

            HStack(spacing: 8) {
                Menu("窗口 \(targetSlot)") {
                    Button("窗口 A") { targetSlot = "A" }
                    Button("窗口 B") { targetSlot = "B" }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { sendAsGuide.toggle() } label: {
                    Image(systemName: sendAsGuide ? "shield.lefthalf.filled" : "arrow.triangle.turn.up.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(sendAsGuide ? .orange : .blue)

                Spacer()

                Button {
                    hideKeyboard()
                    onSend()
                } label: {
                    Image(systemName: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct WindowSlotCard: View {
    let slotName: String
    let slot: WindowSlot?
    let onSelect: () -> Void
    let onSendScreenshot: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("窗口 \(slotName)")
                        .font(.headline)
                    Text(slot?.uiTitle ?? "未选择")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack {
                    Button("选择") { onSelect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("截图发给 Codex") { onSendScreenshot() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black)
                    .aspectRatio(16/9, contentMode: .fit)
                if let image = slot?.image {
                    ZoomableImage(image: image)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "display")
                            .font(.system(size: 32))
                        Text(slot?.error ?? "选择一个电脑窗口后显示画面")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 5)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.02 {
                                    resetZoom()
                                }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        if scale > 1 {
                            resetZoom()
                        } else {
                            scale = 2
                            lastScale = 2
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if scale > 1.01 {
                        Text("\(scale, specifier: "%.1f")x")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
struct WindowListRow: View {
    let window: RemoteWindow
    let onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: window.foreground == true ? "macwindow.badge.plus" : "macwindow")
                .font(.title3)
                .foregroundStyle(window.foreground == true ? .green : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(window.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(window.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu("设为") {
                Button("窗口 A") { onPick("A") }
                Button("窗口 B") { onPick("B") }
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct FilesPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                Text("文件功能预留")
                    .font(.title2.bold())
                Text("后续这里会显示 Codex 当前工作区文件、diff、日志和下载入口。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("文件")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(RemoteClient())
}
