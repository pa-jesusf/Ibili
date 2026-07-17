import Combine
import Foundation

enum RootSearchPhase: Equatable {
    case inactive
    case editing
    case results
}

enum RootSearchEvent: Equatable {
    case presentationChanged(Bool)
    case submitted
    case queryCleared
}

struct RootSearchState: Equatable {
    private(set) var phase: RootSearchPhase = .inactive

    var isPresented: Bool {
        phase != .inactive
    }

    mutating func send(_ event: RootSearchEvent) {
        switch event {
        case .presentationChanged(true):
            if phase == .inactive {
                phase = .editing
            }
        case .presentationChanged(false):
            phase = .inactive
        case .submitted:
            guard phase != .inactive else { return }
            phase = .results
        case .queryCleared:
            guard phase != .inactive else { return }
            phase = .editing
        }
    }
}

@MainActor
final class RootSearchCoordinator: ObservableObject {
    @Published private(set) var state = RootSearchState()

    var isPresented: Bool {
        state.isPresented
    }

    func send(_ event: RootSearchEvent) {
        state.send(event)
    }
}
