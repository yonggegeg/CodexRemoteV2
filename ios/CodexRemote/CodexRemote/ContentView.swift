import SwiftUI

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
    @State private var selectedModel: String = "5.5 ?"
    @State private var showActionDrawer: Bool = false

    private let sampleMessages: [(String, String, Bool)] = [
        ("user", "我需要手机 App 能同步电脑 Codex 当前对话，并且可以随时发送引导消息纠正操作。", false),
        ("codex", "收到。这个 v2 界面会做成类似桌面版，支持上下文同步、图片发送和窗口截图。", false),
        ("codex", "打开窗口 Tab 可以选择两个电脑窗口，双指放大后再把截图发给 Codex。", true)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HeaderCard()
                            workspaceHeader
                            ForEach(Array(sampleMessages.enumerated()), id: \.offset) { index, message in
                                ChatMessageCard(role: message.0, text: message.1, compact: message.2)
                                    .id(index)
                            }
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
                    .background(Color(.systemGroupedBackground))
                }
                DesktopComposer(
                    text: $inputText,
                    guideMode: $guideMode,
                    selectedModel: $selectedModel,
                    onSend: sendText,
                    onImage: { },
                    onPermission: { }
                )
            }
            .navigationTitle("iOS Codex 控制器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let outgoing = text
        inputText = ""
        Task {
            if guideMode {
                await client.sendGuideMessage(outgoing, settings: settings)
            } else {
                await client.sendGuideMessage(outgoing, settings: settings)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(role == "user" ? "?" : "Codex")
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
            Text(text)
                .font(.subheadline)
                .textSelection(.enabled)
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

struct DesktopComposer: View {
    @Binding var text: String
    @Binding var guideMode: Bool
    @Binding var selectedModel: String
    let onSend: () -> Void
    let onImage: () -> Void
    let onPermission: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $text)
                .frame(minHeight: 76, maxHeight: 120)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("继续输入，或添加图片 / 引导消息...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                    }
                }
            HStack(spacing: 10) {
                Button(action: onImage) { Label("图片", systemImage: "plus") }
                    .buttonStyle(.bordered)
                Button { guideMode.toggle() } label: {
                    Label(guideMode ? "引导中" : "引导", systemImage: guideMode ? "shield.lefthalf.filled" : "arrow.triangle.turn.up.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(guideMode ? .orange : .blue)
                Button(action: onPermission) { Label("完全访问", systemImage: "exclamationmark.shield.fill") }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.orange)
                Spacer()
                Menu(selectedModel) {
                    Button("5.5 ?") { selectedModel = "5.5 ?" }
                    Button("5.5 ?") { selectedModel = "5.5 ?" }
                    Button("5.5 ?") { selectedModel = "5.5 ?" }
                }
                .font(.caption)
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

struct ThreadRow: View {
    let thread: RemoteThread
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundStyle(.blue)
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
            Text(thread.status ?? "空闲")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        VStack(spacing: 10) {
            TextEditor(text: $note)
                .frame(minHeight: 72, maxHeight: 110)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("描述窗口问题，截图会一起发送给 Codex...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                    }
                }

            HStack(spacing: 10) {
                Menu("窗口 \(targetSlot)") {
                    Button("窗口 A") { targetSlot = "A" }
                    Button("窗口 B") { targetSlot = "B" }
                }
                .buttonStyle(.bordered)

                Button { sendAsGuide.toggle() } label: {
                    Label(sendAsGuide ? "引导中" : "引导", systemImage: sendAsGuide ? "shield.lefthalf.filled" : "arrow.triangle.turn.up.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(sendAsGuide ? .orange : .blue)

                Spacer()

                Button(action: onSend) {
                    Label("发送截图", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
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


