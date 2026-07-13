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

    /// Debounce CloudKit remote-change reconcile storms (main-thread I/O).
    private static var lastReconcileAt: Date = .distantPast
    private static let reconcileMinInterval: TimeInterval = 2.0

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

    /// Mirrors every can's synced `imageData` into the id-keyed disk cache.
    ///
    /// Debounced (min 2s between runs) because CloudKit remote-change fires in bursts.
    /// Change detection: size + 8-byte prefix/suffix fingerprint (not full-file compare).
    /// Same-size different photo can still miss — rare; documented tradeoff vs main-thread I/O.
    /// Orphan sweep skipped when Can fetch is empty (transient empty ≠ mass-delete).
    static func reconcile(context: NSManagedObjectContext) {
        let now = Date()
        guard now.timeIntervalSince(lastReconcileAt) >= reconcileMinInterval else { return }
        lastReconcileAt = now

        let request = NSFetchRequest<Can>(entityName: "Can")
        request.predicate = NSPredicate(format: "id != nil")
        guard let cans = try? context.fetch(request) else { return }

        let allowOrphanSweep = !cans.isEmpty
        var liveIDs = Set<UUID>()

        for can in cans {
            guard let id = can.id else { continue }
            liveIDs.insert(id)

            if let data = can.imageData {
                // Accessing imageData may fault external storage once; unavoidable for sync.
                if diskMatches(data: data, id: id) { continue }
                store(data: data, for: id)
            } else if hasImage(for: id) {
                store(data: nil, for: id)
            }
        }

        guard allowOrphanSweep else { return }

        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
              ) else { return }

        for file in files {
            // Case-insensitive: iCloud / tooling can produce .JPG / .jpeg
            let ext = file.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: name), !liveIDs.contains(uuid) else { continue }
            delete(for: uuid)
        }
    }

    /// True when disk file size matches and first/last 8 bytes match `data`.
    /// Failure mode: two different images with identical size AND identical 8-byte ends
    /// won't re-mirror (extremely rare for re-encoded JPEGs). Prefer this over full-byte
    /// load on every CloudKit reconcile.
    private static func diskMatches(data: Data, id: UUID) -> Bool {
        guard let url = fileURL(for: id) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.intValue == data.count else {
            return false
        }
        guard data.count >= 16 else {
            // Tiny payload — full compare is cheap.
            guard let disk = try? Data(contentsOf: url) else { return false }
            return disk == data
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let headDisk = handle.readData(ofLength: 8)
        try? handle.seek(toOffset: UInt64(data.count - 8))
        let tailDisk = handle.readData(ofLength: 8)
        let headMem = data.prefix(8)
        let tailMem = data.suffix(8)
        return headDisk == Data(headMem) && tailDisk == Data(tailMem)
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
