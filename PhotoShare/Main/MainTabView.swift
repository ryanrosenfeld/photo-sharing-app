import Photos
import PhotosUI
import SwiftUI
import Supabase
import UserNotifications

struct MainTabView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var inviteRouter: InviteRouter
    @StateObject private var photosVM = PhotosViewModel()
    @StateObject private var friendsVM = FriendsViewModel()
    @StateObject private var processor = AutoShareProcessor()
    @StateObject private var reviewStore = ReviewQueueStore()
    @StateObject private var enrollment = FaceEnrollmentSync()
    @State private var selectedTab: OttoTab = .photos

    var body: some View {
        ZStack(alignment: .bottom) {
            OttoColor.canvas.ignoresSafeArea()

            // Keep all views alive in the ZStack; use opacity to switch — preserves scroll position
            ZStack {
                PhotosView()
                    .environmentObject(photosVM)
                    .environmentObject(authManager)
                    .opacity(selectedTab == .photos ? 1 : 0)
                    .allowsHitTesting(selectedTab == .photos)

                FriendsView()
                    .environmentObject(friendsVM)
                    .opacity(selectedTab == .friends ? 1 : 0)
                    .allowsHitTesting(selectedTab == .friends)

                NavigationStack {
                    OttoProfileView()
                        .environmentObject(authManager)
                }
                .opacity(selectedTab == .profile ? 1 : 0)
                .allowsHitTesting(selectedTab == .profile)
            }

            OttoTabBarView(selected: $selectedTab, friendsBadge: reviewStore.count)
        }
        .ignoresSafeArea(.keyboard)
        .environmentObject(reviewStore)
        .environmentObject(friendsVM)
        .environmentObject(enrollment)
        .sheet(item: Binding(
            get: { inviteRouter.pendingCode.map(PendingInvite.init) },
            set: { if $0 == nil { inviteRouter.pendingCode = nil } }
        )) { invite in
            InviteAcceptSheet(code: invite.code).environmentObject(friendsVM)
        }
        // A deep link can arrive while another tab is showing; the accept sheet is global, but land on Friends afterwards.
        .onChange(of: inviteRouter.pendingCode) { _, code in
            if code != nil { selectedTab = .friends }
        }
        .task {
            guard let userId = authManager.session?.user.id else { return }
            reviewStore.bind(userId: userId)
            PendingShareStore.shared.bind(userId: userId)
            await processor.libraryManager.requestAccess()
            async let p: () = photosVM.load(userId: userId)
            async let f: () = friendsVM.load()
            _ = await (p, f)
            await syncEncryption(userId: userId)
            await enrollment.sync(viewer: userId, friends: friendsVM.friends)
            await processor.processNewPhotos(userId: userId, friends: friendsVM.friends, review: reviewStore)
        }
        // A new friend (invite accepted on either side): hand them our face-profile key now, and enroll them as soon
        // as theirs is readable, instead of waiting for the next launch.
        .onChange(of: friendsVM.friends.map(\.friendId)) { old, new in
            guard let userId = authManager.session?.user.id, !Set(new).isSubset(of: Set(old)) else { return }
            Task {
                await FaceProfileManager.syncKeys(userId: userId, friendIds: new)
                await enrollment.sync(viewer: userId, friends: friendsVM.friends)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let userId = authManager.session?.user.id else { return }
            reviewStore.bind(userId: userId)
            PendingShareStore.shared.bind(userId: userId)
            Task {
                await friendsVM.load()   // pick up new friends and the other side's toggle changes
                await syncEncryption(userId: userId)
                await enrollment.sync(viewer: userId, friends: friendsVM.friends)
                await processor.processNewPhotos(userId: userId, friends: friendsVM.friends, review: reviewStore)
            }
        }
    }
}

extension MainTabView {
    /// Hands friends the key to your face profile, and delivers photos that were waiting on a friend's key.
    fileprivate func syncEncryption(userId: UUID) async {
        await FaceProfileManager.syncKeys(userId: userId, friendIds: friendsVM.friends.map(\.friendId))
        await queuePhotosForAcceptedInvites()
        await PendingShareStore.shared.retry(senderId: userId, friends: friendsVM.friends)
    }
}

