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

/// One of my invites nobody has used yet (rows of `invites`, readable by the inviter).
struct OpenInvite: Codable, Identifiable, Hashable {
    let code: String
    let createdAt: Date
    let expiresAt: Date
    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

/// Result of `preview_invite_public`: enough for the welcome screen of a signed-out invitee.
struct PublicInvitePreview: Codable, Sendable {
    let inviterName: String?
    let usable: Bool

    enum CodingKeys: String, CodingKey {
        case inviterName = "inviter_name"
        case usable
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

    /// What someone pastes into "Have an invite link?": the link, the whole invite message, or just the code.
    /// Invite codes are 32 lowercase hex characters (see `invites.code`).
    static func code(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in trimmed.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'.,;"))
            if let url = URL(string: word), let code = code(from: url), isCode(code) { return code }
        }
        let bare = trimmed.lowercased()
        return isCode(bare) ? bare : nil
    }

    static func isCode(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
