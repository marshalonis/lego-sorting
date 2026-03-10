import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            IdentifyView(onPartSaved: { selectedTab = 2 })
                .tabItem { Label("Identify", systemImage: "camera.fill") }
                .tag(0)

            BrowseView()
                .tabItem { Label("Browse", systemImage: "magnifyingglass") }
                .tag(1)

            DrawersView()
                .tabItem { Label("Drawers", systemImage: "square.grid.3x3.fill") }
                .tag(2)

            DataView()
                .tabItem { Label("Data", systemImage: "externaldrive.fill") }
                .tag(3)
        }
    }
}
