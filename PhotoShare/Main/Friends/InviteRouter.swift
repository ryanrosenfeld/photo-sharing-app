import Foundation

/// Holds an invite code from a `photoshare://invite/<code>` link (or a pasted link/code) until the user is signed in,
/// onboarded, and the accept screen can be shown.
///
/// The code is saved on the device, so it survives the app being killed during sign-up, or the user leaving for the
/// confirmation email. It is cleared once the accept screen is dismissed (accepted, declined, or not usable).
@MainActor
final class InviteRouter: ObservableObject {
    nonisolated static let storageKey = "invite.pendingCode"

    private let defaults: UserDefaults

    @Published var pendingCode: String? {
        didSet {
            if let pendingCode { defaults.set(pendingCode, forKey: Self.storageKey) }
            else { defaults.removeObject(forKey: Self.storageKey) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pendingCode = defaults.string(forKey: Self.storageKey)
    }

    /// Whether an invite is waiting, readable from places that don't hold the router (onboarding step logic).
    nonisolated static func hasStoredInvite(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: storageKey) != nil
    }

    /// Returns true if the URL was an invite link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let code = InviteLink.code(from: url) else { return false }
        pendingCode = code
        return true
    }
}
