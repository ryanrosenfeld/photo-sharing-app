import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var vm: FriendsViewModel
    @EnvironmentObject var reviewStore: ReviewQueueStore
    @EnvironmentObject var inviteRouter: InviteRouter
    @State private var showReview = false
    @State private var showInvite = false
    @State private var showPasteInvite = false
    @State private var showSuggestions = false
    @State private var pastedCode: String?
    @State private var detailFriend: Friend?
    @EnvironmentObject var enrollment: FaceEnrollmentSync
    @EnvironmentObject var pastPhotos: PastPhotosOffers

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("friends")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInvite = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("add friend")
                            .accessibilityIdentifier("friends.add")
                    }
                }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("ok") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
        .onChange(of: vm.friends) { _, friends in
            // Unfriended people must not linger as review recipients or overrides.
            reviewStore.prune(keeping: Set(friends.map(\.friendId)))
        }
        .sheet(isPresented: $showReview) { ReviewQueueView() }
        .sheet(isPresented: $showSuggestions, onDismiss: { Task { await vm.loadOpenInvites() } }) {
            FriendSuggestionsStep(embedded: true) { showSuggestions = false }
        }
        .sheet(isPresented: $showInvite, onDismiss: { Task { await vm.loadOpenInvites() } }) { AddFriendSheet() }
        .sheet(isPresented: $showPasteInvite, onDismiss: {
            if let pastedCode { inviteRouter.pendingCode = pastedCode; self.pastedCode = nil }
        }) { PasteInviteSheet(code: $pastedCode) }
        .task { await vm.loadOpenInvites() }
        .sheet(item: $detailFriend) { friend in FriendDetailSheet(friendId: friend.friendId) }
    }

    private var content: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                if vm.isLoading && vm.friends.isEmpty {
                    Spacer()
                    ProgressView().tint(OttoColor.sage)
                    Spacer()
                } else if vm.friends.isEmpty && reviewStore.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            // photos waiting for approval (manual review)
                            if !reviewStore.items.isEmpty {
                                reviewCard
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 16)
                            }
                            PastPhotosCard()
                                .padding(.horizontal, 16)
                                .padding(.bottom, pastPhotos.offers.isEmpty ? 0 : 16)
                            if !vm.friends.isEmpty {
                                friendsList
                                    .padding(.horizontal, 16)
                            }
                            footer
                                .padding(.top, 18)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                    }
                    .refreshable {
                        // Unstructured on purpose: the load re-renders this view, and SwiftUI cancels the refreshable
                        // task when that happens, which surfaced as an "Error: cancelled" alert on pull-to-refresh.
                        await Task { await vm.load() }.value
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            OttoMascot(pose: .friends, width: 240)
            VStack(spacing: 8) {
                Text("better with friends.")
                    .font(OttoFont.serifBoldItalic(size: 24))
                    .foregroundStyle(OttoColor.ink)
                Text("send an invite. once they accept, photos start flowing both ways.")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.bark)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 40)
            }
            Button { showInvite = true } label: {
                Label("add your first friend", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 10)
            }
            .modifier(ProminentGlassButton())
            .accessibilityIdentifier("friends.empty.invite")
            footer
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.empty")
    }

    // MARK: - Footer: invites waiting, paste a link

    private var footer: some View {
        VStack(spacing: 10) {
            Button("find people in your photos") { showSuggestions = true }
                .font(.system(size: 13))
                .foregroundStyle(OttoColor.sage)
                .accessibilityIdentifier("friends.findInPhotos")
            Button("have an invite link? paste it") { showPasteInvite = true }
                .font(.footnote)
                .foregroundStyle(OttoColor.sage)
                .accessibilityIdentifier("friends.pasteInvite")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Review card

    private var reviewCard: some View {
        Button {
            showReview = true
        } label: {
            OttoSectionCard {
                HStack(spacing: 14) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(OttoColor.sage)
                        .frame(width: 42, height: 42)
                        .background(OttoColor.sage.opacity(0.15))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(reviewStore.count) photo\(reviewStore.count == 1 ? "" : "s") to review")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OttoColor.ink)
                            .accessibilityIdentifier("friends.reviewQueue.count")
                        Text("held on your phone until you send them")
                            .font(.system(size: 13))
                            .foregroundStyle(OttoColor.barkSoft)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OttoColor.barkSoft.opacity(0.5))
                }
                .padding(16)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friends.reviewQueue")
    }

    // MARK: - Friends list

    private var friendsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(vm.friends.count) friend\(vm.friends.count != 1 ? "s" : "")")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OttoColor.barkSoft)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            OttoSectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(vm.friends.enumerated()), id: \.element.id) { idx, friend in
                        FriendRow(
                            friend: friend,
                            enrollment: enrollment.status(for: friend),
                            reviewOn: reviewStore.settings.requiresReview(for: friend.friendId),
                            onOpen: { detailFriend = friend }
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
    let enrollment: EnrollmentStatus?
    let reviewOn: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    OttoAvatarCircle(name: friend.displayName, size: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(friend.displayName)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(OttoColor.ink)
                            if reviewOn {
                                Text("review")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(OttoColor.sage.opacity(0.15))
                                    .foregroundStyle(OttoColor.sageDark)
                                    .clipShape(Capsule())
                                    .accessibilityIdentifier("friends.row.review")
                            }
                        }
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
            .accessibilityLabel("\(friend.displayName), \(friend.statusLine)" + (reviewOn ? ", review before sending" : ""))
            .accessibilityIdentifier("friends.row")

            if let enrollment { EnrollmentChip(status: enrollment, name: friend.displayName) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

extension Friend {
    /// One line summarising both toggles; "Paused" when my photos can't reach them.
    var statusLine: String {
        if isPaused { return "paused: \(displayName) isn't receiving" }
        switch (mySend, myReceive) {
        case (true, true): return "sharing both ways"
        case (true, false): return "only sending"
        case (false, true): return "only receiving"
        case (false, false): return "not sharing"
        }
    }
}

// MARK: - Face recognition status

/// Replaces the old "Enroll" button: enrollment is automatic, so the row only says where it stands.
struct EnrollmentChip: View {
    let status: EnrollmentStatus
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .settingUp: ProgressView().controlSize(.mini)
            default: Image(systemName: icon)
            }
            Text(label)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(status == .ready ? OttoColor.sage.opacity(0.15) : OttoColor.chip)
        .foregroundStyle(status == .ready ? OttoColor.sageDark : OttoColor.bark)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EnrollmentChip.explanation(status, name: name))
        .accessibilityIdentifier("friends.enrollment.\(EnrollmentChip.key(status))")
    }

    private var icon: String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .waitingForThem: "hourglass"
        case .noFaceProfile: "person.crop.circle.badge.questionmark"
        case .failed: "exclamationmark.circle"
        case .settingUp: ""
        }
    }

    private var label: String {
        switch status {
        case .ready: "ready"
        case .settingUp: "setting up"
        case .waitingForThem: "waiting"
        case .noFaceProfile: "no photos"
        case .failed: "retrying"
        }
    }

    static func key(_ status: EnrollmentStatus) -> String {
        switch status {
        case .ready: "ready"
        case .settingUp: "settingUp"
        case .waitingForThem: "waiting"
        case .noFaceProfile: "noProfile"
        case .failed: "failed"
        }
    }

    static func explanation(_ status: EnrollmentStatus, name: String) -> String {
        switch status {
        case .ready: "your phone can recognize \(name) in new photos."
        case .settingUp: "getting ready to recognize \(name)."
        case .waitingForThem: "waiting for \(name) to open otto, so their phone can share their face photos with yours."
        case .noFaceProfile: "\(name) hasn't added face photos yet, so their photos can't be matched."
        case .failed: "couldn't load \(name)'s face photos. otto tries again next time you open it."
        }
    }
}

