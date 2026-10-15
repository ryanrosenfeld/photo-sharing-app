import UIKit
import Vision

/// On-device check that a candidate reference photo is usable for face enrollment.
/// Runs before upload so a bad photo is caught at pick time, not when a friend fails to match you.
struct FaceProfileValidator: Sendable {
    enum Verdict: Equatable, Sendable {
        case ok
        case noFace
        case multipleFaces
        case faceTooSmall
        case unreadable

        var isOK: Bool { self == .ok }

        var message: String {
            switch self {
            case .ok: "Looks good"
            case .noFace: "No face found. Use a clear photo of your face."
            case .multipleFaces: "More than one face. Use a photo of just you."
            case .faceTooSmall: "Your face is too small. Use a closer photo."
            case .unreadable: "Couldn't read this photo."
            }
        }
    }

    /// Minimum face width as a fraction of image width.
    static let minFaceWidthFraction: CGFloat = 0.15

    func validate(_ image: UIImage) -> Verdict {
        let prepared = image.preparedForFaceDetection()
        guard let cgImage = prepared.cgImage else { return .unreadable }
        let request = VNDetectFaceRectanglesRequest()
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return .unreadable
        }
        let faces = request.results ?? []
        switch faces.count {
        case 0: return .noFace
        case 1:
            return faces[0].boundingBox.width >= Self.minFaceWidthFraction ? .ok : .faceTooSmall
        default:
            // A small bystander in the background is fine; two prominent faces are ambiguous.
            let prominent = faces.filter { $0.boundingBox.width >= Self.minFaceWidthFraction }
            return prominent.count > 1 ? .multipleFaces : (prominent.isEmpty ? .faceTooSmall : .ok)
        }
    }
}
