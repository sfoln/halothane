import Foundation

/// Single binary, two modes. Launched normally → SwiftUI menu-bar app.
/// Launched by launchd as `Halothane --daemon` → headless root supervisor.
@main
enum HalothaneEntry {
    static func main() {
        if CommandLine.arguments.contains("--daemon") {
            DaemonMain.run()   // never returns
        }
        HalothaneApp.main()
    }
}
