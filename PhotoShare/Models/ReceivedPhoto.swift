import Foundation

struct ReceivedPhoto: Codable, Identifiable {
    let photoId: UUID
    let recipientId: UUID
    let deliveredAt: Date?
    let viewedAt: Date?
    var savedAt: Date?
    let createdAt: Date
    let photos: PhotoDetail

    var id: UUID { photoId }
    var isSaved: Bool { savedAt != nil }

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case recipientId = "recipient_id"
        case deliveredAt = "delivered_at"
        case viewedAt = "viewed_at"
        case savedAt = "saved_at"
        case createdAt = "created_at"
        case photos
    }
}

struct PhotoDetail: Codable {
    let id: UUID
    let senderId: UUID
    let storagePath: String
    let takenAt: Date
    let locationLat: Double?
    let locationLng: Double?
    let expiresAt: Date
    let sender: SenderProfile

    var publicURL: URL? {
        URL(string: "\(Secrets.supabaseURL)/storage/v1/object/public/photos/\(storagePath)")
    }

    var isExpiringSoon: Bool {
        expiresAt.timeIntervalSinceNow < 3 * 24 * 60 * 60
    }

    enum CodingKeys: String, CodingKey {
        case id, sender
        case senderId = "sender_id"
        case storagePath = "storage_path"
        case takenAt = "taken_at"
        case locationLat = "location_lat"
        case locationLng = "location_lng"
        case expiresAt = "expires_at"
    }
}

struct SenderProfile: Codable {
    let displayName: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}
