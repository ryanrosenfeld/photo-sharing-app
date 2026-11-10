import SwiftUI

/// "found 214 photos of troy": the offer made when a new friend's face is found in the camera roll index.
struct PastPhotosCard: View {
    @EnvironmentObject var offers: PastPhotosOffers
    @EnvironmentObject var vm: FriendsViewModel
    @EnvironmentObject var authManager: AuthManager
    @ObservedObject private var indexer = FaceIndexer.shared

    var body: some View {
        VStack(spacing: 12) {
            ForEach(offers.offers) { offer in
                OttoSectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title(offer))
                            .font(.headline)
                            .foregroundStyle(OttoColor.ink)
                            .accessibilityIdentifier("pastPhotos.title")
                        Text(offer.final
                             ? "found on this phone. nothing is sent until you tap."
                             : "still looking through your library, so this number can grow. nothing is sent until you tap.")
                            .font(.subheadline)
                            .foregroundStyle(OttoColor.bark)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits {
                            HStack { buttons(offer) }
                            VStack(alignment: .leading) { buttons(offer) }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pastPhotos.card")
            }
        }
    }

    private func title(_ o: PastPhotosOffers.Offer) -> String {
        let n = o.matches.count
        return "\(n)\(o.final ? "" : "+") photo\(n == 1 ? "" : "s") of \(o.name.lowercased())"
    }

    @ViewBuilder private func buttons(_ o: PastPhotosOffers.Offer) -> some View {
        Button {
            guard let me = authManager.session?.user.id else { return }
            Task { await offers.accept(o, senderId: me, friends: vm.friends, indexer: indexer) }
        } label: {
            Text(offers.sending.contains(o.friendId) ? "sending…" : "send them all")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(OttoColor.sageDark, in: Capsule())
        }
        .disabled(offers.sending.contains(o.friendId))
        .accessibilityIdentifier("pastPhotos.send")
        .accessibilityHint("sends these photos to \(o.name), encrypted")

        Button("not now") { offers.dismiss(o) }
            .font(.body)
            .foregroundStyle(OttoColor.bark)
            .frame(minHeight: 44)
            .accessibilityIdentifier("pastPhotos.dismiss")
    }
}