extension MainTabView {
    /// Onboarding suggestions can promise someone "our photos together" once they join. When that invite has been
    /// accepted, hand those photos to the normal send path (review mode applies; photos deleted since are skipped later).
    fileprivate func queuePhotosForAcceptedInvites() async {
        InvitedPhotosStore.prune()
        let waiting = InvitedPhotosStore.all()
        guard !waiting.isEmpty else { return }
        struct Row: Decodable {
            let code: String
            let acceptedBy: UUID?
            enum CodingKeys: String, CodingKey { case code; case acceptedBy = "accepted_by" }
        }
        guard let rows: [Row] = try? await supabase.from("invites")
            .select("code, accepted_by").in("code", values: waiting.map(\.code)).execute().value else { return }
        for row in rows {
            guard let friendId = row.acceptedBy, let entry = waiting.first(where: { $0.code == row.code }),
                  let friend = friendsVM.friends.first(where: { $0.friendId == friendId }) else { continue }
            if friend.mySend && friend.theirReceive {
                let (sendNow, toReview) = reviewStore.settings.partition([friendId])
                for assetId in entry.assetIds {
                    if !sendNow.isEmpty { PendingShareStore.shared.add(assetId: assetId, recipientIds: sendNow) }
                    if !toReview.isEmpty {
                        reviewStore.enqueue(assetId: assetId, takenAt: Date(), recipients: [.init(id: friendId, name: friend.displayName)])
                    }
                }
            }
            InvitedPhotosStore.remove(code: row.code)
        }
    }
}

private struct PendingInvite: Identifiable {
    let code: String
    var id: String { code }
}

// MARK: - Tab enum

enum OttoTab: Hashable {
    case photos, friends, profile
}

// MARK: - Custom Otto tab bar

struct OttoTabBarView: View {
    @Binding var selected: OttoTab
    /// Photos waiting in the manual-review queue, shown on the Friends tab.
    var friendsBadge: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            tabItem(tab: .photos, label: "photos", icon: "photo.stack")
            tabItem(tab: .friends, label: "friends", icon: "person.2", badge: friendsBadge)
            tabItem(tab: .profile, label: "profile", icon: "person.circle")
        }
        .padding(.top, 8)
        .padding(.bottom, 28)
        .background(
            OttoColor.surface
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundStyle(OttoColor.line)
                }
        )
    }

    private func tabItem(tab: OttoTab, label: String, icon: String, badge: Int = 0) -> some View {
        Button {
            selected = tab
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: selected == tab ? .medium : .light))
                        .symbolVariant(selected == tab ? .fill : .none)
                        .foregroundStyle(selected == tab ? OttoColor.sage : OttoColor.barkSoft)

                    if badge > 0 {
                        Text(badge > 9 ? "9+" : "\(badge)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(OttoColor.wax)
                            .clipShape(Capsule())
                            .offset(x: 8, y: -2)
                    }
                }

                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected == tab ? OttoColor.sage : OttoColor.barkSoft)
                    .kerning(0.2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(label), \(badge) to review" : label)
        .accessibilityAddTraits(selected == tab ? .isSelected : [])
        .accessibilityIdentifier("tab.\(label.lowercased())")
    }
}

// MARK: - Profile tab

