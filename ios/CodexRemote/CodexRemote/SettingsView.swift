import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("连接"),
                    footer: Text("v2 当前使用公网端口 8080，例如 http://115.159.221.170:8080。")
                ) {
                    TextField("服务器地址", text: $settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    SecureField("App Token", text: $settings.appToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("测试并刷新") {
                        Task { await client.refresh(settings: settings) }
                    }
                }

                Section(header: Text("刷新")) {
                    Toggle("省流量模式", isOn: $settings.lowDataMode)
                    Text("开启后列表同步只传文字、状态和图片索引；点开图片时才单独加载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(value: $settings.refreshSeconds, in: 0.7...5.0, step: 0.1) {
                        Text("刷新间隔")
                    }
                    Text("当前：\(settings.refreshSeconds, specifier: "%.1f") 秒")
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("状态")) {
                    LabeledContent("连接", value: client.isConnected ? "已连接" : "未连接")
                    LabeledContent("Agent", value: client.agentText)
                    if let error = client.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section(header: Text("v2 功能")) {
                    Label("电脑 Codex 会话同步", systemImage: "bubble.left.and.bubble.right")
                    Label("两个电脑窗口监看", systemImage: "rectangle.split.2x1")
                    Label("窗口截图发给 Codex", systemImage: "camera.viewfinder")
                    Label("引导消息纠正当前操作", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(RemoteClient())
}
