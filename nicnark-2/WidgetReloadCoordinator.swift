//
//  WidgetReloadCoordinator.swift
//  nicnark-2
//
//  Coalesces bursts of widget-timeline reloads into a single call.
//

import Foundation
import WidgetKit

/// Debounces `WidgetCenter.reloadAllTimelines()`.
///
/// The app has ~21 reload call sites — per-tick Live Activity updates, every log/removal
/// side-effect, CloudKit sync completion, etc. Firing them individually hammers iOS's
/// limited widget-refresh budget and, several-times-per-user-action, is pure waste. Routing
/// them all through `reload()` collapses any burst within `debounceSeconds` into one actual
/// `reloadAllTimelines()`.
enum WidgetReloadCoordinator {
    /// How long to wait for a burst to settle before performing a single reload.
    private static let debounceSeconds: UInt64 = 2

    @MainActor private static var pending: Task<Void, Never>?

    /// Request a widget reload. Safe to call from any isolation. Repeated calls within the
    /// debounce window collapse into a single `reloadAllTimelines()`.
    nonisolated static func reload() {
        Task { @MainActor in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: debounceSeconds * NSEC_PER_SEC)
                if Task.isCancelled { return }
                WidgetCenter.shared.reloadAllTimelines()
                pending = nil
            }
        }
    }
}
