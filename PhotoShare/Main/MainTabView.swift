import PhotosUI
import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var photosVM = PhotosViewModel()
    @StateObject private var friendsVM = FriendsViewModel()
    @StateObject private var processor = AutoShareProcessor()
    @StateObject private var reviewStore = ReviewQueueStore()
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

            OttoTabBarView(selected: $selectedTab, friendsBadge: friendsVM.pendingCount + reviewStore.count)
        }
        .ignoresSafeArea(.keyboard)
        .environmentObject(reviewStore)
        .task {
            guard let userId = authManager.session?.user.id else { return }
            reviewStore.bind(userId: userId)
            await processor.libraryManager.requestAccess()
            async let p: () = photosVM.load(userId: userId)
            async let f: () = friendsVM.load(userId: userId)
            _ = await (p, f)
            await processor.processNewPhotos(userId: userId, outgoingLinks: friendsVM.outgoingLinks, review: reviewStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let userId = authManager.session?.user.id else { return }
            reviewStore.bind(userId: userId)
            Task {
                await processor.processNewPhotos(userId: userId, outgoingLinks: friendsVM.outgoingLinks, review: reviewStore)
            }
        }
    }
}

// MARK: - Tab enum

enum OttoTab: Hashable {
    case photos, friends, profile
}

// MARK: - Custom Otto tab bar

struct OttoTabBarView: View {
    @Binding var selected: OttoTab
    var friendsBadge: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            tabItem(tab: .photos, label: "Photos", icon: "photo.stack")
            tabItem(tab: .friends, label: "Friends", icon: "person.2", badge: friendsBadge)
            tabItem(tab: .profile, label: "Profile", icon: "person.circle")
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
                        Text("\(badge)")
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
        .accessibilityIdentifier("tab.\(label.lowercased())")
    }
}

// MARK: - Profile tab

