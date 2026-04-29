import Foundation

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var pendingRequests: [IncomingLinkRequest] = []
    @Published var outgoingLinks: [OutgoingLink] = []
    @Published var isLoading = false
    @Published var error: String?

    var pendingCount: Int { pendingRequests.count }

    func load(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        async let incoming: () = loadPending(userId: userId)
        async let outgoing: () = loadOutgoing(userId: userId)
        _ = await (incoming, outgoing)
    }

    private func loadPending(userId: UUID) async {
        do {
            pendingRequests = try await supabase
                .from("links")
                .select("*, sender:profiles!sender_id(display_name, avatar_url)")
                .eq("recipient_id", value: userId)
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadOutgoing(userId: UUID) async {
        do {
            outgoingLinks = try await supabase
                .from("links")
                .select("*, recipient:profiles!recipient_id(display_name, avatar_url)")
                .eq("sender_id", value: userId)
                .in("status", values: ["active", "paused"])
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }
    }

    func acceptRequest(_ request: IncomingLinkRequest) async {
        do {
            try await supabase
                .from("links")
                .update(["status": "active"])
                .eq("id", value: request.id)
                .execute()
            pendingRequests.removeAll { $0.id == request.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func declineRequest(_ request: IncomingLinkRequest) async {
        do {
            try await supabase
                .from("links")
                .update(["status": "declined"])
                .eq("id", value: request.id)
                .execute()
            pendingRequests.removeAll { $0.id == request.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeLink(_ link: OutgoingLink) async {
        do {
            try await supabase
                .from("links")
                .delete()
                .eq("id", value: link.id)
                .execute()
            outgoingLinks.removeAll { $0.id == link.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
