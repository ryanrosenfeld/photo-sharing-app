import Foundation

/// Holds an invite code from a `photoshare://invite/<code>` link until the user is signed in
/// and the accept screen can be shown.
@MainActor
final class InviteRouter: ObservableObject {
    @Published var pendingCode: String?

    /// Returns true if the URL was an invite link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let code = InviteLink.code(from: url) else { return false }
        pendingCode = code
        return true
    }
}
