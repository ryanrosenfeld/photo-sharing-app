import Foundation
import UIKit

struct FaceProfileManager: Sendable {
    private let bucket = "face-profiles"

    func enable(photos: [UIImage], for userId: UUID) async throws {
        // Clear any previously uploaded photos before uploading the new set.
        try await deleteStorageFiles(for: userId)

        for (index, photo) in photos.enumerated() {
            guard let data = photo.jpegData(compressionQuality: 0.85) else { continue }
            let path = "\(userId.uuidString)/\(index).jpg"
            try await supabase.storage.from(bucket).upload(path, data: data)
        }

        try await supabase
            .from("profiles")
            .update(["face_profile_enabled": true])
            .eq("id", value: userId)
            .execute()
    }

    func disable(for userId: UUID) async throws {
        try await deleteStorageFiles(for: userId)

        try await supabase
            .from("profiles")
            .update(["face_profile_enabled": false])
            .eq("id", value: userId)
            .execute()
    }

    func downloadPhotos(for userId: UUID) async throws -> [UIImage] {
        let files = try await supabase.storage.from(bucket).list(path: userId.uuidString)
        var images: [UIImage] = []
        for file in files {
            let path = "\(userId.uuidString)/\(file.name)"
            let data = try await supabase.storage.from(bucket).download(path: path)
            if let image = UIImage(data: data) {
                images.append(image)
            }
        }
        return images
    }

    private func deleteStorageFiles(for userId: UUID) async throws {
        let files = try await supabase.storage.from(bucket).list(path: userId.uuidString)
        guard !files.isEmpty else { return }
        let paths = files.map { "\(userId.uuidString)/\($0.name)" }
        try await supabase.storage.from(bucket).remove(paths: paths)
    }
}