struct OttoProfileView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var notifStatus = UNAuthorizationStatus.notDetermined

    private var photosOK: Bool { photoStatus == .authorized || photoStatus == .limited }
    private var photoSub: String {
        switch photoStatus {
        case .authorized: "all photos · allowed"
        case .limited: "only selected photos · tap to allow all"
        default: "off · new photos aren't being shared. tap to fix"
        }
    }
    private var notifSub: String {
        notifStatus == .authorized ? "allowed" : "off · tap to turn on in settings"
    }
    private func refreshPermissions() async {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @EnvironmentObject var authManager: AuthManager
    @State private var showEditName = false
    @State private var editedName = ""
    @State private var showFaceProfileSetup = false
    @EnvironmentObject var reviewStore: ReviewQueueStore

    private var profile: UserProfile? { authManager.currentProfile }

    var body: some View {
        content.task(id: scenePhase) { await refreshPermissions() }
    }

    private var content: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // header
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            OttoEyebrow(text: "profile")
                            Text("settings")
                                .font(OttoFont.serifBold(size: 32))
                                .foregroundStyle(OttoColor.ink)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                    // identity row
                    HStack(spacing: 14) {
                        OttoAvatarCircle(name: profile?.displayName ?? "?", size: 56, hue: OttoColor.sage)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile?.displayName ?? "loading…")
                                .font(OttoFont.serifBold(size: 20))
                                .foregroundStyle(OttoColor.ink)
                            Text(profile?.plan.displayName ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(OttoColor.barkSoft)
                        }

                        Spacer()

                        Button("edit") {
                            editedName = profile?.displayName ?? ""
                            showEditName = true
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OttoColor.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(OttoColor.line, lineWidth: 1))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                    // plan card
                    if profile?.plan.isPro == false {
                        freePlanCard
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 18)
                    } else {
                        proPlanCard
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 18)
                    }

                    // My reference photos
                    profileSection(title: "my reference photos") {
                        OttoSectionCard {
                            VStack(spacing: 0) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile?.faceProfileEnabled == true ? "set up" : "not set up")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(OttoColor.ink)
                                        Text("fresh, clear photos help friends' phones recognize you")
                                            .font(.system(size: 13))
                                            .foregroundStyle(OttoColor.barkSoft)
                                    }
                                    Spacer()
                                    Button(profile?.faceProfileEnabled == true ? "manage" : "set up") {
                                        showFaceProfileSetup = true
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OttoColor.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(OttoColor.chip)
                                    .clipShape(Capsule())
                                }
                                .padding(16)

                                // encryption note
                                HStack(alignment: .top, spacing: 10) {
                                    Circle()
                                        .fill(OttoColor.sage)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    Text("encrypted before they leave your phone. only your friends' devices can use them — and only to recognize you.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(OttoColor.bark)
                                        .lineSpacing(2)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(OttoColor.chip)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Sending
                    profileSection(title: "sending") {
                        OttoSectionCard {
                            settingsRow(
                                label: "review all photos before sending",
                                sub: reviewStore.settings.globalEnabled
                                    ? "matches wait in friends until you send them"
                                    : "approve every match before it goes",
                                hasToggle: true,
                                isOn: Binding(
                                    get: { reviewStore.settings.globalEnabled },
                                    set: { reviewStore.setGlobalEnabled($0) }
                                ),
                                toggleId: "profile.manualReview",
                                isLast: false
                            )
                            settingsRow(
                                label: "pause all sending",
                                sub: "photos hold until you turn it back on",
                                hasToggle: true,
                                isOn: .constant(false),
                                isLast: true
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Permissions
                    profileSection(title: "permissions") {
                        OttoSectionCard {
                            Button { if !photosOK || photoStatus == .limited { openSettings() } } label: {
                                settingsRowLabel(label: "photos", sub: photoSub, dot: photosOK && photoStatus != .limited, hasChev: !photosOK || photoStatus == .limited)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("profile.photoStatus")
                            Divider().padding(.leading, 16)
                            Button { if notifStatus != .authorized { openSettings() } } label: {
                                settingsRowLabel(label: "notifications", sub: notifSub, dot: notifStatus == .authorized, hasChev: notifStatus != .authorized)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("profile.notificationStatus")
                            Divider().padding(.leading, 16)
                            settingsRow(label: "location", sub: "when in use", dot: true, isLast: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Privacy
                    profileSection(title: "privacy") {
                        OttoSectionCard {
                            settingsRow(label: "what otto stores", sub: "your photos and face data are both encrypted", hasChev: true, isLast: false)
                            settingsRow(label: "privacy policy", hasChev: true, isLast: false)
                            settingsRow(label: "terms", hasChev: true, isLast: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Debug
                    #if DEBUG
                    profileSection(title: "debug") {
                        OttoSectionCard {
                            NavigationLink {
                                FaceMatchSandboxView()
                            } label: {
                                settingsRowLabel(label: "face match sandbox", hasChev: true)
                                    .padding(16)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    #endif

                    // Danger
                    VStack(spacing: 8) {
                        Button("sign out") {
                            Task { await authManager.signOut() }
                        }
                        .accessibilityIdentifier("profile.signOut")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(OttoColor.wax)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OttoColor.line, lineWidth: 1))
                        .padding(.horizontal, 16)

                        Button("delete account", role: .destructive) {}
                            .font(.system(size: 14))
                            .foregroundStyle(OttoColor.barkSoft)
                    }
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showEditName) {
            EditNameSheet(name: $editedName) {
                Task { await authManager.updateDisplayName(editedName) }
            }
        }
        .sheet(isPresented: $showFaceProfileSetup) {
            if let userId = authManager.session?.user.id {
                FaceProfileSetupSheet(
                    isEnabled: profile?.faceProfileEnabled ?? false,
                    userId: userId
                ) {
                    Task { await authManager.fetchProfile(userId: userId) }
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { authManager.error != nil },
            set: { if !$0 { authManager.clearError() } }
        )) {
            Button("ok") { authManager.clearError() }
        } message: {
            Text(authManager.error?.localizedDescription ?? "")
        }
    }

    private var freePlanCard: some View {
        OttoSectionCard {
            ZStack(alignment: .topTrailing) {
                OttoAvatarCircle(name: "O", size: 100, hue: OttoColor.sage)
                    .opacity(0.6)
                    .offset(x: 20, y: -20)

                VStack(alignment: .leading, spacing: 0) {
                    OttoEyebrow(text: "free plan", color: OttoColor.wax)
                        .padding(.bottom, 8)
                    Text("more friends?\notto can deliver.")
                        .font(OttoFont.serifBoldItalic(size: 22))
                        .foregroundStyle(OttoColor.ink)
                        .lineSpacing(2)
                        .padding(.bottom, 4)
                    Text("send to 3 friends free. pro removes the limit.")
                        .font(.system(size: 14))
                        .foregroundStyle(OttoColor.bark)
                        .lineSpacing(2)
                        .padding(.bottom, 14)
                    OttoPillButton(title: "try pro free for 7 days", isFullWidth: false) {}
                }
                .padding(18)
            }
        }
    }

    private var proPlanCard: some View {
        OttoSectionCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(OttoColor.sage)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("otto pro")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                    Text("renews soon · $4.99/mo")
                        .font(.system(size: 13))
                        .foregroundStyle(OttoColor.barkSoft)
                }
            }
            .padding(16)
        }
    }

    private func profileSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .kerning(1.4)
                .foregroundStyle(OttoColor.barkSoft)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            content()
        }
    }

    private func settingsRow(
        label: String,
        sub: String? = nil,
        hasToggle: Bool = false,
        isOn: Binding<Bool> = .constant(false),
        toggleId: String? = nil,
        hasChev: Bool = false,
        dot: Bool = false,
        isLast: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                settingsRowLabel(label: label, sub: sub, dot: dot, hasChev: hasChev)
                if hasToggle {
                    Toggle("", isOn: isOn)
                        .toggleStyle(OttoToggleStyle(id: toggleId))
                        .labelsHidden()
                }
                if hasChev {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(OttoColor.barkSoft.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !isLast {
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(OttoColor.line)
                    .padding(.leading, 16)
            }
        }
    }

    private func settingsRowLabel(label: String, sub: String? = nil, dot: Bool = false, hasChev: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(OttoColor.ink)
                if dot {
                    Circle()
                        .fill(OttoColor.sage)
                        .frame(width: 6, height: 6)
                }
            }
            if let sub {
                Text(sub)
                    .font(.system(size: 13))
                    .foregroundStyle(OttoColor.barkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Otto toggle style

struct OttoToggleStyle: ToggleStyle {
    var id: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? OttoColor.sage : OttoColor.line)
                    .frame(width: 51, height: 31)
                Circle()
                    .fill(.white)
                    .frame(width: 27, height: 27)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id ?? "")
        .animation(.spring(response: 0.2), value: configuration.isOn)
    }
}

// MARK: - Face profile setup sheet (unchanged functionality, reskinned)

/// Profile-tab entry to the same photo picker + on-device check used in onboarding.
/// The face profile is required, so there is deliberately no "turn off".
struct FaceProfileSetupSheet: View {
    let isEnabled: Bool
    let userId: UUID
    let onComplete: () -> Void

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            FaceProfileStep(userId: userId, step: nil, total: 0, title: "your reference photos", showsUploadedNote: isEnabled) {
                onComplete()
                dismiss()
            }
            .background(OttoColor.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }.foregroundStyle(OttoColor.sage)
                }
            }
        }
    }
}

// MARK: - Edit name sheet

struct EditNameSheet: View {
    @Binding var name: String
    @Environment(\.dismiss) var dismiss
    let onSave: () -> Void

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            NavigationStack {
                Form {
                    TextField("display name", text: $name)
                        .autocorrectionDisabled()
                }
                .scrollContentBackground(.hidden)
                .background(OttoColor.canvas)
                .navigationTitle("edit name")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { dismiss() }
                            .foregroundStyle(OttoColor.sage)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("save") {
                            onSave()
                            dismiss()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundStyle(OttoColor.sage)
                    }
                }
            }
        }
        .presentationDetents([.height(180)])
    }
}

#Preview {
    MainTabView().environmentObject(AuthManager())
}
