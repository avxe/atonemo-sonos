import SwiftUI

@main
struct AtonemoSonosApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(systemName: model.isPlaying ? "radio.fill" : "radio")
        }
        .menuBarExtraStyle(.window)
    }
}
