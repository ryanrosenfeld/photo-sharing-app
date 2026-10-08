import PhotosUI
import SwiftUI

/// Onboarding step: choose 3-5 photos of yourself. Each photo is checked on-device as soon as it is picked
/// so the user knows immediately which ones count; only photos that pass are uploaded.
struct FaceProfileStep: View {
    let userId: UUID
    let step: Int?          // nil when reused from the Profile tab (no progress bar)
    let total: Int
    var title = "Show your face"
    var showsUploadedNote = false
    let onUploaded: () -> Void

    private struct Candidate: Identifiable {
        let id = UUID()
        var image: UIImage?
        var verdict: FaceProfileValidator.Verdict?   // nil while checking
    }

    static let minPhotos = 3
    static let maxPhotos = 5

    @State private var selection: [PhotosPickerItem] = []
    @State private var candidates: [Candidate] = []
    @State private var generation = 0
    @State private var isUploading = false
    @State private var uploadError: String?

    private let manager = FaceProfileManager()

    private var validImages: [UIImage] {
        candidates.compactMap { $0.verdict?.isOK == true ? $0.image : nil }
    }
    private var isChecking: Bool { candidates.contains { $0.verdict == nil } }
    private var canContinue: Bool { validImages.count >= Self.minPhotos && !isChecking && !isUploading }

    var body: some View {
        VStack(spacing: 0) {
            if let step {
                OnboardingProgress(step: step, total: total)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(OttoFont.serifBold(size: 28))
                        .foregroundStyle(OttoColor.ink)
                        .padding(.top, 24)
                    Text(showsUploadedNote
                         ? "Pick 3 to 5 new photos to replace your current set. Your current photos stay until you finish."
                         : "Choose 3 to 5 photos of yourself so friends' phones can recognize you in their photos.")
                        .font(.system(size: 16))
                        .foregroundStyle(OttoColor.bark)

                    VStack(alignment: .leading, spacing: 8) {
                        tip("Just you, facing the camera")
                        tip("Good light, nothing covering your face")
                        tip("Mix it up: different days, angles, or glasses on and off")
                    }
                    .font(.system(size: 14))

                    PhotosPicker(
                        selection: $selection,
                        maxSelectionCount: Self.maxPhotos,
                        selectionBehavior: .ordered,
                        matching: .images
                    ) {
                        Label(candidates.isEmpty ? "Choose photos" : "Change photos",
                              systemImage: "photo.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(OttoColor.surface)
                            .foregroundStyle(OttoColor.ink)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(OttoColor.line, lineWidth: 1))
                    }
                    .disabled(isUploading)
                    .accessibilityIdentifier("faceProfile.choose")
                    .onChange(of: selection) { _, items in
                        Task { await load(items) }
                    }

                    if !candidates.isEmpty { grid }

                    Label("These stay private: they're stored encrypted and only your friends' phones use them, only to recognize you.",
                          systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(OttoColor.barkSoft)
                }
                .padding(.horizontal, 28)
            }

            VStack(spacing: 10) {
                if let uploadError {
                    Text(uploadError)
                        .font(.footnote)
                        .foregroundStyle(OttoColor.wax)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("faceProfile.error")
                }
                Button {
                    Task { await upload() }
                } label: {
                    if isUploading {
                        ProgressView().tint(.white)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canContinue)
                .accessibilityIdentifier("faceProfile.continue")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
    }

    private var buttonTitle: String {
        if uploadError != nil { return "Try again" }
        if isChecking { return "Checking photos…" }
        let n = validImages.count
        if n >= Self.minPhotos { return "Continue" }
        return "Choose \(Self.minPhotos - n) more good photo\(Self.minPhotos - n == 1 ? "" : "s")"
    }

    private func tip(_ text: String) -> some View {
        Label(text, systemImage: "face.smiling")
            .foregroundStyle(OttoColor.barkSoft)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(candidates) { c in tile(c) }
            }
            Text("\(validImages.count) of \(Self.minPhotos)–\(Self.maxPhotos) usable")
                .font(.footnote.weight(.medium))
                .foregroundStyle(validImages.count >= Self.minPhotos ? OttoColor.sageDark : OttoColor.barkSoft)
                .accessibilityIdentifier("faceProfile.count")
        }
    }

    private func tile(_ c: Candidate) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = c.image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        OttoColor.chip
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .opacity(c.verdict?.isOK == false ? 0.45 : 1)

                badge(for: c.verdict)
                    .padding(5)
            }
            if let v = c.verdict, !v.isOK {
                Text(v.message)
                    .font(.caption2)
                    .foregroundStyle(OttoColor.wax)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 96)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(c.verdict?.isOK == true ? "faceProfile.tile.ok" : "faceProfile.tile.bad")
    }

    @ViewBuilder
    private func badge(for verdict: FaceProfileValidator.Verdict?) -> some View {
        switch verdict {
        case nil:
            ProgressView().padding(4).background(.regularMaterial, in: Circle())
        case .some(.ok):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, OttoColor.sage).font(.title3)
        case .some:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, OttoColor.wax).font(.title3)
        }
    }

    // MARK: - Work

    private func load(_ items: [PhotosPickerItem]) async {
        generation += 1
        let gen = generation
        uploadError = nil
        candidates = items.map { _ in Candidate() }
        let validator = FaceProfileValidator()
        for (i, item) in items.enumerated() {
            let data = try? await item.loadTransferable(type: Data.self)
            let result: (UIImage?, FaceProfileValidator.Verdict) = await Task.detached {
                guard let data, let image = UIImage(data: data) else { return (nil, .unreadable) }
                let prepared = image.preparedForFaceDetection(maxDimension: 1600)
                return (prepared, validator.validate(prepared))
            }.value
            guard gen == generation, i < candidates.count else { return }
            candidates[i].image = result.0
            candidates[i].verdict = result.1
        }
    }

    private func upload() async {
        isUploading = true
        uploadError = nil
        defer { isUploading = false }
        do {
            try await manager.enable(photos: validImages, for: userId)
            onUploaded()
        } catch {
            uploadError = "Couldn't upload your photos. Check your connection and try again."
        }
    }
}
