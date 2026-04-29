import Foundation

struct IncomingLinkRequest: Codable, Identifiable {
    let id: UUID
    let senderId: UUID
    let status: String
    let createdAt: Date
    let sender: LinkedProfile

    enum CodingKeys: String, CodingKey {
        case id, status, sender
        case senderId = "sender_id"
        case createdAt = "created_at"
    }
}

struct OutgoingLink: Codable, Identifiable {
    let id: UUID
    let recipientId: UUID
    let status: String
    let createdAt: Date
    let recipient: LinkedProfile

    var isPaused: Bool { status == "paused" }

    enum CodingKeys: String, CodingKey {
        case id, status, recipient
        case recipientId = "recipient_id"
        case createdAt = "created_at"
    }
}

struct LinkedProfile: Codable {
    let displayName: String
    let avatarUrl: String?
    let faceProfileEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case displayName        = "display_name"
        case avatarUrl          = "avatar_url"
        case faceProfileEnabled = "face_profile_enabled"
    }
}
