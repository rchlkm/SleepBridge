import AppIntents

struct SyncSleepDataIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Sleep Data"
    static var description = IntentDescription(
        "Fetches new sleep sessions from Google Fit and writes them into Apple Health."
    )

    // Lets Shortcuts run this without opening the app's UI.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = await SyncRunner.run()
        return .result(value: summary)
    }
}

/// Makes the intent discoverable in the Shortcuts app / Siri without extra setup.
struct SleepBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncSleepDataIntent(),
            phrases: ["Sync my sleep data with \(.applicationName)"],
            shortTitle: "Sync Sleep Data",
            systemImageName: "bed.double.fill"
        )
    }
}
