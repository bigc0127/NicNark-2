#if os(iOS)
import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchStatusViewModel: ObservableObject {
    @Published private(set) var isSupported: Bool = WCSession.isSupported()
    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isWatchAppInstalled: Bool = false
    @Published private(set) var isReachable: Bool = false

    private var timerCancellable: AnyCancellable?

    func start() {
        refresh()

        // Keep it lightweight: this is only used while the Settings screen is visible.
        timerCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
    }

    func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    func refresh() {
        guard WCSession.isSupported() else {
            isSupported = false
            activationState = .notActivated
            isPaired = false
            isWatchAppInstalled = false
            isReachable = false
            return
        }

        let session = WCSession.default
        isSupported = true
        activationState = session.activationState
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }
}
#endif
