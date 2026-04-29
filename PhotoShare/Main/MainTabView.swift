import PhotosUI
import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var photosVM = PhotosViewModel()
    @StateObject private var friendsVM = FriendsViewModel()
    @StateObject private var processor = AutoShareProcessor()

    var body: some View {
        TabView {
            PhotosView()
                .environmentObject(photosVM)
                .tabItem { Label("Photos", systemImage: "photo.stack.fill") }

            FriendsView()
                .environmentObject(friendsVM)
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .badge(friendsVM.pendingCount)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle.fill") }
        }
        .task {
            guard let userId = authManager.session?.user.id else { return }
            await processor.libraryManager.requestAccess()
            async let p: () = photosVM.load(userId: userId)
            async let f: () = friendsVM.load(userId: userId)
            _ = await (p, f)
            await processor.processNewPhotos(userId: userId, outgoingLinks: friendsVM.outgoingLinks)
        }
        // Re-run processing every time the app returns to the foreground.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let userId = authManager.session?.user.id else { return }
            Task {
                await processor.processNewPhotos(userId: userId, outgoingLinks: friendsVM.outgoingLinks)
            }
        }
    }
}

// MARK: - Profile tab

struct ProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showEditName = false
    @State private var editedName = ""
    @State private var showFaceProfileSetup = false

    private var profile: UserProfile? { authManager.currentProfile }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Circle()
                            .fill(Color(.secondarySystemFill))
                            .frame(width: 64, height: 64)
                            .overlay(
                                Text(profile?.displayName.prefix(1).uppercased() ?? "?")
                                    .font(.title2.bold())
                                    .foregroundStyle(.secondary)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.displayName ?? "Loading…")
                                .font(.headline)
                            Text(profile?.plan.displayName ?? "")
                                .font(.subheadline)
                                .foregroundStyle(profile?.plan.isPro == true ? .orange : .secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Account") {
                    Button("Edit Name") {
                        editedName = profile?.displayName ?? ""
                        showEditName = true
                    }
                }

                Section("My Face Profile") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile?.faceProfileEnabled == true ? "Shared with friends" : "Not sharing")
                                .font(.subheadline)
                            Text(profile?.faceProfileEnabled == true
                                 ? "Friends can auto-enroll you without choosing photos"
                                 : "Friends must choose photos of you manually")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(profile?.faceProfileEnabled == true ? "Manage" : "Set Up") {
                            showFaceProfileSetup = true
                        }
                        .font(.subheadline)
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await authManager.signOut() }
                    }
                }

                #if DEBUG
                Section("Debug") {
                    NavigationLink("Face Match Sandbox") {
                        FaceMatchSandboxView()
                    }
                }
                #endif
            }
            .navigationTitle("Profile")
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
    }
}

// MARK: - Face profile setup sheet

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
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    explanation

                    if !isEnabled {
                        photoPicker
                        if !previewImages.isEmpty { previewGrid }
                        enableButton
                    } else {
                        updateSection
                    }
                }
                .padding()
            }
            .navigationTitle("My Face Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
        .presentationDetents([.medium, .large])
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isEnabled ? "Your face profile is on" : "Make enrollment easier for friends")
                .font(.headline)
            Text(isEnabled
                 ? "Friends who link with you can auto-enroll your face without selecting photos themselves. You can update your reference photos or turn this off at any time."
                 : "Upload 3–5 photos of yourself so friends can auto-enroll your face when they link with you — no manual photo selection on their end. Your photos are stored securely and only used to generate face embeddings on your friends' devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $selectedItems,
            maxSelectionCount: 5,
            matching: .images
        ) {
            Label(
                "Select Photos of Yourself (\(selectedItems.count) of 5)",
                systemImage: "photo.badge.plus"
            )
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .onChange(of: selectedItems) {
            Task { await loadPreviews() }
        }
    }

    private var previewGrid: some View {
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

    private var enableButton: some View {
        Button {
            Task { await uploadAndEnable() }
        } label: {
            Group {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text("Share My Face Profile")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(selectedItems.count >= 3 && !isWorking ? Color.accentColor : Color.secondary.opacity(0.3))
            .foregroundStyle(selectedItems.count >= 3 && !isWorking ? Color.white : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(selectedItems.count < 3 || isWorking)
    }

    private var updateSection: some View {
        VStack(spacing: 16) {
            photoPicker
            if !previewImages.isEmpty { previewGrid }

            Button {
                Task { await uploadAndEnable() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Update Photos")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(selectedItems.count >= 3 && !isWorking ? Color.accentColor : Color.secondary.opacity(0.3))
                .foregroundStyle(selectedItems.count >= 3 && !isWorking ? Color.white : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(selectedItems.count < 3 || isWorking)

            Button("Turn Off Face Profile", role: .destructive) {
                Task { await disableProfile() }
            }
            .disabled(isWorking)
        }
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

struct EditNameSheet: View {
    @Binding var name: String
    @Environment(\.dismiss) var dismiss
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Display Name", text: $name)
                    .autocorrectionDisabled()
            }
            .navigationTitle("Edit Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(180)])
    }
}

#Preview {
    MainTabView().environmentObject(AuthManager())
}
