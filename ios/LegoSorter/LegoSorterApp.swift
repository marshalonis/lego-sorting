import SwiftUI

class AppState: ObservableObject {
    let auth = AuthService()
    lazy var api: APIService = APIService(auth: auth)
}

@main
struct LegoSorterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.auth.isLoggedIn {
                    ContentView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(appState.auth)
            .environmentObject(appState.api)
        }
    }
}
