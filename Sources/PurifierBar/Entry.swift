// Entry point: one binary, two modes. With the `--settings` argument the process
// serves the settings window and exits when it closes; without it -
// the regular menu bar app.
import Foundation

@main
enum Entry {
    static func main() {
        // The process entry point is always on the main thread.
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--settings") {
                SettingsProcess.run()
            } else {
                PurifierBarApp.main()
            }
        }
    }
}
