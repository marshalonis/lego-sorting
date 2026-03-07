import AppIntents

struct LegoSorterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IdentifyLegoPartIntent(),
            phrases: [
                "Identify LEGO part with \(.applicationName)",
                "What LEGO part is this with \(.applicationName)",
                "Find this LEGO piece with \(.applicationName)",
                "Scan LEGO part with \(.applicationName)",
            ],
            shortTitle: "Identify LEGO Part",
            systemImageName: "camera.fill"
        )
    }
}
