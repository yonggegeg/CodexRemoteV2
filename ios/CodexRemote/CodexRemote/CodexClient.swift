import Foundation
import SwiftUI

@MainActor
final class RemoteClient: ObservableObject {
    @Published var isConnected = false
    @Published var agentText = "未连接"
    @Published var windows: [RemoteWindow] = []
    @Published var slots: [WindowSlot] = [
        WindowSlot(slot: "A", hwnd: nil, title: "窗口 A", imageBase64: nil, imageHash: nil, unchanged: nil, updatedAt: nil, error: nil),
        WindowSlot(slot: "B", hwnd: nil, title: "窗口 B", imageBase64: nil, imageHash: nil, unchanged: nil, updatedAt: nil, error: nil)
    ]
    @Published var threads: [RemoteThread] = []
    @Published var threadItems: [RemoteThreadItem] = []
    @Published var modelCatalog: [CodexModel] = []
    @Published var permissionProfiles: [CodexPermissionProfile] = []
    @Published var codexSettings = CodexSettings(model: nil, reasoningEffort: nil, permissionMode: "ask", updatedAt: nil)
    @Published var codexRuntime = CodexRuntime(active: false, activeTurnId: nil, threadId: nil, lastItemType: nil, plan: nil, historyCursor: nil, updatedAt: nil)
    @Published var latestMessageStatus: RelayMessageStatus?
    @Published var selectedThreadId: String?
    @Published var lastError: String?
    @Published var lastSendStatus: String?
    @Published var isPolling = false
    @Published var isLoadingOlder = false
    @Published var hasMoreHistory = true

