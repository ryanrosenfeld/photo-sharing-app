import Photos
import SwiftUI

/// Photos waiting for the user's OK before anything is uploaded. Presented as a sheet from the Friends tab.
struct ReviewQueueView: View {
    @EnvironmentObject var store: ReviewQueueStore
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSendAll = false
    @State private var confirmDiscardAll = false

    private var senderId: UUID? { authManager.session?.user.id }

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if store.items.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            Label("Nothing leaves your phone until you send it.", systemImage: "lock.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(OttoColor.barkSoft)
                            ForEach(store.items) { item in
                                ReviewCard(item: item)
                            }
                        }
                        .padding(16)
                    }
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

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                OttoEyebrow(text: "Review")
                Text("Ready to send?")
                    .font(OttoFont.serifBold(size: 28))
                    .foregroundStyle(OttoColor.ink)
            }
            Spacer()
            if store.items.count > 1 {
                Menu {
                    Button("Send All (\(store.items.count))", systemImage: "paperplane") { confirmSendAll = true }
                        .accessibilityIdentifier("review.sendAll")
                    Button("Discard All", systemImage: "trash", role: .destructive) { confirmDiscardAll = true }
                        .accessibilityIdentifier("review.discardAll")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                        .frame(width: 38, height: 38)
                        .background(OttoColor.chip)
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("review.bulkMenu")
            }
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OttoColor.sage)
                .padding(.leading, 8)
                .accessibilityIdentifier("review.done")
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Spacer()
            OttoMascot(pose: .sleeping, width: 200)
            Text("All caught up.")
                .font(OttoFont.serifBoldItalic(size: 22))
                .foregroundStyle(OttoColor.ink)
            Text("Photos you want to check before sharing will wait here.")
                .font(.system(size: 14))
                .foregroundStyle(OttoColor.bark)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.empty")
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
        OttoSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                LibraryThumbnail(assetId: item.assetId)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(item.takenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(OttoColor.barkSoft)

                VStack(alignment: .leading, spacing: 6) {
                    OttoEyebrow(text: "Send to")
                    RecipientChips(recipients: item.recipients, excluded: $excluded)
                }

                HStack(spacing: 10) {
                    Button {
                        store.reject(item)
                    } label: {
                        Text("Discard")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(OttoColor.bark)
                            .overlay(Capsule().stroke(OttoColor.line, lineWidth: 1))
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
                            if isSending { ProgressView().tint(.white) } else { Text("Send").font(.system(size: 15, weight: .semibold)) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(included.isEmpty ? OttoColor.sage.opacity(0.35) : OttoColor.sage)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(included.isEmpty || isSending)
                    .accessibilityIdentifier("review.approve")
                }
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.row")
    }
}

private struct RecipientChips: View {
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
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(on ? OttoColor.sage.opacity(0.18) : OttoColor.chip)
                        .foregroundStyle(on ? OttoColor.sageDark : OttoColor.barkSoft)
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
            OttoColor.chip
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().tint(OttoColor.sage)
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
        let stream = AsyncStream<UIImage> { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 900, height: 900),
                                                  contentMode: .aspectFill, options: options) { img, info in
                if let img { cont.yield(img) }
                if !((info?[PHImageResultIsDegradedKey] as? Bool) ?? false) { cont.finish() }
            }
        }
        for await img in stream { image = img }
    }
}
