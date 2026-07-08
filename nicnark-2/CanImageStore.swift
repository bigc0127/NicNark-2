//
//  CanImageStore.swift
//  nicnark-2
//
//  Storage + cache for a photo attached to each can, keyed by the can's UUID.
//
//  DESIGN (the can-image feature is now CloudKit-synced):
//  • Source of truth = the `imageData` binary attribute on the `Can` entity. It has
//    "Allows External Storage" on, so NSPersistentCloudKitContainer ships it as a CKAsset
//    and it syncs across the user's devices automatically (same as every other Can field).
//  • This store is a *fast decode cache* keyed by the can's UUID: a downsized JPEG on disk in
//    the shared App Group container, plus an in-memory NSCache of decoded UIImages. The disk
//    copy lets the Usage-log cells (which only carry a can *id*, not the Can object) show a
//    photo without touching Core Data on every render, and keeps images available to widgets.
//  • `reconcile(context:)` mirrors Core Data → this cache, so a photo that arrived from
//    CloudKit on another device becomes visible in the id-keyed call sites too.
//
//  NOTE ON PRODUCTION SYNC: after this ships, the new `imageData` field must be deployed to the
//  CloudKit *Production* schema (CloudKit dashboard) for cross-device sync on TestFlight/App
//  Store builds — same one-time step the other CD_ fields needed. Until then it still works
//  locally; it just won't propagate to other devices.
//

import UIKit
import CoreData

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

    // MARK: - Encoding

    /// Canonical bytes we persist everywhere (Core Data `imageData` + the disk cache): a
    /// downscaled JPEG. Returns nil for a nil image (i.e. "no photo / removed").
    static func encodedJPEG(from image: UIImage?) -> Data? {
        guard let image else { return nil }
        return image.downscaled(maxDimension: 1000).jpegData(compressionQuality: 0.8)
    }

    // MARK: - Read (id-keyed cache: for the log, which only has a can id)

    static func hasImage(for id: UUID?) -> Bool {
        guard let id else { return false }
        if cache.object(forKey: id.uuidString as NSString) != nil { return true }
        guard let url = fileURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Loads (and caches) the can's image from the id-keyed cache, or nil if none is cached yet.
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

    // MARK: - Read (can-aware: for inventory / editor, which hold the Can)

    /// Cache → disk → Core Data `imageData`. Reading straight from the managed object means an
    /// image that synced in from CloudKit shows immediately, even before `reconcile` has run; a
    /// hit from Core Data seeds the id-keyed cache so later log reads are fast.
    static func image(for can: Can?) -> UIImage? {
        guard let can, let id = can.id else { return nil }
        if let cached = loadImage(for: id) { return cached }
        guard let data = can.imageData, let image = UIImage(data: data) else { return nil }
        store(data: data, for: id)
        return image
    }

    // MARK: - Write (disk cache; the caller sets can.imageData for the synced copy)

    /// Writes (or clears) the disk-cache copy from already-encoded bytes. Pass nil to remove.
    /// The synced source of truth is `Can.imageData`, set by the caller; this only mirrors it
    /// into the fast id-keyed cache.
    static func store(data: Data?, for id: UUID) {
        let key = id.uuidString as NSString
        guard let url = fileURL(for: id) else { return }

        guard let data else {
            try? FileManager.default.removeItem(at: url)
            cache.removeObject(forKey: key)
            return
        }

        try? data.write(to: url, options: .atomic)
        if let image = UIImage(data: data) {
            cache.setObject(image, forKey: key)
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

    // MARK: - Reconciliation (Core Data → disk cache)

    /// Mirrors every can's synced `imageData` into the id-keyed disk cache so id-only call sites
    /// (the Usage log) can render photos that arrived via CloudKit on this device. Cheap: cans
    /// are few, and cans already present on disk are skipped. Safe to call on the main context.
    static func reconcile(context: NSManagedObjectContext) {
        let request = NSFetchRequest<Can>(entityName: "Can")
        request.predicate = NSPredicate(format: "imageData != nil AND id != nil")
        guard let cans = try? context.fetch(request) else { return }
        for can in cans {
            guard let id = can.id, !hasImage(for: id) else { continue }
            if let data = can.imageData {
                store(data: data, for: id)
            }
        }
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
