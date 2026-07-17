import Foundation
import SwiftUI

@MainActor
final class RemoteClient: ObservableObject {
    @Published var isConnected = false
    @Published var agentText = "未连接"
    @Published var windows: [RemoteWindow] = []
    @Published var slots: [WindowSlot] = [
        WindowSlot(slot: "A", hwnd: nil, title: "窗口 A", imageBase64: nil, updatedAt: nil, error: nil),
        WindowSlot(slot: "B", hwnd: nil, title: "窗口 B", imageBase64: nil, updatedAt: nil, error: nil)
    ]
    @Published var threads: [RemoteThread] = []
    @Published var selectedThreadId: String?
    @Published var lastError: String?
    @Published var lastSendStatus: String?
    @Published var isPolling = false

    private var pollTask: Task<Void, Never>?

    func startPolling(settings: AppSettings) {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh(settings: settings)
                let seconds = max(0.7, settings.refreshSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func refresh(settings: AppSettings) async {
        do {
            let state: RelayState = try await request(settings: settings, path: "/api/state", method: "GET", body: Optional<String>.none)
            isConnected = state.ok
            windows = state.windows
            slots = state.slots.sorted { $0.slot < $1.slot }
            threads = state.threads
            selectedThreadId = state.selectedThreadId
            agentText = state.agent.online ? (state.agent.statusText ?? "Windows Agent 在线") : "Windows Agent 离线"
            lastError = nil
        } catch {
            isConnected = false
            agentText = "连接失败"
            lastError = error.localizedDescription
        }
    }

    func selectWindow(slot: String, window: RemoteWindow?, settings: AppSettings) async {
        do {
            let requestBody = SelectWindowsRequest(slots: [
                SelectWindowSlot(slot: slot, hwnd: window?.hwnd, title: window?.title)
            ])
            let _: OKEnvelope = try await request(settings: settings, path: "/api/windows/select", method: "POST", body: requestBody)
            await refresh(settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }


    func sendWindowScreenshotToCodex(slot: WindowSlot, note: String, kind: String = "normal", settings: AppSettings) async {
        guard let imageBase64 = slot.imageBase64 else {
            lastError = "窗口 \(slot.slot) 还没有截图，请先等待画面刷新"
            return
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = cleanNote.isEmpty
            ? "请查看这张电脑窗口截图，帮我判断当前软件/游戏窗口是否有异常，并给出下一步操作建议。"
            : cleanNote

        do {
            lastSendStatus = "正在上传窗口截图…"
            let fileName = "window-\(slot.slot)-\(Int(Date().timeIntervalSince1970)).jpg"
            let uploadReq = UploadRequest(fileName: fileName, mimeType: "image/jpeg", dataBase64: imageBase64)
            let upload: UploadEnvelope = try await request(settings: settings, path: "/api/uploads", method: "POST", body: uploadReq)

            lastSendStatus = "正在发送给 Codex…"
            let msgReq = SendMessageRequest(
                threadId: selectedThreadId,
                text: finalText,
                kind: kind,
                attachments: [MessageAttachment(id: upload.upload.id, fileName: upload.upload.fileName, mimeType: upload.upload.mimeType)]
            )
            let _: SendMessageEnvelope = try await request(settings: settings, path: "/api/messages/send", method: "POST", body: msgReq)
            lastSendStatus = "已发送窗口 \(slot.slot) 截图给 Codex"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lastSendStatus = nil
        }
    }


    func sendGuideMessage(_ text: String, settings: AppSettings) async {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            lastError = "引导消息不能为空"
            return
        }
        do {
            lastSendStatus = "正在发送引导消息…"
            let msgReq = SendMessageRequest(threadId: selectedThreadId, text: cleanText, kind: "steer", attachments: [])
            let _: SendMessageEnvelope = try await request(settings: settings, path: "/api/messages/send", method: "POST", body: msgReq)
            lastSendStatus = "已发送引导消息"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lastSendStatus = nil
        }
    }

    private func request<T: Decodable, B: Encodable>(settings: AppSettings, path: String, method: String, body: B?) async throws -> T {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw RemoteClientError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(settings.appToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.badResponse("无 HTTP 响应") }
        if http.statusCode == 401 { throw RemoteClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteClientError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}



