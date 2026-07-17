import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "http://115.159.221.170:8080" { willSet { objectWillChange.send() } }
    @AppStorage("appToken") var appToken: String = "" { willSet { objectWillChange.send() } }
    @AppStorage("refreshSeconds") var refreshSeconds: Double = 1.2 { willSet { objectWillChange.send() } }
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
    let agent: AgentStatus
    let windows: [RemoteWindow]
    let slots: [WindowSlot]
    let threads: [RemoteThread]
    let threadItems: [RemoteThreadItem]?
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

struct RemoteThreadItem: Identifiable, Decodable {
    let id: String
    let role: String?
    let text: String
    let createdAt: String?
    let type: String?

    var isUser: Bool {
        let r = (role ?? "").lowercased()
        return r.contains("user") || r == "input"
    }
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

struct QueuedMessage: Decodable {
    let id: String
    let threadId: String?
    let text: String?
    let createdAt: String?
}
