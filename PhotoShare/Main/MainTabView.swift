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
