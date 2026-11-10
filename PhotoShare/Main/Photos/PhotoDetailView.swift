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
        .background(OttoColor.canvas.ignoresSafeArea())
        .navigationTitle(detail.sender.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.markViewed(photo) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                saveButton
            }
        }
    }

    // MARK: - Subviews

    private var photoImage: some View {
        PhotoImage(photo: photo, size: .full) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 12)
            case .failure:
                imagePlaceholder
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
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
                Label("saved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(OttoColor.sageDark)
            }
        }
    }

    private var expiryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("expires \(detail.expiresAt.formatted(.relative(presentation: .named)))")
                .font(.subheadline)
        }
        .foregroundStyle(OttoColor.wax)
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
