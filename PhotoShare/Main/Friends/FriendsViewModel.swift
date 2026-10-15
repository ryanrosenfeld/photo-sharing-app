import Foundation

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [Friend] = []
    @Published var isLoading = false
    @Published var error: String?

    /// Friends I currently auto-share with: Send ON and the friend's Receive ON.
    var sendTargets: [Friend] { friends.filter { $0.mySend && $0.theirReceive } }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            friends = try await supabase.rpc("list_friends").execute().value
            pruneEnrollments()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Drop local face embeddings for anyone who is no longer a friend (unfriended from either side).
    private func pruneEnrollments() {
        FaceEnrollmentStore().prune(keeping: Set(friends.map(\.friendId)))
    }

    func setSend(_ on: Bool, for friend: Friend) async {
        await update(friend, send: on, receive: nil)
    }

    func setReceive(_ on: Bool, for friend: Friend) async {
        await update(friend, send: nil, receive: on)
    }

    private func update(_ friend: Friend, send: Bool?, receive: Bool?) async {
        do {
            try await supabase.rpc("set_friend_prefs", params: PrefsParams(p_friend: friend.friendId, p_send: send, p_receive: receive)).execute()
        } catch {
            self.error = Self.message(for: error)
        }
        await load()   // authoritative state, also reverts a toggle the server refused
    }

    func unfriend(_ friend: Friend) async {
        do {
            try await supabase.rpc("unfriend", params: ["p_friend": friend.friendId]).execute()
            FaceEnrollmentStore().remove(for: friend.friendId)
            friends.removeAll { $0.friendId == friend.friendId }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createInvite() async -> String? {
        do {
            return try await supabase.rpc("create_invite").execute().value
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func preview(code: String) async -> InvitePreview? {
        do {
            let rows: [InvitePreview] = try await supabase.rpc("preview_invite", params: ["p_code": code]).execute().value
            return rows.first
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Returns nil on success, otherwise a user-facing message.
    func accept(code: String) async -> String? {
        do {
            let _: UUID = try await supabase.rpc("accept_invite", params: ["p_code": code]).execute().value
            await load()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("send_limit") { return "Free accounts can auto-share with up to 3 friends. Turn Send off for another friend first." }
        if text.contains("invite_used") { return "This invite link has already been used." }
        if text.contains("invite_expired") { return "This invite link has expired." }
        if text.contains("invite_self") { return "That's your own invite link." }
        if text.contains("already_friends") { return "You're already friends." }
        if text.contains("invite_unknown") { return "This invite link isn't valid." }
        return text
    }
}

private struct PrefsParams: Encodable {
    let p_friend: UUID
    let p_send: Bool?
    let p_receive: Bool?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_friend, forKey: .p_friend)
        try c.encodeIfPresent(p_send, forKey: .p_send)
        try c.encodeIfPresent(p_receive, forKey: .p_receive)
    }
    enum CodingKeys: String, CodingKey { case p_friend, p_send, p_receive }
}