// MARK: - Friend detail (toggles, unfriend)

struct FriendDetailSheet: View {
    @EnvironmentObject var vm: FriendsViewModel
    @EnvironmentObject var reviewStore: ReviewQueueStore
    @EnvironmentObject var enrollment: FaceEnrollmentSync
    @EnvironmentObject var auth: AuthManager
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
                        Button("done") { dismiss() }
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
                                title: "send",
                                detail: "share photos of \(friend.displayName) with them, automatically.",
                                id: "friend.send",
                                isOn: Binding(get: { friend.mySend }, set: { on in Task { await vm.setSend(on, for: friend) } })
                            )
                            Divider().background(OttoColor.line).padding(.leading, 16)
                            toggleRow(
                                title: "receive",
                                detail: "get photos \(friend.displayName) shares of you.",
                                id: "friend.receive",
                                isOn: Binding(get: { friend.myReceive }, set: { on in Task { await vm.setReceive(on, for: friend) } })
                            )
                            Divider().background(OttoColor.line).padding(.leading, 16)
                            toggleRow(
                                title: "review before sending",
                                detail: reviewDetail(for: friend),
                                id: "friend.review",
                                isOn: Binding(
                                    get: { reviewStore.settings.requiresReview(for: friend.friendId) },
                                    set: { reviewStore.setOverride($0, for: friend.friendId) }
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    if reviewStore.settings.friendOverrides[friend.friendId.uuidString] != nil {
                        Button("use my default (\(reviewStore.settings.globalEnabled ? "review" : "send automatically"))") {
                            reviewStore.setOverride(nil, for: friend.friendId)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OttoColor.sage)
                        .padding(.top, 10)
                        .accessibilityIdentifier("friend.review.reset")
                    }

                    if let status = enrollment.status(for: friend) {
                        HStack(alignment: .top, spacing: 10) {
                            EnrollmentChip(status: status, name: friend.displayName)
                            Text(EnrollmentChip.explanation(status, name: friend.displayName))
                                .font(.system(size: 13))
                                .foregroundStyle(OttoColor.bark)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("friend.enrollment.explanation")
                            if status != .settingUp, status != .noFaceProfile, let me = auth.session?.user.id {
                                Button("refresh") { Task { await enrollment.refresh(friend, viewer: me, friends: vm.friends) } }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OttoColor.sage)
                                    .accessibilityIdentifier("friend.enrollment.refresh")
                            }
                        }
                        .padding(.horizontal, 24).padding(.top, 14)
                    }

                    if friend.isPaused {
                        Text("\(friend.displayName) has turned off receiving, so your photos of them aren't being delivered.")
                            .font(.system(size: 13))
                            .foregroundStyle(OttoColor.bark)
                            .padding(.horizontal, 24).padding(.top, 12)
                    }

                    Spacer()

                    OttoPillButton(title: "unfriend", isDestructive: true) { confirmUnfriend = true }
                        .accessibilityIdentifier("friend.unfriend")
                        .padding(.horizontal, 28).padding(.bottom, 30)
                }
                .confirmationDialog("unfriend \(friend.displayName)?", isPresented: $confirmUnfriend, titleVisibility: .visible) {
                    Button("unfriend", role: .destructive) {
                        Task {
                            await vm.unfriend(friend)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("friend.unfriend.confirm")
                } message: {
                    Text("you'll stop sharing photos with each other. photos already shared stay where they are.")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func reviewDetail(for friend: Friend) -> String {
        let overridden = reviewStore.settings.friendOverrides[friend.friendId.uuidString] != nil
        let on = reviewStore.settings.requiresReview(for: friend.friendId)
        let base = on
            ? "photos of \(friend.displayName) wait in friends until you approve them."
            : "photos of \(friend.displayName) are sent as soon as they're matched."
        return overridden ? base : base + " (following your default.)"
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
    @State private var copied = false
    @State private var shared = false


    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("add a friend")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                    Spacer()
                }
                .overlay(alignment: .leading) {
                    Button("done") { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(OttoColor.sage)
                        .accessibilityIdentifier("invite.done")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 10) {
                            Text("send them a link.")
                                .font(OttoFont.serifBoldItalic(size: 26))
                                .foregroundStyle(OttoColor.ink)
                            Text("they open it and accept, and you start sharing photos of each other. together? have them scan the code with their camera.")
                                .font(.system(size: 15))
                                .foregroundStyle(OttoColor.bark)
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                        }
                        .padding(.top, 12)

                        if let code {
                            InviteQRCode(url: InviteLink.url(code: code))
                                .frame(width: 200, height: 200)

                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .font(.system(size: 14))
                                    .foregroundStyle(OttoColor.barkSoft)
                                Text(InviteLink.url(code: code).absoluteString)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(OttoColor.bark)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("invite.link")
                                Spacer(minLength: 0)
                                Button(copied ? "copied" : "copy") {
                                    UIPasteboard.general.string = InviteLink.url(code: code).absoluteString
                                    FriendsViewModel.markShared(code)
                                    copied = true
                                    shared = true
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(OttoColor.sage)
                                .accessibilityIdentifier("invite.copy")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(OttoColor.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(OttoColor.lineSoft, lineWidth: 0.5))

                            Text("works for one person and expires in 14 days.")
                                .font(.system(size: 12))
                                .foregroundStyle(OttoColor.barkSoft)
                        } else if failed {
                            Button("couldn't create a link. try again") { Task { await load(fresh: false) } }
                                .foregroundStyle(OttoColor.wax)
                                .accessibilityIdentifier("invite.retry")
                        } else {
                            ProgressView().tint(OttoColor.sage).frame(height: 200)
                        }

                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }

                if let code {
                    VStack(spacing: 10) {
                        ShareLink(
                            item: InviteLink.url(code: code),
                            message: Text(InviteMessage.text(from: auth.currentProfile?.displayName))
                        ) {
                            Text("share invite")
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(OttoColor.sage)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            FriendsViewModel.markShared(code)
                            shared = true
                        })
                        .accessibilityIdentifier("invite.share")

                        if shared {
                            Button("new link for someone else") { Task { await load(fresh: true) } }
                                .font(.system(size: 14))
                                .foregroundStyle(OttoColor.barkSoft)
                                .accessibilityIdentifier("invite.another")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .padding(.top, 8)
                }
            }
        }
        .task { await load(fresh: false) }
    }

    private func load(fresh: Bool) async {
        failed = false
        copied = false
        shared = false
        if fresh { code = nil }
        code = await vm.inviteToShare(fresh: fresh)
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

    private var name: String { preview?.inviterName ?? "someone" }

    /// accept_invite turns my Send off when I'm already at the free plan's limit; say so instead of surprising them.
    private var sendStartsPaused: Bool {
        guard let id = preview?.inviterId, let friend = vm.friends.first(where: { $0.friendId == id }) else { return false }
        return !friend.mySend
    }

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                if preview == nil {
                    ProgressView().tint(OttoColor.sage)
                } else if accepted {
                    OttoMascot(pose: .friends, width: 200)
                    Text("you and \(name) are friends")
                        .font(OttoFont.serifBold(size: 24)).foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("invite.accepted")
                    if sendStartsPaused {
                        Text("sending to \(name) starts off: free accounts auto-share with up to 3 friends. turn send off for someone else, then on for \(name), in friends.")
                            .font(.system(size: 14)).foregroundStyle(OttoColor.wax).multilineTextAlignment(.center)
                            .accessibilityIdentifier("invite.sendPaused")
                    } else {
                        Text("change what you send and receive anytime from the friends tab.")
                            .font(.system(size: 14)).foregroundStyle(OttoColor.bark).multilineTextAlignment(.center)
                    }
                    OttoPillButton(title: "done") { dismiss() }.accessibilityIdentifier("invite.done")
                } else if preview?.state == "valid" {
                    OttoAvatarCircle(name: name, size: 72)
                    Text("\(name) wants to be friends")
                        .font(OttoFont.serifBold(size: 26)).foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("invite.title")
                    Text("you'll automatically share photos of each other when you appear in them. you choose per friend whether to send and receive.")
                        .font(.system(size: 14)).foregroundStyle(OttoColor.bark)
                        .multilineTextAlignment(.center).lineSpacing(2)
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(OttoColor.wax) }
                    OttoPillButton(title: isWorking ? "accepting…" : "accept") { Task { await accept() } }
                        .disabled(isWorking)
                        .accessibilityIdentifier("invite.accept")
                    Button("not now") { dismiss() }
                        .foregroundStyle(OttoColor.barkSoft)
                        .accessibilityIdentifier("invite.decline")
                } else {
                    OttoMascot(pose: .sleeping, width: 200)
                    Text(Self.problem(for: preview?.state ?? "unknown", name: name))
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("invite.problem")
                    OttoPillButton(title: "ok") { dismiss() }.accessibilityIdentifier("invite.done")
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
        case "used": return "this invite link has already been used."
        case "expired": return "this invite link has expired. ask \(name) for a new one."
        case "self": return "this is your own invite link. send it to a friend instead."
        case "already_friends": return "you and \(name) are already friends."
        default: return "this invite link isn't valid."
        }
    }
}


private struct ProminentGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent).tint(OttoColor.sage).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).tint(OttoColor.sage).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}
