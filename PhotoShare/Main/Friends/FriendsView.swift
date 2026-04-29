import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var vm: FriendsViewModel
    @State private var enrollingLink: OutgoingLink?

    private let store = FaceEnrollmentStore()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.pendingRequests.isEmpty && vm.outgoingLinks.isEmpty {
                    ContentUnavailableView(
                        "No Friends Yet",
                        systemImage: "person.2",
                        description: Text("When someone sends you a link request, it will appear here.")
                    )
                } else {
                    List {
                        if !vm.pendingRequests.isEmpty {
                            Section("Requests") {
                                ForEach(vm.pendingRequests) { request in
                                    LinkRequestRow(request: request) {
                                        Task { await vm.acceptRequest(request) }
                                    } onDecline: {
                                        Task { await vm.declineRequest(request) }
                                    }
                                }
                            }
                        }

                        if !vm.outgoingLinks.isEmpty {
                            Section("Sharing With") {
                                ForEach(vm.outgoingLinks) { link in
                                    OutgoingLinkRow(
                                        link: link,
                                        isEnrolled: store.hasEnrollment(for: link.recipientId)
                                    ) {
                                        enrollingLink = link
                                    }
                                }
                                .onDelete { indexSet in
                                    for idx in indexSet {
                                        let link = vm.outgoingLinks[idx]
                                        Task { await vm.removeLink(link) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Friends")
            .alert("Error", isPresented: Binding(
                get: { vm.error != nil },
                set: { if !$0 { vm.error = nil } }
            )) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
            .sheet(item: $enrollingLink) { link in
                FaceEnrollmentView(friendId: link.recipientId, friendName: link.recipient.displayName)
            }
        }
    }
}

// MARK: - Request row

private struct LinkRequestRow: View {
    let request: IncomingLinkRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AvatarCircle(name: request.sender.displayName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.sender.displayName).font(.headline)
                    Text("Wants to auto-share photos with you")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button(action: onAccept) {
                    Text("Accept")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Button(action: onDecline) {
                    Text("Decline")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemFill))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Outgoing link row

private struct OutgoingLinkRow: View {
    let link: OutgoingLink
    let isEnrolled: Bool
    let onEnrollTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AvatarCircle(name: link.recipient.displayName, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(link.recipient.displayName).font(.headline)
                Text(link.isPaused ? "Paused" : "Auto-sharing on")
                    .font(.caption)
                    .foregroundStyle(link.isPaused ? .orange : .secondary)
            }

            Spacer()

            Button(action: onEnrollTap) {
                Label(
                    isEnrolled ? "Enrolled" : "Enroll Face",
                    systemImage: isEnrolled ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus"
                )
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isEnrolled ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12))
                .foregroundStyle(isEnrolled ? .green : .accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared avatar

struct AvatarCircle: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemFill))
            .frame(width: size, height: size)
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            )
    }
}
