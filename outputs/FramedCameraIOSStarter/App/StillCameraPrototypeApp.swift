import SwiftUI

@main
struct StillCameraPrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                // Unit tests exercise processing without requesting hardware or permissions.
                Color.black
            } else {
                CameraView().preferredColorScheme(.dark)
            }
        }
    }
}
