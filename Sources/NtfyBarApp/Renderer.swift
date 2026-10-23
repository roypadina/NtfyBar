import Foundation

// shortcut: M1 placeholder — off-screen renders arrive in M2b.
@MainActor enum Renderer {
    static func run(_ flag: String, to url: URL) -> Bool {
        FileHandle.standardError.write(Data("NtfyBar: \(flag) is not available in this build\n".utf8))
        return false
    }
}
