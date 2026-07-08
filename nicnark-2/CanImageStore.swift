//
//  CanImageStore.swift
//  nicnark-2
//
//  Device-local storage for a photo attached to each can, keyed by the can's UUID.
//
//  FRAMEWORK NOTE (this is the first cut of the can-image feature, on its own branch):
//  Images are stored as downsized JPEGs in the shared App Group container, so the main app
//  (and, later, the widgets / watch) can read the same files. They are NOT yet CloudKit-
//  synced across devices — the follow-up, when we want sync, is to move the bytes into an
//  optional Binary attribute on the Can entity (Core Data + CloudKit CKAsset). Keeping it
//  file-based for now avoids a Core Data model migration while the feature is being shaped.
//

import UIKit

enum CanImageStore {

    /// Same App Group the rest of the app already uses (see WidgetPersistenceHelper / Persistence).
    private static let appGroup = "group.ConnorNeedling.nicnark-2"
    private static let folderName = "CanImages"

    /// Small in-memory cache so list/log cells don't hit disk + decode on every render.
    private static let cache = NSCache<NSString, UIImage>()

    // MARK: - Locations

    private static var directory: URL? {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).jpg")
    }

    // MARK: - Read

    static func hasImage(for id: UUID?) -> Bool {
        guard let id else { return false }
        if cache.object(forKey: id.uuidString as NSString) != nil { return true }
        guard let url = fileURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Loads (and caches) the can's image, or nil if none is set.
    static func loadImage(for id: UUID?) -> UIImage? {
        guard let id else { return nil }
        let key = id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = fileURL(for: id),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Write

    /// Saves a downsized JPEG for the can. Pass `nil` to remove any existing image.
    static func save(_ image: UIImage?, for id: UUID) {
        let key = id.uuidString as NSString
        guard let url = fileURL(for: id) else { return }

        guard let image else {
            try? FileManager.default.removeItem(at: url)
            cache.removeObject(forKey: key)
            return
        }

        let resized = image.downscaled(maxDimension: 1000)
        if let data = resized.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url, options: .atomic)
            cache.setObject(resized, forKey: key)
        }
    }

    static func delete(for id: UUID?) {
        guard let id else { return }
        let key = id.uuidString as NSString
        if let url = fileURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
        cache.removeObject(forKey: key)
    }
}

private extension UIImage {
    /// Proportionally shrink so the longest side is at most `maxDimension` points.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return self }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in self.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
