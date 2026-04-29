import Photos

@MainActor
final class PhotoLibraryManager: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus

    private let lastProcessedKey = "lastProcessedPhotoDate"

    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // Seed the cursor to now on first launch so we don't scan historical photos.
        if UserDefaults.standard.object(forKey: lastProcessedKey) == nil {
            UserDefaults.standard.set(Date(), forKey: lastProcessedKey)
        }
    }

    func requestAccess() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Timestamp of the most recently processed photo. Persisted across launches.
    var lastProcessedDate: Date {
        get { UserDefaults.standard.object(forKey: lastProcessedKey) as? Date ?? Date() }
        set { UserDefaults.standard.set(newValue, forKey: lastProcessedKey) }
    }

    /// Returns all photo assets added to the library after `lastProcessedDate`.
    func fetchNewAssets() -> [PHAsset] {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@", lastProcessedDate as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }
}
