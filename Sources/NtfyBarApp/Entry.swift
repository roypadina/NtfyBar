import AppKit
import Foundation

/// Handles command-line flags before SwiftUI starts, so a render or a typo never launches the
/// full GUI (and never registers a login item). Single-dash args are AppKit defaults (`-NS…`).
@main
enum Entry {
    static let usage = """
        usage: NtfyBar [--render-settings <png> | --render-popup <png> | --render-history <png>]
        """

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let flag = args.first(where: { $0.hasPrefix("--") }) {
            let path = args.drop(while: { $0 != flag }).dropFirst().first
            switch flag {
            case "--render-settings", "--render-popup", "--render-history":
                guard let path else { fail("missing output path for \(flag)") }
                exit(MainActor.assumeIsolated { Renderer.run(flag, to: URL(fileURLWithPath: path)) } ? 0 : 1)
            case "--help":
                print(usage)
                exit(0)
            default:
                fail("unknown option \(flag)")
            }
        }
        if ProcessInfo.processInfo.environment["NTFYBAR_TEST"] == "1",
           (ProcessInfo.processInfo.environment["NTFYBAR_CONFIG_DIR"] ?? "").isEmpty {
            fail("NTFYBAR_TEST=1 needs NTFYBAR_CONFIG_DIR, so a test run never touches the real config")
        }
        NtfyBarApp.main()
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("NtfyBar: \(message)\n\(usage)\n".utf8))
        exit(2)
    }
}
