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
    @StateObject private var pastPhotos = PastPhotosOffers()
    @ObservedObject private var indexer = FaceIndexer.shared
    @State private var selectedTab: OttoTab = .photos

    var body: some View {
        ZStack {
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

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OttoTabBarView(selected: $selectedTab, friendsBadge: reviewStore.count)
        }
        .ignoresSafeArea(.keyboard)
        .environmentObject(reviewStore)
        .environmentObject(friendsVM)
        .environmentObject(enrollment)
        .environmentObject(pastPhotos)
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
            startIndexing(userId: userId)
            await processor.processNewPhotos(userId: userId, friends: friendsVM.friends, review: reviewStore)
        }
        // The index grew (or finished): look again for new friends' past photos.
        .onChange(of: indexer.revision) { _, _ in
            Task { await pastPhotos.refresh(friends: friendsVM.friends, review: reviewStore, indexer: indexer) }
        }
        // A new friend (invite accepted on either side): hand them our face-profile key now, and enroll them as soon
        // as theirs is readable, instead of waiting for the next launch.
        .onChange(of: friendsVM.friends.map(\.friendId)) { old, new in
            guard let userId = authManager.session?.user.id, !Set(new).isSubset(of: Set(old)) else { return }
            Task {
                await FaceProfileManager.syncKeys(userId: userId, friendIds: new)
                await enrollment.sync(viewer: userId, friends: friendsVM.friends)
                await pastPhotos.refresh(friends: friendsVM.friends, review: reviewStore, indexer: indexer)
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
                startIndexing(userId: userId)
                await processor.processNewPhotos(userId: userId, friends: friendsVM.friends, review: reviewStore)
            }
        }
    }
}

extension MainTabView {
    /// Starts the incremental face-index scan (new photos first, then the backlog) and books a background window.
    fileprivate func startIndexing(userId: UUID) {
        pastPhotos.bind(userId: userId)
        indexer.start()
        FaceIndexer.scheduleBackgroundTask()
        Task { await pastPhotos.refresh(friends: friendsVM.friends, review: reviewStore, indexer: indexer) }
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

// MARK: - Custom Otto tab bar (floating Liquid Glass capsule)

struct OttoTabBarView: View {
    @Binding var selected: OttoTab
    /// Photos waiting in the manual-review queue, shown on the Friends tab.
    var friendsBadge: Int = 0
    @Namespace private var highlight

    var body: some View {
        OttoGlassGroup {
            HStack(spacing: 0) {
                tabItem(tab: .photos, label: "photos", icon: "photo.stack")
                tabItem(tab: .friends, label: "friends", icon: "person.2", badge: friendsBadge)
                tabItem(tab: .profile, label: "profile", icon: "person.crop.circle")
            }
            .padding(6)
            .ottoGlass(Capsule(), interactive: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selected)
    }

    private func tabItem(tab: OttoTab, label: String, icon: String, badge: Int = 0) -> some View {
        let isSelected = selected == tab
        return Button {
            selected = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .symbolVariant(isSelected ? .fill : .none)
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 9 ? "9+" : "\(badge)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .background(OttoColor.wax, in: Capsule())
                                .offset(x: 12, y: -4)
                        }
                    }
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(isSelected ? OttoColor.sageDark : OttoColor.bark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule()
                        .fill(OttoColor.sage.opacity(0.18))
                        .matchedGeometryEffect(id: "tab.highlight", in: highlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(label), \(badge) to review" : label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        case .authorized: "all photos"
        case .limited: "only selected photos · tap to allow all"
        default: "off · new photos aren't being shared. tap to fix"
        }
    }
    private var notifSub: String {
        notifStatus == .authorized ? "on" : "off · tap to turn on"
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
    private var photosNeedAttention: Bool { !photosOK || photoStatus == .limited }

    var body: some View {
        content.task(id: scenePhase) { await refreshPermissions() }
    }

    private var content: some View {
        List {
            // who you are (the tab already says "profile"; no second title)
            Section {
                Button {
                    editedName = profile?.displayName ?? ""
                    showEditName = true
                } label: {
                    HStack(spacing: 14) {
                        OttoAvatarCircle(name: profile?.displayName ?? "?", size: 56, hue: OttoColor.sage)
                        Text(profile?.displayName ?? "loading…")
                            .font(OttoFont.serifBold(size: 24))
                            .foregroundStyle(OttoColor.ink)
                        Spacer()
                        Image(systemName: "pencil")
                            .font(.body.weight(.medium))
                            .foregroundStyle(OttoColor.barkSoft)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("edit name")
            }
            .listRowBackground(OttoColor.surface)

            Section {
                Button { showFaceProfileSetup = true } label: {
                    row("reference photos",
                        sub: profile?.faceProfileEnabled == true ? "set up" : "not set up",
                        chevron: true)
                }
                .listRowBackground(OttoColor.surface)
            } footer: {
                Text("encrypted before they leave your phone. only your friends' devices can use them, and only to recognize you.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { reviewStore.settings.globalEnabled },
                    set: { reviewStore.setGlobalEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("review before sending").foregroundStyle(OttoColor.ink)
                        Text(reviewStore.settings.globalEnabled
                             ? "matches wait in friends until you send them"
                             : "matches go straight to your friends")
                            .font(.footnote).foregroundStyle(OttoColor.barkSoft)
                    }
                }
                .tint(OttoColor.sage)
                .accessibilityIdentifier("profile.manualReview")
                .listRowBackground(OttoColor.surface)
            }

            Section {
                Button { if photosNeedAttention { openSettings() } } label: {
                    row("photos", sub: photoSub, good: !photosNeedAttention, chevron: photosNeedAttention)
                }
                .accessibilityIdentifier("profile.photoStatus")
                Button { if notifStatus != .authorized { openSettings() } } label: {
                    row("notifications", sub: notifSub, good: notifStatus == .authorized, chevron: notifStatus != .authorized)
                }
                .accessibilityIdentifier("profile.notificationStatus")
            }
            .listRowBackground(OttoColor.surface)

            #if DEBUG
            Section("debug") {
                NavigationLink("face match sandbox") { FaceMatchSandboxView() }
            }
            .listRowBackground(OttoColor.surface)
            #endif

            Section {
                Button(role: .destructive) {
                    Task { await authManager.signOut() }
                } label: {
                    Text("sign out").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("profile.signOut")
            }
            .listRowBackground(OttoColor.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(OttoColor.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
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

    /// One settings row: label, optional one-line status, optional chevron.
    private func row(_ label: String, sub: String? = nil, good: Bool = false, chevron: Bool = false) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(OttoColor.ink)
                if let sub {
                    Text(sub).font(.footnote).foregroundStyle(OttoColor.barkSoft)
                }
            }
            Spacer()
            if good {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(OttoColor.sage)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OttoColor.barkSoft.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
