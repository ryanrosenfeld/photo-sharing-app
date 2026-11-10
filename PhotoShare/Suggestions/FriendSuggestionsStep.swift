import ContactsUI
import Photos
import SwiftUI

/// Onboarding: "people you're in photos with". Groups faces in the camera roll on the phone, shows the most common
/// people, and lets the user invite one with a tap. The app never learns who a face is: the user attaches a name by
/// picking a contact (optional). Skipping is as visible as inviting; the link/QR step follows either way.
struct FriendSuggestionsStep: View {
    var step: Int = 0
    var total: Int = 0
    /// Opened from the friends tab after onboarding: no progress bar, and the button just closes the sheet.
    var embedded = false
    let onFinished: () -> Void

    @StateObject private var scanner = CameraRollScanner()
    @State private var selected: PersonCluster?
    @State private var invited = Set<UUID>()

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                OnboardingProgress(step: step, total: total)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            ScrollView {
                VStack(spacing: 14) {
                    Text("people you're in photos with")
                        .font(OttoFont.serifBold(size: 28))
                        .foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 28)
                    Text("otto looked through your photos, on your phone only, to find who shows up most. tap someone to invite them. nothing leaves your phone until you send an invite.")
                        .font(.system(size: 15))
                        .lineSpacing(2)
                        .foregroundStyle(OttoColor.bark)
                        .multilineTextAlignment(.center)

                    status

                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(scanner.people.prefix(12)) { person in
                            PersonTile(person: person, invited: invited.contains(person.id))
                                .onTapGesture { selected = person }
                                .accessibilityIdentifier("suggestions.person")
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 28)
            }

            VStack(spacing: 10) {
                Button(embedded ? "done" : invited.isEmpty ? "skip for now" : "continue") { finish() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("suggestions.continue")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
        .task {
            if embedded, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            scanner.start()
        }
        .onDisappear { scanner.stop() }
        .sheet(item: $selected) { person in
            PersonInviteSheet(person: person) { _ in
                invited.insert(person.id)
                scanner.hide(person)
                selected = nil
            } onNotNow: {
                scanner.hide(person)
                selected = nil
            }
        }
    }

    @ViewBuilder private var status: some View {
        if scanner.isScanning {
            HStack(spacing: 8) {
                ProgressView().tint(OttoColor.sage)
                Text(scanner.scanned < CameraRollScanner.firstBatch
                     ? "looking through your photos… \(scanner.scanned) of \(min(scanner.total, CameraRollScanner.firstBatch))"
                     : "still looking through older photos…")
                    .font(.system(size: 13))
                    .foregroundStyle(OttoColor.barkSoft)
            }
            .accessibilityIdentifier("suggestions.scanning")
        } else if scanner.finished && scanner.people.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 14))
                .foregroundStyle(OttoColor.barkSoft)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("suggestions.empty")
        }
    }

    private var emptyMessage: String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .limited || status == .denied || status == .restricted
            ? "otto can only see some of your photos, so nobody stood out. you can still invite a friend with a link on the next screen."
            : "nobody shows up in enough photos yet. you can invite a friend with a link on the next screen."
    }

    private func finish() {
        if !invited.isEmpty && !embedded { OnboardingStep.markFirstFriendOffered() }
        onFinished()
    }
}

private struct PersonTile: View {
    let person: PersonCluster
    let invited: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let data = person.crop, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        OttoColor.chip
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                .overlay(Circle().stroke(OttoColor.line, lineWidth: 1))
                if invited {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(OttoColor.sage, .white)
                }
            }
            Text("\(person.photoCount) photos")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OttoColor.bark)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Invite one suggested person. A contact can be picked just to label the invite message; the link goes out through
/// the normal share sheet.
private struct PersonInviteSheet: View {
    let person: PersonCluster
    let onSent: (String) -> Void
    let onNotNow: () -> Void

    @EnvironmentObject var authManager: AuthManager
    @StateObject private var friends = FriendsViewModel()
    @State private var code: String?
    @State private var failed = false
    @State private var name: String?
    @State private var pickingContact = false
    @State private var sendPhotos = true

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            VStack(spacing: 16) {
                if let data = person.crop, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 120, height: 120).clipShape(Circle())
                        .padding(.top, 28)
                }
                Text(name.map { "invite \($0)" } ?? "invite this person")
                    .font(OttoFont.serifBold(size: 24))
                    .foregroundStyle(OttoColor.ink)
                    .accessibilityIdentifier("suggestions.sheetTitle")
                Text("you're in \(person.photoCount) photos with them.")
                    .font(.system(size: 15))
                    .foregroundStyle(OttoColor.bark)

                Button(name == nil ? "pick from contacts" : "pick someone else") { pickingContact = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OttoColor.sage)
                    .frame(height: 44)
                    .accessibilityIdentifier("suggestions.pickContact")

                Toggle(isOn: $sendPhotos) {
                    Text("also send them our \(min(person.photoCount, InvitedPhotosStore.maxPhotos)) most recent photos once they join. you'll still review them first if review mode is on.")
                        .font(.system(size: 13))
                        .foregroundStyle(OttoColor.bark)
                }
                .tint(OttoColor.sage)
                .accessibilityIdentifier("suggestions.sendPhotos")

                Spacer()

                if let code {
                    ShareLink(
                        item: InviteLink.url(code: code),
                        message: Text(InviteMessage.text(from: authManager.currentProfile?.displayName))
                    ) {
                        Text("send an invite")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(OttoColor.sage).foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        FriendsViewModel.markShared(code)
                        if sendPhotos { InvitedPhotosStore.add(code: code, assetIds: person.assetIds) }
                        Task { try? await Task.sleep(for: .milliseconds(800)); onSent(code) }
                    })
                    .accessibilityIdentifier("suggestions.send")
                } else if failed {
                    Button("couldn't create a link. try again") { Task { await load() } }
                        .foregroundStyle(OttoColor.wax)
                } else {
                    ProgressView().tint(OttoColor.sage).frame(height: 52)
                }
                Button("not them") { onNotNow() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OttoColor.bark)
                    .frame(height: 44)
                    .accessibilityIdentifier("suggestions.notThem")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .presentationDetents([.large])
        .task { await load() }
        .sheet(isPresented: $pickingContact) {
            ContactPicker { name = $0 }.ignoresSafeArea()
        }
    }

    private func load() async {
        failed = false
        code = await friends.inviteToShare()
        failed = code == nil
    }
}

/// System contact picker. It runs out of process, so no contacts permission is needed; only the chosen name comes back.
private struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { onPick(name) }
        }
    }
}
