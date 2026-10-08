import Foundation
import UIKit

struct FaceProfileManager: Sendable {
    private let bucket = "face-profiles"

    // Storage paths are case-sensitive and the bucket RLS compares the first folder to the
    // lowercase auth.uid()::text, so folders must be the lowercase UUID (UUID.uuidString is uppercase).
    private func folder(_ userId: UUID) -> String { userId.uuidString.lowercased() }

    func enable(photos: [UIImage], for userId: UUID) async throws {
        // Clear any previously uploaded photos before uploading the new set.
        try await deleteStorageFiles(for: userId)

        for (index, photo) in photos.enumerated() {
            guard let data = photo.jpegData(compressionQuality: 0.85) else { continue }
            let path = "\(folder(userId))/\(index).jpg"
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
        let files = try await supabase.storage.from(bucket).list(path: folder(userId))
        var images: [UIImage] = []
        for file in files {
            let path = "\(folder(userId))/\(file.name)"
            let data = try await supabase.storage.from(bucket).download(path: path)
            if let image = UIImage(data: data) {
                images.append(image)
            }
        }
        return images
    }

    private func deleteStorageFiles(for userId: UUID) async throws {
        let files = try await supabase.storage.from(bucket).list(path: folder(userId))
        guard !files.isEmpty else { return }
        let paths = files.map { "\(folder(userId))/\($0.name)" }
        try await supabase.storage.from(bucket).remove(paths: paths)
    }
}
