import SwiftUI

class AppState: ObservableObject {
    let auth = AuthService()
    lazy var api: APIService = APIService(auth: auth)

    /// True while we are validating a restored project ID on startup.
    @Published var isValidatingProject = false

    /// Validates the restored project ID by fetching it from the API.
    /// Clears currentProject if the fetch fails (e.g., removed from project, project deleted).
    func validateRestoredProject() async {
        guard auth.isLoggedIn,
              let pid = api.currentProject?.projectID,
              !pid.isEmpty else { return }
        await MainActor.run { isValidatingProject = true }
        do {
            let project = try await api.getProject(projectID: pid)
            await MainActor.run {
                api.currentProject = project
                isValidatingProject = false
            }
        } catch {
            await MainActor.run {
                api.currentProject = nil
                isValidatingProject = false
            }
        }
    }
}

@main
struct LegoSorterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.auth.isLoggedIn {
                    if appState.isValidatingProject {
                        ProgressView("Loading…")
                    } else if appState.api.currentProject != nil {
                        ContentView()
                    } else {
                        ProjectPickerView()
                    }
                } else {
                    LoginView()
                }
            }
            .environmentObject(appState.auth)
            .environmentObject(appState.api)
            .task { await appState.validateRestoredProject() }
        }
    }
}
