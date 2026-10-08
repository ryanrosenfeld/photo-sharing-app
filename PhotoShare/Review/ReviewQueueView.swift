import Photos
import SwiftUI

/// Photos waiting for the user's OK before anything is uploaded.
struct ReviewQueueView: View {
    @EnvironmentObject var store: ReviewQueueStore
    @EnvironmentObject var authManager: AuthManager
    @State private var confirmSendAll = false
    @State private var confirmDiscardAll = false

    private var senderId: UUID? { authManager.session?.user.id }

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView(
                    "All Caught Up",
                    systemImage: "checkmark.circle",
                    description: Text("Photos you want to check before sharing will wait here.")
                )
                .accessibilityIdentifier("review.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        Label("Nothing leaves your phone until you send it.", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(store.items) { item in
                            ReviewCard(item: item)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.items.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Send All (\(store.items.count))", systemImage: "paperplane") { confirmSendAll = true }
                            .accessibilityIdentifier("review.sendAll")
                        Button("Discard All", systemImage: "trash", role: .destructive) { confirmDiscardAll = true }
                            .accessibilityIdentifier("review.discardAll")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("review.bulkMenu")
                }
            }
        }
        .confirmationDialog("Send all \(store.items.count) photos to the friends shown on them?",
                            isPresented: $confirmSendAll, titleVisibility: .visible) {
            Button("Send All") {
                guard let senderId else { return }
                Task { await store.approveAll(senderId: senderId) }
            }
            .accessibilityIdentifier("review.sendAll.confirm")
        }
        .confirmationDialog("Discard all \(store.items.count) photos?",
                            isPresented: $confirmDiscardAll, titleVisibility: .visible) {
            Button("Discard All", role: .destructive) { store.rejectAll() }
                .accessibilityIdentifier("review.discardAll.confirm")
        } message: {
            Text("They stay in your library. They just won't be shared.")
        }
        .alert("Couldn't finish", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}

private struct ReviewCard: View {
    let item: ReviewItem
    @EnvironmentObject var store: ReviewQueueStore
    @EnvironmentObject var authManager: AuthManager
    @State private var excluded: Set<UUID> = []

    private var included: Set<UUID> { Set(item.recipients.map(\.id)).subtracting(excluded) }
    private var isSending: Bool { store.sendingIds.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryThumbnail(assetId: item.assetId)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(item.takenAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Send to")
                    .font(.subheadline.weight(.semibold))
                FlowChips(recipients: item.recipients, excluded: $excluded)
            }

            HStack(spacing: 10) {
                Button {
                    store.reject(item)
                } label: {
                    Text("Discard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityIdentifier("review.reject")

                Button {
                    guard let senderId = authManager.session?.user.id else { return }
                    let ids = included
                    Task { await store.approve(item, to: ids, senderId: senderId) }
                } label: {
                    Group {
                        if isSending {
                            ProgressView().tint(.white)
                        } else {
                            Text("Send").font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(included.isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(included.isEmpty || isSending)
                .accessibilityIdentifier("review.approve")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.row")
    }
}

private struct FlowChips: View {
    let recipients: [ReviewItem.Recipient]
    @Binding var excluded: Set<UUID>

    var body: some View {
        HStack {
            ForEach(recipients, id: \.id) { r in
                let on = !excluded.contains(r.id)
                Button {
                    if on { excluded.insert(r.id) } else { excluded.remove(r.id) }
                } label: {
                    Label(r.name, systemImage: on ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(on ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill))
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review.recipient")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Library thumbnail loaded on demand (the queue stores only the asset identifier).
private struct LibraryThumbnail: View {
    let assetId: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: assetId) { await load() }
    }

    private func load() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: 900, height: 900)
        let stream = AsyncStream<UIImage> { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, info in
                if let img { cont.yield(img) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.finish() }
            }
        }
        for await img in stream { image = img }
    }
}
