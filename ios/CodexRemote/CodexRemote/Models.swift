import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "http://115.159.221.170:8080" { willSet { objectWillChange.send() } }
    @AppStorage("appToken") var appToken: String = "" { willSet { objectWillChange.send() } }
    @AppStorage("refreshSeconds") var refreshSeconds: Double = 1.5 { willSet { objectWillChange.send() } }
    @AppStorage("lowDataMode") var lowDataMode: Bool = true { willSet { objectWillChange.send() } }
}

struct RelayHealth: Decodable {
    let ok: Bool
    let name: String?
    let port: Int?
    let agent: AgentStatus?
    let time: String?
}

struct RelayState: Decodable {
    let ok: Bool
    let notModified: Bool?
    let stateHash: String?
    let modelCatalogHash: String?
    let permissionProfilesHash: String?
    let threadsHash: String?
    let windowsHash: String?
    let agent: AgentStatus
    let windows: [RemoteWindow]?
    let slots: [WindowSlot]?
    let threads: [RemoteThread]?
    let threadItems: [RemoteThreadItem]?
    let modelCatalog: [CodexModel]?
    let permissionProfiles: [CodexPermissionProfile]?
    let codexSettings: CodexSettings?
    let codexRuntime: CodexRuntime?
    let historyCursor: String?
    let latestMessageStatus: RelayMessageStatus?
    let messageStatuses: [RelayMessageStatus]?
    let selectedThreadId: String?
    let time: String?
}

struct AgentStatus: Decodable {
    let online: Bool
    let id: String?
    let host: String?
    let version: String?
    let updatedAt: String?
    let statusText: String?
}

struct RemoteWindow: Identifiable, Hashable, Decodable {
    let hwnd: String
    let title: String
    let process: String?
    let pid: Int?
    let x: Int?
    let y: Int?
    let width: Int?
    let height: Int?
    let foreground: Bool?

    var id: String { hwnd }
    var displayTitle: String { title.isEmpty ? "未命名窗口" : title }
    var subtitle: String {
        let p = process ?? "unknown"
        if let width, let height { return "\(p) · \(width)x\(height)" }
        return p
    }
}

struct WindowSlot: Identifiable, Decodable {
    let slot: String
    let hwnd: String?
    let title: String?
    let imageBase64: String?
    let imageHash: String?
    let unchanged: Bool?
    let updatedAt: String?
    let error: String?

    var id: String { slot }
    var uiTitle: String { title ?? "窗口 \(slot)" }

    var image: UIImage? {
        guard let imageBase64, let data = Data(base64Encoded: imageBase64) else { return nil }
        return UIImage(data: data)
    }
}

struct RemoteThread: Identifiable, Decodable {
    let id: String
    let title: String?
    let status: String?
    let updatedAt: String?
    let cwd: String?
    let preview: String?
}

struct RemoteThreadItem: Identifiable, Codable {
    let id: String
    let role: String?
    let text: String
    let createdAt: String?
    let type: String?
    let turnId: String?
    let images: [RemoteThreadImage]?
    let fileCount: Int?
    let additions: Int?
    let deletions: Int?
    let files: [RemoteFileChange]?

    var isUser: Bool {
        let r = (role ?? "").lowercased()
        return r.contains("user") || r == "input"
    }

    var isStatus: Bool {
        let t = (type ?? "").lowercased()
        return t == "reasoning" || t.contains("status")
    }

    var isFileChange: Bool {
        (type ?? "").lowercased() == "filechange"
    }
}

struct RemoteFileChange: Identifiable, Codable, Hashable {
    let path: String?
    let file: String?
    let kind: String?
    let additions: Int?
    let deletions: Int?

    var id: String { path ?? file ?? "change" }
}

struct RemoteThreadImage: Identifiable, Codable {
    let id: String
    let fileName: String?
    let mimeType: String?
    let localPath: String?
    let dataBase64: String?
    let url: String?
    let error: String?
    let hasRemoteData: Bool?

    var image: UIImage? {
        guard let dataBase64, let data = Data(base64Encoded: dataBase64) else { return nil }
        return UIImage(data: data)
    }
}

struct CodexModel: Identifiable, Decodable, Hashable {
    let id: String
    let model: String?
    let displayName: String?
    let description: String?
    let isDefault: Bool?
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [CodexReasoningEffort]?