    private var pollTask: Task<Void, Never>?
    private var isInBackground = false
    private var latestThreadItems: [RemoteThreadItem] = []
    private var olderThreadItems: [RemoteThreadItem] = []
    private var historyCursor: String?
    private var lastStateHash: String?
    private var lastModelCatalogHash: String?
    private var lastPermissionProfilesHash: String?
    private var lastThreadsHash: String?
    private var lastWindowsHash: String?
    private let maxDisplayedItems = 800
    private let cacheStore = ChatCacheStore()

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
            let query = slotHashQuery(settings: settings)
            let state: RelayState = try await request(settings: settings, path: "/api/state\(query)", method: "GET", body: Optional<String>.none)
            isConnected = state.ok
            agentText = state.agent.online ? (state.agent.statusText ?? "Windows Agent 在线") : "Windows Agent 离线"
            if state.notModified == true {
                if let hash = state.stateHash { lastStateHash = hash }
                if state.latestMessageStatus?.isError != true { lastError = nil }
                return
            }
            if let hash = state.stateHash { lastStateHash = hash }
            if let hash = state.modelCatalogHash { lastModelCatalogHash = hash }
            if let hash = state.permissionProfilesHash { lastPermissionProfilesHash = hash }
            if let hash = state.threadsHash { lastThreadsHash = hash }
            if let hash = state.windowsHash { lastWindowsHash = hash }
            windows = state.windows ?? windows
            slots = mergeSlots((state.slots ?? slots).sorted { $0.slot < $1.slot })
            threads = state.threads ?? threads
            let incomingThreadId = state.selectedThreadId
            let threadChanged = selectedThreadId != incomingThreadId
            if threadChanged {
                olderThreadItems = cacheStore.load(threadId: incomingThreadId)
                latestThreadItems = []
                threadItems = olderThreadItems
            }
            latestThreadItems = state.threadItems ?? []
            historyCursor = state.historyCursor ?? state.codexRuntime?.historyCursor ?? (threadChanged ? nil : historyCursor)
            hasMoreHistory = historyCursor != nil
            selectedThreadId = incomingThreadId
            publishMergedThreadItems()
            modelCatalog = state.modelCatalog ?? modelCatalog
            permissionProfiles = state.permissionProfiles ?? permissionProfiles
            if let codexSettings = state.codexSettings {
                self.codexSettings = codexSettings
            }
            if let codexRuntime = state.codexRuntime {
                self.codexRuntime = codexRuntime
            }
            latestMessageStatus = state.latestMessageStatus
            if let status = state.latestMessageStatus {
                lastSendStatus = shouldShowMessageStatus(status) ? status.displayText : nil
                if status.isError { lastError = status.error ?? status.displayText }
            }
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
            olderThreadItems = cacheStore.load(threadId: thread.id)
            latestThreadItems = []
            threadItems = olderThreadItems
            historyCursor = nil
            lastStateHash = nil
            lastThreadsHash = nil
            hasMoreHistory = true
            await refresh(settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadOlderMessages(settings: AppSettings) async {
        guard !isLoadingOlder, hasMoreHistory else { return }
        guard let threadId = selectedThreadId else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let body = HistoryRequestBody(threadId: threadId, cursor: historyCursor, limit: 60)
            let queued: HistoryRequestEnvelope = try await request(settings: settings, path: "/api/thread/history/request", method: "POST", body: body)
            guard let requestId = queued.requestId else { throw RemoteClientError.badResponse("历史请求没有返回 requestId") }
            var result: HistoryResultEnvelope?
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                let path = "/api/thread/history/result?id=\(requestId)"
                let response: HistoryResultEnvelope = try await request(settings: settings, path: path, method: "GET", body: Optional<String>.none)
                if response.pending == true { continue }
                result = response
                break
            }
            guard let result else { throw RemoteClientError.badResponse("读取历史消息超时") }
            if result.ok == false { throw RemoteClientError.badResponse(result.error ?? "读取历史消息失败") }
            let incoming = result.items ?? []
            historyCursor = result.nextCursor
            hasMoreHistory = result.nextCursor != nil && !incoming.isEmpty
            olderThreadItems = mergeUnique(incoming + olderThreadItems)
            publishMergedThreadItems()
            lastError = nil
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
            lastStateHash = nil
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

    func loadThreadImage(_ image: RemoteThreadImage, settings: AppSettings) async throws -> RemoteThreadImage {
        if let cached = cacheStore.loadImage(image) {
            return cached
        }
        guard image.image == nil, let url = image.url, url.hasPrefix("/api/") else {
            return image
        }
        let envelope: ThreadImageEnvelope = try await request(settings: settings, path: url, method: "GET", body: Optional<String>.none)
        let loaded = envelope.image ?? image
        cacheStore.saveImage(loaded)
        return loaded
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

    private func publishMergedThreadItems() {
        let merged = mergeUnique(olderThreadItems + latestThreadItems)
        if merged.count > maxDisplayedItems {
            threadItems = Array(merged.suffix(maxDisplayedItems))
            olderThreadItems = Array(threadItems.dropLast(latestThreadItems.count))
        } else {
            threadItems = merged
        }
        cacheStore.save(threadId: selectedThreadId, items: threadItems)
    }

    private func mergeUnique(_ items: [RemoteThreadItem]) -> [RemoteThreadItem] {
        var order: [String] = []
        var byId: [String: RemoteThreadItem] = [:]
        for item in items {
            if byId[item.id] == nil {
                order.append(item.id)
            }
            byId[item.id] = item
        }
        return order.compactMap { byId[$0] }
    }

    private func slotHashQuery(settings: AppSettings) -> String {
        var params: [String] = []
        if settings.lowDataMode {
            params.append("lowData=1")
        }
        if let lastStateHash {
            params.append("stateHash=\(lastStateHash)")
        }
        if let lastModelCatalogHash {
            params.append("modelCatalogHash=\(lastModelCatalogHash)")
        }
        if let lastPermissionProfilesHash {
            params.append("permissionProfilesHash=\(lastPermissionProfilesHash)")
        }
        if let lastThreadsHash {
            params.append("threadsHash=\(lastThreadsHash)")
        }
        if let lastWindowsHash {
            params.append("windowsHash=\(lastWindowsHash)")
        }
        let pairs = slots.compactMap { slot -> String? in
            guard let hash = slot.imageHash, !hash.isEmpty else { return nil }
            return "\(slot.slot):\(hash)"
        }
        if !pairs.isEmpty {
            params.append("slotHashes=\(pairs.joined(separator: ","))")
        }
        guard !params.isEmpty else { return "" }
        return "?\(params.joined(separator: "&"))"
    }

    private func mergeSlots(_ incoming: [WindowSlot]) -> [WindowSlot] {
        incoming.map { slot in
            if slot.unchanged == true,
               slot.imageBase64 == nil,
               let old = slots.first(where: { $0.slot == slot.slot }) {
                return WindowSlot(slot: slot.slot, hwnd: slot.hwnd, title: slot.title, imageBase64: old.imageBase64, imageHash: slot.imageHash ?? old.imageHash, unchanged: slot.unchanged, updatedAt: slot.updatedAt, error: slot.error)
            }
            return slot
        }
    }

    private func shouldShowMessageStatus(_ status: RelayMessageStatus) -> Bool {
        if status.isError { return true }
        guard status.status == "sentToCodex" || status.status == "submittedToCodexRuntime" || status.status == "visibleInDesktop" else { return true }
        let raw = status.updatedAt ?? status.processedAt
        guard let raw, let date = ISO8601DateFormatter().date(from: raw) else { return true }
        return Date().timeIntervalSince(date) < 12
    }
}


private final class ChatCacheStore {
    private struct CacheEnvelope: Codable {
        let version: Int
        let threadId: String
        let updatedAt: String
        let items: [RemoteThreadItem]
    }

    private let maxItemsPerThread = 2500
    private let maxThreadFileBytes = 24 * 1024 * 1024
    private let maxSingleImageBytes = 16 * 1024 * 1024
    private let folderURL: URL
    private let mediaURL: URL
    private var lastWriteSignature: [String: Int] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = base.appendingPathComponent("CodexRemote/ChatCache", isDirectory: true)
        mediaURL = base.appendingPathComponent("CodexRemote/MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    }

    func load(threadId: String?) -> [RemoteThreadItem] {
        guard let threadId, !threadId.isEmpty else { return [] }
        let url = fileURL(threadId: threadId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else { return [] }
        return envelope.items
    }

    func save(threadId: String?, items: [RemoteThreadItem]) {
        guard let threadId, !threadId.isEmpty, !items.isEmpty else { return }
        let stripped = items.suffix(maxItemsPerThread).map(stripHeavyPayloads)
        var envelope = CacheEnvelope(version: 1, threadId: threadId, updatedAt: ISO8601DateFormatter().string(from: Date()), items: stripped)
        var data = try? JSONEncoder().encode(envelope)
        if let current = data, current.count > maxThreadFileBytes {
            let ratio = Double(maxThreadFileBytes) / Double(max(current.count, 1))
            let targetCount = max(200, Int(Double(stripped.count) * ratio * 0.88))
            envelope = CacheEnvelope(version: 1, threadId: threadId, updatedAt: envelope.updatedAt, items: Array(stripped.suffix(targetCount)))
            data = try? JSONEncoder().encode(envelope)
        }
        guard let data else { return }
        let signature = data.hashValue
        if lastWriteSignature[threadId] == signature { return }
        lastWriteSignature[threadId] = signature
        try? data.write(to: fileURL(threadId: threadId), options: [.atomic])
        pruneOldThreadFiles()
    }

    func loadImage(_ image: RemoteThreadImage) -> RemoteThreadImage? {
        let url = imageFileURL(id: image.id)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(RemoteThreadImage.self, from: data),
              cached.dataBase64 != nil else { return nil }
        return cached
    }

    func saveImage(_ image: RemoteThreadImage) {
        guard let dataBase64 = image.dataBase64 else { return }
        let size = dataBase64.utf8.count
        guard size > 0, size <= maxSingleImageBytes else { return }
        let storable = RemoteThreadImage(
            id: image.id,
            fileName: image.fileName,
            mimeType: image.mimeType,
            localPath: image.localPath,
            dataBase64: dataBase64,
            url: image.url,
            error: image.error,
            hasRemoteData: image.hasRemoteData
        )
        guard let data = try? JSONEncoder().encode(storable) else { return }
        try? data.write(to: imageFileURL(id: image.id), options: [.atomic])
        pruneOldMediaFiles()
    }

    private func stripHeavyPayloads(_ item: RemoteThreadItem) -> RemoteThreadItem {
        let images = item.images?.map { image in
            RemoteThreadImage(
                id: image.id,
                fileName: image.fileName,
                mimeType: image.mimeType,
                localPath: image.localPath,
                dataBase64: nil,
                url: image.url,
                error: image.error,
                hasRemoteData: image.hasRemoteData
            )
        }
        return RemoteThreadItem(
            id: item.id,
            role: item.role,
            text: item.text,
            createdAt: item.createdAt,
            type: item.type,
            turnId: item.turnId,
            images: images,
            fileCount: item.fileCount,
            additions: item.additions,
            deletions: item.deletions,
            files: item.files
        )
    }

    private func fileURL(threadId: String) -> URL {
        return folderURL.appendingPathComponent(safeFileName(threadId)).appendingPathExtension("json")
    }

    private func imageFileURL(id: String) -> URL {
        return mediaURL.appendingPathComponent(safeFileName(id)).appendingPathExtension("json")
    }

    private func safeFileName(_ raw: String) -> String {
        let safe = raw.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
            return "_"
        }
        let name = String(safe)
        let prefix = String((name.isEmpty ? "unknown" : name).prefix(80))
        return "\(prefix)-\(stableSmallHash(raw))"
    }

    private func stableSmallHash(_ raw: String) -> String {
        var hash: UInt64 = 5381
        for byte in raw.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func pruneOldThreadFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var total = 0
        let infos: [(URL, Date, Int)] = files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            total += size
            return (url, values?.contentModificationDate ?? .distantPast, size)
        }
        let maxTotal = 512 * 1024 * 1024
        guard total > maxTotal else { return }
        for (url, _, size) in infos.sorted(by: { $0.1 < $1.1 }) {
            try? FileManager.default.removeItem(at: url)
            total -= size
            if total <= maxTotal { break }
        }
    }

    private func pruneOldMediaFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: mediaURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var total = 0
        let infos: [(URL, Date, Int)] = files.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            total += size
            return (url, values?.contentModificationDate ?? .distantPast, size)
        }
        let maxTotal = 1536 * 1024 * 1024
        guard total > maxTotal else { return }
        for (url, _, size) in infos.sorted(by: { $0.1 < $1.1 }) {
            try? FileManager.default.removeItem(at: url)
            total -= size
            if total <= maxTotal { break }
        }
    }
}


