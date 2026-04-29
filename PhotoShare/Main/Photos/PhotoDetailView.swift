import SwiftUI

struct PhotoDetailView: View {
    let photo: ReceivedPhoto
    @EnvironmentObject var vm: PhotosViewModel
    @Environment(\.dismiss) var dismiss

    var detail: PhotoDetail { photo.photos }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                photoImage

                VStack(alignment: .leading, spacing: 16) {
                    senderRow

                    if detail.isExpiringSoon {
                        expiryBanner
                    }
                }
                .padding()
            }
        }
        .navigationTitle(detail.sender.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                saveButton
            }
        }
    }

    // MARK: - Subviews

    private var photoImage: some View {
        Group {
            if let url = detail.publicURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        imagePlaceholder
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                    @unknown default:
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(Color(.secondarySystemFill))
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary))
    }

    private var senderRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.sender.displayName)
                    .font(.headline)
                Text(detail.takenAt.formatted(date: .long, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if photo.isSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
    }

    private var expiryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("Expires \(detail.expiresAt.formatted(.relative(presentation: .named)))")
                .font(.subheadline)
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var saveButton: some View {
        Button {
            Task { await vm.saveToLibrary(photo) }
        } label: {
            Image(systemName: photo.isSaved ? "checkmark.circle.fill" : "arrow.down.circle")
        }
        .disabled(photo.isSaved)
    }
}
