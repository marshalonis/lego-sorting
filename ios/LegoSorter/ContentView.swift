import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            IdentifyView()
                .tabItem { Label("Identify", systemImage: "camera.fill") }

            BrowseView()
                .tabItem { Label("Browse", systemImage: "magnifyingglass") }

            DrawersView()
                .tabItem { Label("Drawers", systemImage: "square.grid.3x3.fill") }

            DataView()
                .tabItem { Label("Data", systemImage: "externaldrive.fill") }
        }
    }
}
