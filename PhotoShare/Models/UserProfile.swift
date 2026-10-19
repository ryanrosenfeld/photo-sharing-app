import Foundation

struct UserProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var avatarUrl: String?
    var plan: Plan
    var faceProfileEnabled: Bool
    /// Base64 DER of the account's photo-encryption public key (nil until the app has published one).
    var publicKey: String?
    let createdAt: Date

    enum Plan: String, Codable {
        case free, pro

        var displayName: String {
            switch self {
            case .free: "Free"
            case .pro:  "Pro"
            }
        }

        var isPro: Bool { self == .pro }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName       = "display_name"
        case avatarUrl         = "avatar_url"
        case plan
        case faceProfileEnabled = "face_profile_enabled"
        case publicKey         = "public_key"
        case createdAt         = "created_at"
    }
}
