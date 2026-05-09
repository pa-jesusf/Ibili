import Foundation

/// Small process-wide guard used by full-screen overlay tools that need
/// horizontal drags for their own interaction. The player host's
/// any-position swipe-back recognizer lives on the window, so SwiftUI
/// presentation containment is not always enough to keep it from seeing
/// those drags.
enum ModalGestureShield {
    private static let lock = NSLock()
    private static var activeCount = 0

    static func enter() {
        lock.lock()
        activeCount += 1
        lock.unlock()
    }

    static func leave() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        lock.unlock()
    }

    static var isActive: Bool {
        lock.lock()
        let value = activeCount > 0
        lock.unlock()
        return value
    }
}