    var title: String { displayName ?? model ?? id }
}

struct CodexReasoningEffort: Identifiable, Decodable, Hashable {
    let id: String
    let description: String?
}

struct CodexPermissionProfile: Identifiable, Decodable, Hashable {
    let id: String
    let description: String?
    let allowed: Bool?
}

struct CodexSettings: Codable, Hashable {
    let model: String?
    let reasoningEffort: String?
    let permissionMode: String?
    let updatedAt: String?
}

struct CodexSettingsRequest: Encodable {
    let model: String?
    let reasoningEffort: String?
    let permissionMode: String?
}

struct RelayMessageStatus: Decodable, Hashable {
    let id: String
    let status: String?
    let text: String?
    let threadId: String?
    let kind: String?
    let error: String?
    let processedAt: String?
    let updatedAt: String?

    var displayText: String {
        switch status {
        case "queued": return "已提交，等待电脑处理…"
        case "deliveredToAgent": return "Windows Agent 已收到，正在发给 Codex…"
        case "submittedToCodexRuntime": return "已写入后台 Codex，电脑窗口待同步"
        case "visibleInDesktop": return "电脑窗口已同步"
        case "sentToCodex": return "已写入后台 Codex，电脑窗口待同步"
        case "error": return error ?? "发送失败"
        default: return status ?? "等待处理"
        }
    }

    var isError: Bool { status == "error" }
}

struct CodexRuntime: Decodable, Hashable {
    let active: Bool?
    let activeTurnId: String?
    let threadId: String?
    let lastItemType: String?
    let plan: CodexPlanRuntime?
    let historyCursor: String?
    let updatedAt: String?
}

struct ThreadImageEnvelope: Decodable {
    let ok: Bool
    let image: RemoteThreadImage?
}

struct CodexPlanRuntime: Codable, Hashable {
    let currentStep: String?
    let currentIndex: Int?
    let total: Int?
    let completed: Int?
    let explanation: String?
    let fileSummary: CodexPlanFileSummary?
    let updatedAt: String?
}

struct CodexPlanFileSummary: Codable, Hashable {
    let fileCount: Int?
    let additions: Int?
    let deletions: Int?
    let files: [RemoteFileChange]?
}

struct InterruptCodexRequest: Encodable {
    let threadId: String?
    let turnId: String?
}

struct CodexSettingsEnvelope: Decodable {
    let ok: Bool
    let codexSettings: CodexSettings?
}

struct SelectThreadRequest: Encodable {
    let threadId: String?
}

struct SelectWindowsRequest: Encodable {
    let slots: [SelectWindowSlot]
}

struct SelectWindowSlot: Encodable {
    let slot: String
    let hwnd: String?
    let title: String?
}

enum RemoteClientError: LocalizedError {
    case invalidURL
    case unauthorized
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址不正确"
        case .unauthorized: return "App Token 不正确"
        case .badResponse(let message): return message
        }
    }
}

struct OKEnvelope: Decodable {
    let ok: Bool
}

struct UploadRequest: Encodable {
    let fileName: String
    let mimeType: String
    let dataBase64: String
}

struct UploadEnvelope: Decodable {
    let ok: Bool
    let upload: UploadedFile
}

struct UploadedFile: Codable {
    let id: String
    let fileName: String?
    let mimeType: String?
    let createdAt: String?
}

struct SendMessageRequest: Encodable {
    let threadId: String?
    let text: String
    let kind: String
    let turnId: String?
    let attachments: [MessageAttachment]
}

struct MessageAttachment: Codable {
    let id: String
    let fileName: String?
    let mimeType: String?
}

struct SendMessageEnvelope: Decodable {
    let ok: Bool
    let message: QueuedMessage?
}

struct HistoryRequestBody: Encodable {
    let threadId: String?
    let cursor: String?
    let limit: Int
}

struct HistoryRequestEnvelope: Decodable {
    let ok: Bool
    let requestId: String?
}

struct HistoryResultEnvelope: Decodable {
    let ok: Bool
    let pending: Bool?
    let id: String?
    let threadId: String?
    let items: [RemoteThreadItem]?
    let nextCursor: String?
    let error: String?
}

struct QueuedMessage: Decodable {
    let id: String
    let threadId: String?
    let text: String?
    let createdAt: String?
}
