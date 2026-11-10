import AVFoundation
import UIKit
import Vision

/// What the camera sees right now, reduced to what the guided selfie needs. Sendable so it can cross from the
/// capture queue to the main actor.
struct FaceReading: Equatable, Sendable {
    var faceCount: Int
    var width: CGFloat = 0        // largest face width as a fraction of the frame width
    var centered = true           // largest face's centre is near the middle of the frame
    var yaw: Double?              // radians; nil when Vision doesn't report it
}

/// Front camera for guided selfies (onboarding "Show your face"). The session lives on a private serial queue;
/// every mutable property below is touched only on that queue, which is why the class is @unchecked Sendable.
/// Frames are analysed on-device for face position and turn, at most ~6 times a second, and never stored.
/// Photos are returned in memory only: nothing is written to the camera roll.
final class SelfieCamera: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "otto.selfie.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    private var analysing = false
    private var lastAnalysis = Date.distantPast
    private var onReading: (@Sendable (FaceReading) -> Void)?
    private var pendingPhoto: CheckedContinuation<UIImage?, Never>?

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    /// Asks for camera access if needed. False when denied or restricted.
    static func requestAccess() async -> Bool {
        switch authorization {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Starts the session. `onReading` is called on the capture queue.
    func start(onReading: @escaping @Sendable (FaceReading) -> Void) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                self.onReading = onReading
                if !configured { configured = configure() }
                if configured && !session.isRunning { session.startRunning() }
                cont.resume(returning: configured)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            onReading = nil
            if session.isRunning { session.stopRunning() }
            pendingPhoto?.resume(returning: nil)
            pendingPhoto = nil
        }
    }

    func capture() async -> UIImage? {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                guard configured, session.isRunning, pendingPhoto == nil else { cont.resume(returning: nil); return }
                pendingPhoto = cont
                photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(videoOutput), session.canAddOutput(photoOutput)
        else { return false }
        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(videoOutput)
        session.addOutput(photoOutput)
        return true
    }
}

extension SelfieCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onReading, !analysing, Date().timeIntervalSince(lastAnalysis) > 0.16,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        analysing = true
        defer { analysing = false; lastAnalysis = Date() }
        // Portrait front-camera buffers arrive rotated and mirrored.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .leftMirrored, options: [:])
        onReading(Self.reading(handler))
    }

    /// Shared with the debug fixture camera so both paths read faces the same way.
    static func reading(_ handler: VNImageRequestHandler) -> FaceReading {
        let request = VNDetectFaceRectanglesRequest()
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        guard (try? handler.perform([request])) != nil else { return FaceReading(faceCount: 0) }
        let faces = request.results ?? []
        guard let largest = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            return FaceReading(faceCount: 0)
        }
        let box = largest.boundingBox
        let prominent = faces.filter { $0.boundingBox.width >= FaceProfileValidator.minFaceWidthFraction }.count
        return FaceReading(faceCount: max(1, prominent), width: box.width,
                           centered: abs(box.midX - 0.5) < 0.18 && abs(box.midY - 0.5) < 0.22,
                           yaw: largest.yaw?.doubleValue)
    }
}

extension SelfieCamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        queue.async { [self] in
            pendingPhoto?.resume(returning: image)
            pendingPhoto = nil
        }
    }
}
