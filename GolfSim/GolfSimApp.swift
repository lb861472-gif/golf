import SwiftUI

@main
struct GolfSimApp: App {
    @StateObject private var persistence = PersistenceManager()
    @StateObject private var ble = BluetoothServerManager()
    @StateObject private var motion = MotionManager()

    var body: some Scene {
        WindowGroup {
            MainMenuView()
                .environmentObject(persistence)
                .environmentObject(ble)
                .environmentObject(motion)
                .preferredColorScheme(.dark)
        }
    }
}
