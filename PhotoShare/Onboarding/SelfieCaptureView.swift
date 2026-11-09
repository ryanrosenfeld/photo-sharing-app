import AVFoundation
import SwiftUI
import Vision

/// Guided selfies: three poses (straight on, a slight turn, a slight turn the other way), each captured
/// automatically once the face is in position and held still for a moment. A turned face gives friends' phones
/// more to match against than three identical frames. A shutter button is always there as a manual fallback.
enum SelfiePose: Int, CaseIterable, Sendable {
    case straight, turn, turnOther

    var instruction: String {
        switch self {
        case .straight: "look straight at the camera"
        case .turn: "now turn your head a little to one side"
        case .turnOther: "and a little the other way"
        }
    }
}

enum SelfieGuidance: Equatable, Sendable {
    case ready
    case hint(String)

    /// Turns are judged by size only, never by direction, so mirroring can't make an instruction wrong.
    static let turnMin = 0.25, turnMax = 1.0, straightMax = 0.2

    /// Pure, unit-tested: what to tell the person for this frame. `firstTurnSign` is the direction of the first turn,
    /// so the second turn has to go the other way.
    static func evaluate(_ r: FaceReading, pose: SelfiePose, firstTurnSign: Double?) -> SelfieGuidance {
        if r.faceCount == 0 { return .hint("bring your face into the circle") }
        if r.faceCount > 1 { return .hint("just you in the frame") }
        if r.width < 0.22 { return .hint("move a little closer") }
        if r.width > 0.8 { return .hint("move back a little") }
        if !r.centered { return .hint("center your face in the circle") }
        guard let yaw = r.yaw else { return .ready }   // no turn reading: position is all we can check
        switch pose {
        case .straight:
            return abs(yaw) <= straightMax ? .ready : .hint("look straight at the camera")
        case .turn:
            if abs(yaw) < turnMin { return .hint("turn your head a little to one side") }
            return abs(yaw) > turnMax ? .hint("not quite so far") : .ready
        case .turnOther:
            let sameSide = firstTurnSign.map { ($0 > 0) == (yaw > 0) } ?? false
            if abs(yaw) < turnMin || sameSide { return .hint("now turn a little the other way") }
            return abs(yaw) > turnMax ? .hint("not quite so far") : .ready
        }
    }
}

@MainActor
final class SelfieCaptureModel: ObservableObject {
    enum Phase: Equatable { case starting, denied, unavailable, running, done }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var pose: SelfiePose = .straight
    @Published private(set) var hint = SelfiePose.straight.instruction
    @Published private(set) var isReady = false
    @Published private(set) var captured: [UIImage] = []
    @Published private(set) var flash = false

    let camera = SelfieCamera()
    private var firstTurnSign: Double?
    private var lastYaw: Double?
    private var readySince: Date?
    private var busy = false
    private let validator = FaceProfileValidator()
    private let holdSeconds = 0.7
    #if DEBUG
    private var fixtureTask: Task<Void, Never>?
    #endif

    /// The camera is usable here, or a UI test supplied stand-in frames.
    nonisolated static var canCapture: Bool { SelfieCamera.isAvailable || !fixtures.isEmpty }

    func start() async {
        #if DEBUG
        if !Self.fixtures.isEmpty { startFixtures(); return }
        #endif
        guard SelfieCamera.isAvailable else { phase = .unavailable; return }
        guard await SelfieCamera.requestAccess() else { phase = .denied; return }
        let ok = await camera.start { [weak self] reading in
            Task { @MainActor in self?.handle(reading) }
        }
        phase = ok ? .running : .unavailable
    }

    func stop() {
        camera.stop()
        #if DEBUG
        fixtureTask?.cancel()
        #endif
    }

    func handle(_ reading: FaceReading) {
        guard phase == .running, !busy else { return }
        lastYaw = reading.yaw
        switch SelfieGuidance.evaluate(reading, pose: pose, firstTurnSign: firstTurnSign) {
        case .hint(let text):
            hint = text; isReady = false; readySince = nil
        case .ready:
            hint = "hold still"; isReady = true
            let since = readySince ?? Date()
            readySince = since
            if Date().timeIntervalSince(since) >= holdSeconds { Task { await shoot() } }
        }
    }

    /// Manual shutter, or the automatic one once a pose has been held.
    func shoot() async {
        guard phase == .running, !busy else { return }
        busy = true
        defer { busy = false; readySince = nil; isReady = false }
        guard let photo = await takePhoto() else { hint = "couldn't take that one. try again."; return }
        let checked: (UIImage, FaceProfileValidator.Verdict) = await Task.detached { [validator] in
            let prepared = photo.preparedForFaceDetection(maxDimension: 1600)
            return (prepared, validator.validate(prepared))
        }.value
        guard checked.1.isOK else { hint = checked.1.message; return }
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        Task { try? await Task.sleep(for: .milliseconds(180)); flash = false }
        captured.append(checked.0)
        if pose == .turn { firstTurnSign = lastYaw.map { $0 >= 0 ? 1 : -1 } }
        if let next = SelfiePose(rawValue: pose.rawValue + 1) {
            pose = next
            hint = next.instruction
        } else {
            phase = .done
            stop()
        }
    }

