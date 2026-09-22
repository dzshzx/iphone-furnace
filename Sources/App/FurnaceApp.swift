import SwiftUI

@main struct FurnaceApp: App {
    @State private var session = SessionController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Dashboard(session: session)
                .onChange(of: scenePhase) { _, value in
                    if value == .background { session.stop(reason: "应用进入后台或锁屏") }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    session.stop(reason: "系统内存压力，结束会话")
                }
        }
    }
}