struct OttoProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showEditName = false
    @State private var editedName = ""
    @State private var showFaceProfileSetup = false
    @EnvironmentObject var reviewStore: ReviewQueueStore

    private var profile: UserProfile? { authManager.currentProfile }

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // header
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            OttoEyebrow(text: "Profile")
                            Text("Settings")
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
                            Text(profile?.displayName ?? "Loading…")
                                .font(OttoFont.serifBold(size: 20))
                                .foregroundStyle(OttoColor.ink)
                            Text(profile?.plan.displayName ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(OttoColor.barkSoft)
                        }

                        Spacer()

                        Button("Edit") {
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
                    profileSection(title: "My reference photos") {
                        OttoSectionCard {
                            VStack(spacing: 0) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile?.faceProfileEnabled == true ? "5 photos · best" : "Not set up")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(OttoColor.ink)
                                        Text("The more you add, the better recognition gets")
                                            .font(.system(size: 13))
                                            .foregroundStyle(OttoColor.barkSoft)
                                    }
                                    Spacer()
                                    Button(profile?.faceProfileEnabled == true ? "Manage" : "Set up") {
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
                                    Text("Encrypted before they leave your phone. Only your friends' devices can use them — and only to recognize you.")
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
                    profileSection(title: "Sending") {
                        OttoSectionCard {
                            settingsRow(
                                label: "Review all photos before sending",
                                sub: reviewStore.settings.globalEnabled
                                    ? "Matches wait in Friends until you send them"
                                    : "Approve every match before it goes",
                                hasToggle: true,
                                isOn: Binding(
                                    get: { reviewStore.settings.globalEnabled },
                                    set: { reviewStore.setGlobalEnabled($0) }
                                ),
                                toggleId: "profile.manualReview",
                                isLast: false
                            )
                            settingsRow(
                                label: "Pause all sending",
                                sub: "Photos hold until you turn it back on",
                                hasToggle: true,
                                isOn: .constant(false),
                                isLast: true
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Permissions
                    profileSection(title: "Permissions") {
                        OttoSectionCard {
                            settingsRow(label: "Photos", sub: "All photos · allowed", dot: true, isLast: false)
                            settingsRow(label: "Notifications", sub: "Allowed", dot: true, isLast: false)
                            settingsRow(label: "Location", sub: "When in use", dot: true, isLast: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Privacy
                    profileSection(title: "Privacy") {
                        OttoSectionCard {
                            settingsRow(label: "What otto stores", sub: "Your photos and face data are both encrypted", hasChev: true, isLast: false)
                            settingsRow(label: "Privacy policy", hasChev: true, isLast: false)
                            settingsRow(label: "Terms", hasChev: true, isLast: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                    // Debug
                    #if DEBUG
                    profileSection(title: "Debug") {
                        OttoSectionCard {
                            NavigationLink {
                                FaceMatchSandboxView()
                            } label: {
                                settingsRowLabel(label: "Face Match Sandbox", hasChev: true)
                                    .padding(16)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    #endif

                    // Danger
                    VStack(spacing: 8) {
                        Button("Sign Out") {
                            Task { await authManager.signOut() }
                        }
                        .accessibilityIdentifier("profile.signOut")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(OttoColor.wax)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OttoColor.line, lineWidth: 1))
                        .padding(.horizontal, 16)

                        Button("Delete account", role: .destructive) {}
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
            Button("OK") { authManager.clearError() }
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
                    OttoEyebrow(text: "Free plan", color: OttoColor.wax)
                        .padding(.bottom, 8)
                    Text("More friends?\nOtto can deliver.")
                        .font(OttoFont.serifBoldItalic(size: 22))
                        .foregroundStyle(OttoColor.ink)
                        .lineSpacing(2)
                        .padding(.bottom, 4)
                    Text("Send to 3 friends free. Pro removes the limit.")
                        .font(.system(size: 14))
                        .foregroundStyle(OttoColor.bark)
                        .lineSpacing(2)
                        .padding(.bottom, 14)
                    OttoPillButton(title: "Try Pro free for 7 days", isFullWidth: false) {}
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
                    Text("Otto Pro")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                    Text("Renews soon · $4.99/mo")
                        .font(.system(size: 13))
                        .foregroundStyle(OttoColor.barkSoft)
                }
            }
            .padding(16)
        }
    }

    private func profileSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
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

struct FaceProfileSetupSheet: View {
    let isEnabled: Bool
    let userId: UUID
    let onComplete: () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var previewImages: [UIImage] = []
    @State private var isWorking = false
    @State private var error: String?

    private let manager = FaceProfileManager()

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // heading
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isEnabled ? "Your reference photos" : "Set up your reference photos")
                                .font(OttoFont.serifBold(size: 24))
                                .foregroundStyle(OttoColor.ink)
                            Text(isEnabled
                                 ? "Upload new photos to improve recognition accuracy. At least 3 required, up to 5."
                                 : "Upload 3–5 photos of yourself. Friends' devices use them to recognize you in photos they take.")
                                .font(.system(size: 15))
                                .foregroundStyle(OttoColor.bark)
                                .lineSpacing(2)
                        }

                        // encryption note
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(OttoColor.sage).frame(width: 6, height: 6).padding(.top, 6)
                            Text("Encrypted before they leave your phone. Only your friends' devices can use them — and only to recognize you.")
                                .font(.system(size: 13))
                                .foregroundStyle(OttoColor.bark)
                                .lineSpacing(2)
                        }
                        .padding(14)
                        .background(OttoColor.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        // photo picker
                        PhotosPicker(
                            selection: $selectedItems,
                            maxSelectionCount: 5,
                            matching: .images
                        ) {
                            HStack {
                                Image(systemName: "photo.badge.plus")
                                Text("Select photos of yourself (\(selectedItems.count) of 5)")
                            }
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(OttoColor.surface)
                            .foregroundStyle(OttoColor.ink)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(OttoColor.line, lineWidth: 1))
                        }
                        .onChange(of: selectedItems) {
                            Task { await loadPreviews() }
                        }

                        // previews
                        if !previewImages.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 8) {
                                ForEach(Array(previewImages.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 88, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }

                        // quality nudge
                        if !selectedItems.isEmpty {
                            qualityNudge
                        }

                        // action
                        Button {
                            Task { await uploadAndEnable() }
                        } label: {
                            Group {
                                if isWorking {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(isEnabled ? "Update photos" : "Share my reference photos")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(canContinue ? OttoColor.sage : OttoColor.chip)
                            .foregroundStyle(canContinue ? .white : OttoColor.barkSoft)
                            .clipShape(Capsule())
                        }
                        .disabled(!canContinue)

                        if isEnabled {
                            Button("Turn off reference photos", role: .destructive) {
                                Task { await disableProfile() }
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(OttoColor.wax)
                            .frame(maxWidth: .infinity)
                            .disabled(isWorking)
                        }
                    }
                    .padding(24)
                }
                .background(OttoColor.canvas.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(OttoColor.sage)
                    }
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var canContinue: Bool { selectedItems.count >= 3 && !isWorking }

    private var qualityNudge: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Circle()
                        .fill(i <= selectedItems.count ? OttoColor.sage : OttoColor.chip)
                        .frame(width: 9, height: 9)
                        .overlay(
                            i <= selectedItems.count ? nil :
                                Circle().stroke(OttoColor.line, lineWidth: 1)
                        )
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(qualityLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OttoColor.ink)
                Text(qualityHint)
                    .font(.system(size: 12))
                    .foregroundStyle(OttoColor.barkSoft)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OttoColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selectedItems.count >= 3 ? OttoColor.lineSoft : OttoColor.sage, lineWidth: 1)
        )
    }

    private var qualityLabel: String {
        let n = selectedItems.count
        if n >= 5 { return "\(n) added — best" }
        if n == 4 { return "\(n) added — better" }
        if n >= 3 { return "\(n) added — good" }
        return "\(n) of 3 minimum"
    }

    private var qualityHint: String {
        let n = selectedItems.count
        if n >= 5 { return "Looking great" }
        if n >= 3 { return "Add more for sharper recognition" }
        return "Add at least \(3 - n) more to continue"
    }

    private func loadPreviews() async {
        var images: [UIImage] = []
        for item in selectedItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        previewImages = images
    }

    private func uploadAndEnable() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await manager.enable(photos: previewImages, for: userId)
            onComplete()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disableProfile() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await manager.disable(for: userId)
            onComplete()
            dismiss()
        } catch {
            self.error = error.localizedDescription
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
                    TextField("Display Name", text: $name)
                        .autocorrectionDisabled()
                }
                .scrollContentBackground(.hidden)
                .background(OttoColor.canvas)
                .navigationTitle("Edit Name")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(OttoColor.sage)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
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
