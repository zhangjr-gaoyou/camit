import Foundation
@preconcurrency import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var bailianConfig: BailianConfig

    init() {
        self.bailianConfig = (try? BailianConfig.load()) ?? BailianConfig()
    }

    func save() throws {
        try bailianConfig.save()
    }
}

