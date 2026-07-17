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
    @Published var threadItems: [RemoteThreadItem] = []
    @Published var modelCatalog: [CodexModel] = []
    @Published var permissionProfiles: [CodexPermissionProfile] = []
    @Published var codexSettings = CodexSettings(model: nil, reasoningEffort: nil, permissionMode: "ask", updatedAt: nil)
    @Published var codexRuntime = CodexRuntime(active: false, activeTurnId: nil, threadId: nil, lastItemType: nil, plan: nil, updatedAt: nil)
    @Published var latestMessageStatus: RelayMessageStatus?
    @Published var selectedThreadId: String?
    @Published var lastError: String?
    @Published var lastSendStatus: String?
    @Published var isPolling = false

    private var pollTask: Task<Void, Never>?
    private var isInBackground = false

    func startPolling(settings: AppSettings) {
        isInBackground = false
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

    func pauseForBackground() {
        isInBackground = true
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        agentText = "后台暂停，返回后自动恢复"
    }

    func refresh(settings: AppSettings) async {
        guard !isInBackground else { return }
        do {
            let state: RelayState = try await request(settings: settings, path: "/api/state", method: "GET", body: Optional<String>.none)
            isConnected = state.ok
            windows = state.windows
            slots = state.slots.sorted { $0.slot < $1.slot }
            threads = state.threads
            threadItems = state.threadItems ?? []
            modelCatalog = state.modelCatalog ?? []
            permissionProfiles = state.permissionProfiles ?? []
            if let codexSettings = state.codexSettings {
                self.codexSettings = codexSettings
            }
            if let codexRuntime = state.codexRuntime {
                self.codexRuntime = codexRuntime
            }
            latestMessageStatus = state.latestMessageStatus
            if let status = state.latestMessageStatus {
                lastSendStatus = status.displayText
                if status.isError { lastError = status.error ?? status.displayText }
            }
            selectedThreadId = state.selectedThreadId
            agentText = state.agent.online ? (state.agent.statusText ?? "Windows Agent 在线") : "Windows Agent 离线"
            if state.latestMessageStatus?.isError != true {
                lastError = nil
            }
        } catch {
            if !isInBackground {
                isConnected = false
                agentText = "正在恢复连接…"
            }
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

    func selectThread(_ thread: RemoteThread, settings: AppSettings) async {
        do {
            let requestBody = SelectThreadRequest(threadId: thread.id)
            let _: OKEnvelope = try await request(settings: settings, path: "/api/thread/select", method: "POST", body: requestBody)
            selectedThreadId = thread.id
            await refresh(settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendMessage(_ text: String, kind: String = "normal", settings: AppSettings) async {
        await sendMessageWithUploads(text, uploads: [], kind: kind, settings: settings)
    }

    func sendMessageWithUploads(_ text: String, uploads: [UploadRequest], kind: String = "normal", settings: AppSettings) async {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty || !uploads.isEmpty else {
            lastError = "消息不能为空"
            return
        }
        do {
            lastSendStatus = kind == "steer" ? "正在发送引导消息…" : "正在发送消息…"
            var attachments: [MessageAttachment] = []
            for uploadReq in uploads {
                let upload: UploadEnvelope = try await request(settings: settings, path: "/api/uploads", method: "POST", body: uploadReq)
                attachments.append(MessageAttachment(id: upload.upload.id, fileName: upload.upload.fileName, mimeType: upload.upload.mimeType))
            }
            let activeTurnId = codexRuntime.active == true ? codexRuntime.activeTurnId : nil
            let finalKind = activeTurnId == nil ? kind : "steer"
            let msgReq = SendMessageRequest(threadId: selectedThreadId, text: cleanText, kind: finalKind, turnId: activeTurnId, attachments: attachments)
            let envelope: SendMessageEnvelope = try await request(settings: settings, path: "/api/messages/send", method: "POST", body: msgReq)
            if let queued = envelope.message {
                latestMessageStatus = RelayMessageStatus(id: queued.id, status: "queued", text: queued.text, threadId: queued.threadId, kind: finalKind, error: nil, processedAt: nil, updatedAt: nil)
            }
            lastSendStatus = latestMessageStatus?.displayText ?? "已提交，等待电脑处理…"
            lastError = nil
            await refresh(settings: settings)
        } catch {
            lastError = error.localizedDescription
            lastSendStatus = nil
        }
    }

    func updateCodexSettings(model: String?, reasoningEffort: String?, permissionMode: String?, settings: AppSettings) async {
        do {
            let body = CodexSettingsRequest(
                model: model ?? codexSettings.model,
                reasoningEffort: reasoningEffort ?? codexSettings.reasoningEffort,
                permissionMode: permissionMode ?? codexSettings.permissionMode
            )
            let envelope: CodexSettingsEnvelope = try await request(settings: settings, path: "/api/codex/settings", method: "POST", body: body)
            if let updated = envelope.codexSettings {
                codexSettings = updated
            }
            lastError = nil
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
            let activeTurnId = codexRuntime.active == true ? codexRuntime.activeTurnId : nil
            let finalKind = activeTurnId == nil ? kind : "steer"
            let msgReq = SendMessageRequest(
                threadId: selectedThreadId,
                text: finalText,
                kind: finalKind,
                turnId: activeTurnId,
                attachments: [MessageAttachment(id: upload.upload.id, fileName: upload.upload.fileName, mimeType: upload.upload.mimeType)]
            )
            let envelope: SendMessageEnvelope = try await request(settings: settings, path: "/api/messages/send", method: "POST", body: msgReq)
            if let queued = envelope.message {
                latestMessageStatus = RelayMessageStatus(id: queued.id, status: "queued", text: queued.text, threadId: queued.threadId, kind: finalKind, error: nil, processedAt: nil, updatedAt: nil)
            }
            lastSendStatus = "已提交窗口 \(slot.slot) 截图，等待电脑 Codex 处理…"
            lastError = nil
            await refresh(settings: settings)
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
        await sendMessage(cleanText, kind: "steer", settings: settings)
    }

    func interruptCodex(settings: AppSettings) async {
        do {
            lastSendStatus = "正在停止当前对话…"
            let body = InterruptCodexRequest(threadId: selectedThreadId ?? codexRuntime.threadId, turnId: codexRuntime.activeTurnId)
            let _: OKEnvelope = try await request(settings: settings, path: "/api/codex/interrupt", method: "POST", body: body)
            lastSendStatus = "已请求停止"
            lastError = nil
            await refresh(settings: settings)
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



