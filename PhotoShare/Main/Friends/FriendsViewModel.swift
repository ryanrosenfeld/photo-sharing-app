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
        } catch is CancellationError {
            // a superseded refresh, not a failure
        } catch let urlError as URLError where urlError.code == .cancelled {
            // same: the request was cancelled mid-flight
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

    /// My invites that nobody has used yet and that haven't expired, newest first ("Invites waiting").
    @Published var openInvites: [OpenInvite] = []

    func loadOpenInvites() async {
        do {
            openInvites = try await supabase.from("invites")
                .select("code, created_at, expires_at")
                .is("accepted_at", value: nil)
                .gt("expires_at", value: ISO8601DateFormatter().string(from: Date()))
                .order("created_at", ascending: false)
                .execute().value
        } catch {
            print("[Friends] Couldn't load open invites: \(error)")
        }
    }

    /// Links already handed to someone (shared or copied), remembered on this device. A link is single-use, so a
    /// shared one must not be offered again for a second person.
    private static let sharedKey = "invite.sharedCodes"
    static func markShared(_ code: String, defaults: UserDefaults = .standard) {
        var codes = defaults.stringArray(forKey: sharedKey) ?? []
        if !codes.contains(code) { codes = Array((codes + [code]).suffix(50)) }
        defaults.set(codes, forKey: sharedKey)
    }
    static func wasShared(_ code: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: sharedKey) ?? []).contains(code)
    }

    /// The link to show on Add Friend: reuse my newest open invite that hasn't been handed to anyone yet, so opening
    /// Add Friend repeatedly doesn't pile up unused links. Pass `fresh` to force a new one.
    func inviteToShare(fresh: Bool = false) async -> String? {
        if !fresh {
            await loadOpenInvites()
            if let reusable = openInvites.first(where: {
                $0.expiresAt.timeIntervalSinceNow > 3 * 86_400 && !Self.wasShared($0.code)
            }) {
                return reusable.code
            }
        }
        let code = await createInvite()
        await loadOpenInvites()
        return code
    }

    func cancelInvite(_ code: String) async {
        do {
            try await supabase.from("invites").delete().eq("code", value: code).execute()
            openInvites.removeAll { $0.code == code }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Who sent an invite, for a signed-out person (welcome screen). Nil when the code is unknown or offline.
    nonisolated static func publicPreview(code: String) async -> PublicInvitePreview? {
        guard let rows: [PublicInvitePreview] = try? await supabase
            .rpc("preview_invite_public", params: ["p_code": code]).execute().value
        else { return nil }   // offline: say nothing rather than "invalid"
        return rows.first ?? PublicInvitePreview(inviterName: nil, usable: false)
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
        if text.contains("send_limit") { return "free accounts can auto-share with up to 3 friends. turn send off for another friend first." }
        if text.contains("invite_used") { return "this invite link has already been used." }
        if text.contains("invite_expired") { return "this invite link has expired." }
        if text.contains("invite_self") { return "that's your own invite link." }
        if text.contains("already_friends") { return "you're already friends." }
        if text.contains("invite_unknown") { return "this invite link isn't valid." }
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