    private func takePhoto() async -> UIImage? {
        #if DEBUG
        if !Self.fixtures.isEmpty { return Self.fixtures[min(captured.count, Self.fixtures.count - 1)] }
        #endif
        return await camera.capture()
    }

    // MARK: - UI-test stand-in camera (debug builds only)

    /// The simulator has no camera. UI tests pass SELFIE_FIXTURES (comma-separated image paths); frames are then
    /// read from those images, with the turn for each pose simulated, so the whole guided flow can run.
    nonisolated static var fixtures: [UIImage] {
        #if DEBUG
        let paths = ProcessInfo.processInfo.environment["SELFIE_FIXTURES"] ?? ""
        return paths.split(separator: ",").compactMap { UIImage(contentsOfFile: String($0)) }
        #else
        return []
        #endif
    }

    #if DEBUG
    @Published private(set) var fixturePreview: UIImage?

    private func startFixtures() {
        phase = .running
        let images = Self.fixtures
        fixtureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let image = images[min(self.captured.count, images.count - 1)]
                self.fixturePreview = image
                let simulatedYaw: [SelfiePose: Double] = [.straight: 0, .turn: 0.45, .turnOther: -0.45]
                let yaw = simulatedYaw[self.pose]
                let reading = await Task.detached { () -> FaceReading in
                    guard let cg = image.preparedForFaceDetection().cgImage else { return FaceReading(faceCount: 0) }
                    var r = SelfieCamera.reading(VNImageRequestHandler(cgImage: cg, options: [:]))
                    r.yaw = yaw
                    r.centered = true   // fixture portraits aren't framed for the circle
                    r.width = min(max(r.width, 0.3), 0.7)
                    return r
                }.value
                self.handle(reading)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    #endif
}

/// Full-screen guided capture. Calls `onFinished` with the accepted photos (empty if cancelled).
struct SelfieCaptureView: View {
    let onFinished: ([UIImage]) -> Void
    var onUseLibrary: (() -> Void)?

    @StateObject private var model = SelfieCaptureModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .denied:
                fallback(title: "camera access is off",
                         message: "turn on the camera for otto in settings, or choose photos of yourself instead.",
                         showSettings: true)
            case .unavailable:
                fallback(title: "no camera available",
                         message: "choose photos of yourself from your library instead.", showSettings: false)
            default:
                capture
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, phase in
            if phase == .done {
                Task { try? await Task.sleep(for: .milliseconds(500)); onFinished(model.captured) }
            }
        }
    }

    private var capture: some View {
        VStack(spacing: 20) {
            HStack {
                Button("cancel") { model.stop(); onFinished([]) }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("selfie.cancel")
                Spacer()
                Text("\(min(model.captured.count + 1, SelfiePose.allCases.count)) of \(SelfiePose.allCases.count)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("selfie.progress")
            }
            .padding(.horizontal, 24)

            Text(model.phase == .done ? "all set" : model.hint)
                .font(OttoFont.serifBold(size: 24))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(minHeight: 64)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("selfie.instruction")

            ZStack {
                preview
                    .frame(width: 280, height: 280)
                    .clipShape(Circle())
                Circle()
                    .stroke(model.isReady || model.phase == .done ? OttoColor.sage : .white.opacity(0.6), lineWidth: 5)
                    .frame(width: 290, height: 290)
                    .animation(.easeInOut(duration: 0.2), value: model.isReady)
                if model.flash { Circle().fill(.white).frame(width: 280, height: 280) }
            }

            HStack(spacing: 12) {
                ForEach(0..<SelfiePose.allCases.count, id: \.self) { i in
                    Group {
                        if i < model.captured.count {
                            Image(uiImage: model.captured[i]).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.12)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(i == model.captured.count ? .white : .clear, lineWidth: 2))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.captured.count) of \(SelfiePose.allCases.count) taken")
            .accessibilityIdentifier("selfie.taken")

            Spacer()

            Button { Task { await model.shoot() } } label: {
                Circle().fill(.white).frame(width: 72, height: 72)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 4).frame(width: 84, height: 84))
            }
            .disabled(model.phase != .running)
            .accessibilityLabel("take photo")
            .accessibilityIdentifier("selfie.shutter")
            Text("it takes each photo on its own when you're in position.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 12)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var preview: some View {
        #if DEBUG
        if let image = model.fixturePreview {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            CameraPreview(session: model.camera.session)
        }
        #else
        CameraPreview(session: model.camera.session)
        #endif
    }

    private func fallback(title: String, message: String, showSettings: Bool) -> some View {
        VStack(spacing: 16) {
            Text(title).font(OttoFont.serifBold(size: 24)).foregroundStyle(.white)
                .accessibilityIdentifier("selfie.fallback")
            Text(message).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            if showSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("open settings") { openURL(url) }.buttonStyle(PrimaryButtonStyle())
            }
            if let onUseLibrary {
                Button("choose photos instead") { onUseLibrary() }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("selfie.useLibrary")
            }
            Button("cancel") { onFinished([]) }.foregroundStyle(.white.opacity(0.7))
        }
        .padding(32)
    }
}

/// AVCaptureVideoPreviewLayer as the view's own layer, mirrored like a mirror (the front camera default).
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
