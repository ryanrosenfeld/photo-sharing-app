import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var vm: FriendsViewModel
    @State private var showInvite = false
    @State private var detailFriend: Friend?
    @State private var enrollingFriend: Friend?

    private let enrollmentStore = FaceEnrollmentStore()

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if vm.isLoading && vm.friends.isEmpty {
                    Spacer()
                    ProgressView().tint(OttoColor.sage)
                    Spacer()
                } else if vm.friends.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        friendsList
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 110)
                    }
                    .refreshable { await vm.load() }
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
        .sheet(isPresented: $showInvite) { AddFriendSheet() }
        .sheet(item: $detailFriend) { friend in FriendDetailSheet(friendId: friend.friendId) }
        .sheet(item: $enrollingFriend) { friend in
            FaceEnrollmentView(
                friendId: friend.friendId,
                friendName: friend.displayName,
                friendHasFaceProfile: friend.faceProfileEnabled
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                OttoEyebrow(text: "Friends")
                Text("Your circle")
                    .font(OttoFont.serifBold(size: 32))
                    .foregroundStyle(OttoColor.ink)
            }
            Spacer()
            Button { showInvite = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(OttoColor.sage)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Add Friend")
            .accessibilityIdentifier("friends.add")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            OttoMascot(pose: .friends, width: 240)
            VStack(spacing: 8) {
                Text("Better with friends.")
                    .font(OttoFont.serifBoldItalic(size: 24))
                    .foregroundStyle(OttoColor.ink)
                Text("Send an invite. Once they accept, photos start flowing both ways.")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.bark)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 40)
            }
            Button { showInvite = true } label: {
                Label("Add your first friend", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(OttoColor.sage)
                    .clipShape(Capsule())
            }
            .accessibilityIdentifier("friends.empty.invite")
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.empty")
    }

    // MARK: - Friends list

    private var friendsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(vm.friends.count) friend\(vm.friends.count != 1 ? "s" : "")")
                .font(.system(size: 12, weight: .semibold))
                .kerning(1.4)
                .textCase(.uppercase)
                .foregroundStyle(OttoColor.barkSoft)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            OttoSectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(vm.friends.enumerated()), id: \.element.id) { idx, friend in
                        FriendRow(
                            friend: friend,
                            isEnrolled: enrollmentStore.hasEnrollment(for: friend.friendId),
                            onOpen: { detailFriend = friend },
                            onEnroll: { enrollingFriend = friend }
                        )
                        if idx < vm.friends.count - 1 {
                            Divider().background(OttoColor.line).padding(.leading, 70)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct FriendRow: View {
    let friend: Friend
    let isEnrolled: Bool
    let onOpen: () -> Void
    let onEnroll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    OttoAvatarCircle(name: friend.displayName, size: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(friend.displayName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(OttoColor.ink)
                        Text(friend.statusLine)
                            .font(.system(size: 13))
                            .foregroundStyle(friend.isPaused ? OttoColor.wax : OttoColor.barkSoft)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(friend.displayName), \(friend.statusLine)")
            .accessibilityIdentifier("friends.row")

            Button(action: onEnroll) {
                Label(isEnrolled ? "Enrolled" : "Enroll", systemImage: isEnrolled ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isEnrolled ? OttoColor.sage.opacity(0.15) : OttoColor.chip)
                    .foregroundStyle(isEnrolled ? OttoColor.sageDark : OttoColor.bark)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends.link.enroll")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

extension Friend {
    /// One line summarising both toggles; "Paused" when my photos can't reach them.
    var statusLine: String {
        if isPaused { return "Paused: \(displayName) isn't receiving" }
        switch (mySend, myReceive) {
        case (true, true): return "Sharing both ways"
        case (true, false): return "Only sending"
        case (false, true): return "Only receiving"
        case (false, false): return "Not sharing"
        }
    }
}

// MARK: - Friend detail (toggles, unfriend)

struct FriendDetailSheet: View {
    @EnvironmentObject var vm: FriendsViewModel
    @Environment(\.dismiss) private var dismiss
    let friendId: UUID
    @State private var confirmUnfriend = false

    /// Rendered from the view model so toggles reflect the server's answer (a refused change snaps back).
    private var friend: Friend? { vm.friends.first { $0.friendId == friendId } }

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            if let friend {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(OttoColor.sage)
                            .accessibilityIdentifier("friend.done")
                    }
                    .padding(.horizontal, 20).padding(.top, 16)

                    VStack(spacing: 10) {
                        OttoAvatarCircle(name: friend.displayName, size: 72)
                        Text(friend.displayName)
                            .font(OttoFont.serifBold(size: 28))
                            .foregroundStyle(OttoColor.ink)
                        Text(friend.statusLine)
                            .font(.system(size: 14))
                            .foregroundStyle(friend.isPaused ? OttoColor.wax : OttoColor.barkSoft)
                    }
                    .padding(.top, 8).padding(.bottom, 20)

                    OttoSectionCard {
                        VStack(spacing: 0) {
                            toggleRow(
                                title: "Send",
                                detail: "Share photos of \(friend.displayName) with them, automatically.",
                                id: "friend.send",
                                isOn: Binding(get: { friend.mySend }, set: { on in Task { await vm.setSend(on, for: friend) } })
                            )
                            Divider().background(OttoColor.line).padding(.leading, 16)
                            toggleRow(
                                title: "Receive",
                                detail: "Get photos \(friend.displayName) shares of you.",
                                id: "friend.receive",
                                isOn: Binding(get: { friend.myReceive }, set: { on in Task { await vm.setReceive(on, for: friend) } })
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    if friend.isPaused {
                        Text("\(friend.displayName) has turned off receiving, so your photos of them aren't being delivered.")
                            .font(.system(size: 13))
                            .foregroundStyle(OttoColor.bark)
                            .padding(.horizontal, 24).padding(.top, 12)
                    }

                    Spacer()

                    OttoPillButton(title: "Unfriend", isDestructive: true) { confirmUnfriend = true }
                        .accessibilityIdentifier("friend.unfriend")
                        .padding(.horizontal, 28).padding(.bottom, 30)
                }
                .confirmationDialog("Unfriend \(friend.displayName)?", isPresented: $confirmUnfriend, titleVisibility: .visible) {
                    Button("Unfriend", role: .destructive) {
                        Task {
                            await vm.unfriend(friend)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("friend.unfriend.confirm")
                } message: {
                    Text("You'll stop sharing photos with each other. Photos already shared stay where they are.")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func toggleRow(title: String, detail: String, id: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(OttoColor.ink)
                Text(detail).font(.system(size: 13)).foregroundStyle(OttoColor.barkSoft)
            }
        }
        .tint(OttoColor.sage)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Add friend (inviter side)

struct AddFriendSheet: View {
    @EnvironmentObject var vm: FriendsViewModel
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var code: String?
    @State private var failed = false

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Add a friend")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                    Spacer()
                }
                .overlay(alignment: .leading) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(OttoColor.sage)
                        .accessibilityIdentifier("invite.done")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                Spacer()

                VStack(spacing: 24) {
                    OttoMascot(pose: .floating, width: 180)

                    VStack(spacing: 12) {
                        Text("Send them a link.")
                            .font(OttoFont.serifBoldItalic(size: 26))
                            .foregroundStyle(OttoColor.ink)
                        Text("They open it, accept, and you start sharing photos of each other. The link works once and expires in 14 days.")
                            .font(.system(size: 15))
                            .foregroundStyle(OttoColor.bark)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .padding(.horizontal, 20)
                    }

                    if let code {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .font(.system(size: 14))
                                .foregroundStyle(OttoColor.barkSoft)
                            Text(InviteLink.url(code: code).absoluteString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(OttoColor.bark)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("invite.link")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(OttoColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OttoColor.lineSoft, lineWidth: 0.5))
                        .padding(.horizontal, 28)
                    } else if failed {
                        Button("Couldn't create a link. Try again") { Task { await create() } }
                            .foregroundStyle(OttoColor.wax)
                    } else {
                        ProgressView().tint(OttoColor.sage)
                    }
                }

                Spacer()

                if let code {
                    ShareLink(
                        item: InviteLink.url(code: code),
                        message: Text("\(auth.currentProfile?.displayName ?? "A friend") invited you to share photos on otto.")
                    ) {
                        Text("Share invite")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(OttoColor.sage)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .accessibilityIdentifier("invite.share")
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
                }
            }
        }
        .task { await create() }
    }

    private func create() async {
        failed = false
        code = await vm.createInvite()
        failed = code == nil
    }
}

// MARK: - Invite accept (invitee side)

/// Shown when a photoshare://invite/<code> link is opened.
struct InviteAcceptSheet: View {
    @EnvironmentObject var vm: FriendsViewModel
    @Environment(\.dismiss) private var dismiss
    let code: String
    @State private var preview: InvitePreview?
    @State private var isWorking = false
    @State private var message: String?
    @State private var accepted = false

    private var name: String { preview?.inviterName ?? "Someone" }

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                if preview == nil {
                    ProgressView().tint(OttoColor.sage)
                } else if accepted {
                    OttoMascot(pose: .friends, width: 200)
                    Text("You and \(name) are friends")
                        .font(OttoFont.serifBold(size: 24)).foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("invite.accepted")
                    Text("Change what you send and receive anytime from the Friends tab.")
                        .font(.system(size: 14)).foregroundStyle(OttoColor.bark).multilineTextAlignment(.center)
                    OttoPillButton(title: "Done") { dismiss() }.accessibilityIdentifier("invite.done")
                } else if preview?.state == "valid" {
                    OttoAvatarCircle(name: name, size: 72)
                    Text("\(name) wants to be friends")
                        .font(OttoFont.serifBold(size: 26)).foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("invite.title")
                    Text("You'll automatically share photos of each other when you appear in them. You choose per friend whether to send and receive.")
                        .font(.system(size: 14)).foregroundStyle(OttoColor.bark)
                        .multilineTextAlignment(.center).lineSpacing(2)
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(OttoColor.wax) }
                    OttoPillButton(title: isWorking ? "Accepting…" : "Accept") { Task { await accept() } }
                        .disabled(isWorking)
                        .accessibilityIdentifier("invite.accept")
                    Button("Not now") { dismiss() }
                        .foregroundStyle(OttoColor.barkSoft)
                        .accessibilityIdentifier("invite.decline")
                } else {
                    OttoMascot(pose: .sleeping, width: 200)
                    Text(Self.problem(for: preview?.state ?? "unknown", name: name))
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("invite.problem")
                    OttoPillButton(title: "OK") { dismiss() }.accessibilityIdentifier("invite.done")
                }
                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .presentationDetents([.large])
        .task {
            preview = await vm.preview(code: code) ?? InvitePreview(inviterId: nil, inviterName: nil, state: "unknown")
        }
    }

    private func accept() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await vm.accept(code: code) { message = failure } else { accepted = true }
    }

    static func problem(for state: String, name: String) -> String {
        switch state {
        case "used": return "This invite link has already been used."
        case "expired": return "This invite link has expired. Ask \(name) for a new one."
        case "self": return "This is your own invite link. Send it to a friend instead."
        case "already_friends": return "You and \(name) are already friends."
        default: return "This invite link isn't valid."
        }
    }
}
