import SwiftUI

@main
struct InstTunerApp: App {
    @State private var model = TunerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TunerScreen()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Palette.amber)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.scenePhaseChanged(phase)
                }
        }
    }
}
