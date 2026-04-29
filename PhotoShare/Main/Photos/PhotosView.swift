import SwiftUI

struct PhotosView: View {
    @EnvironmentObject var vm: PhotosViewModel
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.photos.isEmpty {
                    ContentUnavailableView(
                        "No Photos Yet",
                        systemImage: "photo.stack",
                        description: Text("Photos shared with you will appear here.")
                    )
                } else {
                    List(vm.photos) { photo in
                        NavigationLink {
                            PhotoDetailView(photo: photo)
                                .environmentObject(vm)
                        } label: {
                            PhotoRow(photo: photo)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .task {
                            await vm.markViewed(photo)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Photos")
            .alert("Error", isPresented: Binding(
                get: { vm.error != nil },
                set: { if !$0 { vm.error = nil } }
            )) {
                Button("OK") { vm.error = nil }
            } message: {
                Text(vm.error ?? "")
            }
        }
    }
}

// MARK: - Row

private struct PhotoRow: View {
    let photo: ReceivedPhoto

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(url: photo.photos.publicURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(photo.photos.sender.displayName)
                    .font(.headline)
                Text(photo.photos.takenAt.formatted(.relative(presentation: .named)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if photo.photos.isExpiringSoon {
                    Label("Expires soon", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if photo.isSaved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.large)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
        }
    }
}

// MARK: - Thumbnail

struct PhotoThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.secondarySystemFill))
            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
    }
}
