import PhotosUI
import SwiftUI

/// Onboarding step: your reference photos. The main path is three guided selfies (SelfieCaptureView); choosing
/// 3-5 photos from the library is the fallback, and library photos can also be added after selfies for variety.
/// Each photo is checked on-device as soon as it is taken or picked; only photos that pass are uploaded.
struct FaceProfileStep: View {
    let userId: UUID
    let step: Int?          // nil when reused from the Profile tab (no progress bar)
    let total: Int
    var title = "show your face"
    var showsUploadedNote = false
    let onUploaded: () -> Void

    private struct Candidate: Identifiable {
        let id = UUID()
        var fromCamera = false
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
    @State private var showCamera = false
    @State private var showPicker = false

    private let canUseCamera = SelfieCaptureModel.canCapture

    private let manager = FaceProfileManager()

    private var validImages: [UIImage] {
        candidates.compactMap { $0.verdict?.isOK == true ? $0.image : nil }
    }
    private var isChecking: Bool { candidates.contains { $0.verdict == nil } }
    private var canContinue: Bool { validImages.count >= Self.minPhotos && !isChecking && !isUploading }
    private var selfieCount: Int { candidates.filter(\.fromCamera).count }

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
                    Text(intro)
                        .font(.system(size: 16))
                        .foregroundStyle(OttoColor.bark)

                    VStack(alignment: .leading, spacing: 8) {
                        if canUseCamera {
                            tip("takes about 10 seconds: straight on, then a little to each side")
                            tip("good light, nothing covering your face")
                            tip("glasses on if you usually wear them")
                        } else {
                            tip("just you, facing the camera")
                            tip("good light, nothing covering your face")
                            tip("mix it up: different days, angles, or glasses on and off")
                        }
                    }
                    .font(.system(size: 14))

                    if canUseCamera {
                        Button { showCamera = true } label: {
                            Label(selfieCount > 0 ? "retake selfies" : "take selfies", systemImage: "camera")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(selfieCount > 0 ? OttoColor.surface : OttoColor.sage)
                                .foregroundStyle(selfieCount > 0 ? OttoColor.ink : .white)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(selfieCount > 0 ? OttoColor.line : .clear, lineWidth: 1))
                        }
                        .disabled(isUploading)
                        .accessibilityIdentifier("faceProfile.selfie")

                        Button(libraryTitle) { showPicker = true }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(OttoColor.bark)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .disabled(isUploading)
                            .accessibilityIdentifier("faceProfile.choose")
                    } else {
                        Button { showPicker = true } label: {
                            Label(candidates.isEmpty ? "choose photos" : "change photos",
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
                    }

                    if !candidates.isEmpty { grid }

                    Label("these stay private: they're stored encrypted and only your friends' phones use them, only to recognize you.",
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
        .photosPicker(isPresented: $showPicker, selection: $selection,
                      maxSelectionCount: max(1, Self.maxPhotos - selfieCount),
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: selection) { _, items in
            Task { await load(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            SelfieCaptureView(onFinished: { photos in
                showCamera = false
                if !photos.isEmpty { useSelfies(photos) }
            }, onUseLibrary: {
                showCamera = false
                Task { try? await Task.sleep(for: .milliseconds(600)); showPicker = true }
            })
        }
    }

    private var intro: String {
        switch (showsUploadedNote, canUseCamera) {
        case (true, true):
            "take new selfies to replace your current set. your current photos stay until you finish."
        case (true, false):
            "pick 3 to 5 new photos to replace your current set. your current photos stay until you finish."
        case (false, true):
            "take three quick selfies so friends' phones can recognize you in their photos."
        case (false, false):
            "choose 3 to 5 photos of yourself so friends' phones can recognize you in their photos."
        }
    }

    private var libraryTitle: String {
        selfieCount > 0 ? "add a photo from another day (optional)" : "choose from your photos instead"
    }

    /// Selfies replace earlier selfies and keep library picks, up to the maximum.
    private func useSelfies(_ photos: [UIImage]) {
        uploadError = nil
        let library = candidates.filter { !$0.fromCamera }
        let shots = photos.map { Candidate(fromCamera: true, image: $0, verdict: .ok) }   // checked during capture
        candidates = Array((shots + library).prefix(Self.maxPhotos))
    }

    private var buttonTitle: String {
        if uploadError != nil { return "try again" }
        if isChecking { return "checking photos…" }
        let n = validImages.count
        if n >= Self.minPhotos { return "Continue" }
        if canUseCamera && candidates.isEmpty { return "take selfies to continue" }
        return "add \(Self.minPhotos - n) more good photo\(Self.minPhotos - n == 1 ? "" : "s")"
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
        let shots = candidates.filter(\.fromCamera)
        candidates = shots + items.map { _ in Candidate() }
        let offset = shots.count
        let validator = FaceProfileValidator()
        for (n, item) in items.enumerated() {
            let i = offset + n
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
            uploadError = "couldn't upload your photos. check your connection and try again."
        }
    }
}
