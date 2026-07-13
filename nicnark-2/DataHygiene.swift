//
//  DataHygiene.swift
//  nicnark-2
//
//  One-shot / idempotent local cleanups that must run when a *feature* is removed or an
//  environment flips — not only when code stops writing. See AGENTS.md global rules on
//  "state that outlives code".
//

import Foundation
import CoreData
import os.log

enum DataHygiene {
    nonisolated private static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "DataHygiene")

    nonisolated private static let appGroup = "group.ConnorNeedling.nicnark-2"
    nonisolated private static let canImagesFolder = "CanImages"
    /// Bumps when a new hygiene pass is required; each key runs once per install.
    private static let stripCanPhotosFlag = "hygiene.v1.stripCanPhotosAndCache"

    /// Call after the persistent store is ready (and after remote merges if needed).
    /// - Bulk-nulls legacy `Can.imageData` so Production exports never re-carry photo assets.
    /// - Deletes the App Group `CanImages/` on-disk cache left by the removed photo feature.
    @MainActor
    static func stripRetiredCanPhotosIfNeeded(context: NSManagedObjectContext) {
        // Always drop the on-disk cache if present (idempotent; cheap).
        removeCanImagesCacheIfPresent()

        // Bulk-null remaining Core Data blobs. Cheap when already clean (count first).
        let request = NSFetchRequest<Can>(entityName: "Can")
        request.predicate = NSPredicate(format: "imageData != nil")
        request.fetchBatchSize = 50
        do {
            let dirty = try context.count(for: request)
            guard dirty > 0 else {
                if !UserDefaults.standard.bool(forKey: stripCanPhotosFlag) {
                    UserDefaults.standard.set(true, forKey: stripCanPhotosFlag)
                    logger.info("✅ Can photo hygiene: no imageData blobs; cache cleared")
                }
                return
            }
            logger.info("🔧 Stripping imageData from \(dirty) Can row(s) (retired photo feature)")
            let cans = try context.fetch(request)
            for can in cans {
                can.imageData = nil
            }
            if context.hasChanges {
                try context.save()
            }
            UserDefaults.standard.set(true, forKey: stripCanPhotosFlag)
            logger.info("✅ Can photo hygiene complete — \(dirty) row(s) nullified (will re-export without assets)")
        } catch {
            logger.error("❌ Can photo hygiene failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes App Group `CanImages/` directory left by the deleted CanImageStore.
    nonisolated static func removeCanImagesCacheIfPresent() {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let base else { return }
        let dir = base.appendingPathComponent(canImagesFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            logger.info("🗑️ Removed orphaned CanImages cache at \(dir.path, privacy: .public)")
        } catch {
            logger.warning("⚠️ Could not remove CanImages cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
