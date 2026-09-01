import SwiftUI

@main
struct CatPlayIOSRelayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = RelayViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        model.stop(reason: "app_backgrounded")
                    }
                }
        }
    }
}
