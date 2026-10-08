import Foundation

/// A mutual friendship as seen by the current user (rows from the `list_friends` RPC).
/// `my*` toggles belong to me; `their*` belong to the friend.
struct Friend: Codable, Identifiable, Hashable {
    let friendId: UUID
    let displayName: String
    let avatarUrl: String?
    let faceProfileEnabled: Bool
    var mySend: Bool
    var myReceive: Bool
    let theirSend: Bool
    let theirReceive: Bool

    var id: UUID { friendId }

    /// I want to send but their Receive is OFF, so my photos of them are not reaching them.
    var isPaused: Bool { mySend && !theirReceive }

    enum CodingKeys: String, CodingKey {
        case friendId           = "friend_id"
        case displayName        = "display_name"
        case avatarUrl          = "avatar_url"
        case faceProfileEnabled = "face_profile_enabled"
        case mySend             = "my_send"
        case myReceive          = "my_receive"
        case theirSend          = "their_send"
        case theirReceive       = "their_receive"
    }
}

/// Result of `preview_invite`: what the accept screen shows.
struct InvitePreview: Codable {
    let inviterId: UUID?
    let inviterName: String?
    let state: String   // valid | used | expired | self | already_friends | unknown

    enum CodingKeys: String, CodingKey {
        case inviterId   = "inviter_id"
        case inviterName = "inviter_name"
        case state
    }
}

enum InviteLink {
    static let scheme = "photoshare"
    static let host = "invite"

    static func url(code: String) -> URL { URL(string: "\(scheme)://\(host)/\(code)")! }

    /// `photoshare://invite/<code>` -> code. Other photoshare:// URLs (auth callbacks) return nil.
    static func code(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let code = url.lastPathComponent
        return code.isEmpty || code == "/" ? nil : code
    }
}
