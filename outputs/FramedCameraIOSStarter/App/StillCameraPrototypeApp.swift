import SwiftUI

@main
struct StillCameraPrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
        }
    }
}
