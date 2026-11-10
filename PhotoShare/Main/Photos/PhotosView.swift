import SwiftUI

struct PhotosView: View {
    @EnvironmentObject var vm: PhotosViewModel
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.photos.isEmpty {
                    ProgressView().tint(OttoColor.sage)
                        .accessibilityIdentifier("photos.loading")
                } else if vm.photos.isEmpty && vm.loadFailed {
                    errorState
                } else if vm.photos.isEmpty {
                    emptyState
                } else {
                    shelves
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OttoColor.canvas.ignoresSafeArea())
            .navigationTitle("photos")
            .navigationDestination(for: UUID.self) { id in
                if let photo = vm.photos.first(where: { $0.id == id }) {
                    PhotoDetailView(photo: photo)
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
    }

    /// One shelf per sender: swipe sideways (native paging), tap for full size, press and hold to save.
    private var shelves: some View {
        ScrollView {
            LazyVStack(spacing: 28) {
                ForEach(groupedPhotos, id: \.senderName) { group in
                    SenderShelf(group: group) {
                        Task { await vm.saveAll(group.photos) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("photos.stack.\(group.senderName)")
                }
            }
            .padding(.vertical, 8)
        }
        .refreshable {
            // Unstructured so SwiftUI cancelling the refresh task (it does when the list re-renders) doesn't abort the request.
            await Task { await reload() }.value
        }
    }

    private func reload() async {
        guard let userId = authManager.session?.user.id else { return }
        await vm.load(userId: userId)
    }

    private var errorState: some View {
        VStack(spacing: 20) {
            OttoMascot(pose: .sleeping, width: 160)
            VStack(spacing: 8) {
                Text("couldn't load your photos.")
                    .font(OttoFont.serifBoldItalic(size: 22))
                    .foregroundStyle(OttoColor.ink)
                Text("check your connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(OttoColor.bark)
            }
            OttoPillButton(title: "try again", isFullWidth: false) {
                Task { await reload() }
            }
            .accessibilityIdentifier("photos.retry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photos.error")
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            OttoMascot(pose: .sleeping, width: 200)
                .accessibilityIdentifier("photos.empty")
            VStack(spacing: 8) {
                Text("otto's keeping watch.")
                    .font(OttoFont.serifBoldItalic(size: 24))
                    .foregroundStyle(OttoColor.ink)
                Text("when friends share photos with you, they'll arrive here.")
                    .font(.subheadline)
                    .foregroundStyle(OttoColor.bark)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    // Group received photos by sender
    private var groupedPhotos: [SenderGroup] {
        var dict: [String: SenderGroup] = [:]
        var order: [String] = []
        for photo in vm.photos {
            let name = photo.photos.sender.displayName
            if dict[name] == nil {
                dict[name] = SenderGroup(senderName: name, photos: [])
                order.append(name)
            }
            dict[name]?.photos.append(photo)
        }
        return order.compactMap { dict[$0] }
    }
}

// MARK: - Data model for grouping

struct SenderGroup {
    let senderName: String
    var photos: [ReceivedPhoto]
}

// MARK: - Sender shelf

struct SenderShelf: View {
    let group: SenderGroup
    var onSaveAll: () -> Void = {}

    @EnvironmentObject private var vm: PhotosViewModel
    private var unsaved: Int { group.photos.filter { !$0.isSaved }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 20)

            // Native horizontal paging: the next photo peeks in, no arrows, counters or hints.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(group.photos) { photo in
                        NavigationLink(value: photo.id) {
                            PhotoCard(photo: photo)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !photo.isSaved {
                                Button("save to photos", systemImage: "arrow.down.circle") {
                                    Task { await vm.saveToLibrary(photo) }
                                }
                            }
                        }
                        .scrollTransition(axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                                .opacity(phase.isIdentity ? 1 : 0.7)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OttoAvatarCircle(name: group.senderName, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.senderName)
                        .font(.headline)
                        .foregroundStyle(OttoColor.ink)
                    if unsaved > 0 {
                        Text("\(unsaved) new")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(OttoColor.sage, in: Capsule())
                    }
                }
                Text(group.photos.first?.photos.takenAt.formatted(.relative(presentation: .named)) ?? "")
                    .font(.footnote)
                    .foregroundStyle(OttoColor.barkSoft)
            }
            Spacer()
            if unsaved > 0 {
                Button("save all", action: onSaveAll)
                    .font(.subheadline.weight(.semibold))
                    .modifier(GlassSmallButton())
                    .accessibilityIdentifier("photos.saveAll.\(group.senderName)")
            } else {
                Label("saved", systemImage: "checkmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OttoColor.barkSoft)
            }
        }
    }
}

private struct GlassSmallButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass).tint(OttoColor.sageDark).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).tint(OttoColor.sageDark).buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Single photo card

struct PhotoCard: View {
    let photo: ReceivedPhoto

    var body: some View {
        PhotoImage(photo: photo) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill().accessibilityIdentifier("photos.image.loaded")
            case .failure:
                OttoColor.cream
                    .overlay(Image(systemName: "photo").font(.title2).foregroundStyle(OttoColor.barkSoft))
            case .empty:
                OttoColor.cream
                    .overlay(ProgressView().tint(OttoColor.barkSoft))
            }
        }
        .frame(width: 280, height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if photo.photos.isExpiringSoon && !photo.isSaved {
                Text("expires soon")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OttoColor.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .ottoGlass(Capsule(), tint: OttoColor.wax.opacity(0.35))
                    .padding(12)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}
