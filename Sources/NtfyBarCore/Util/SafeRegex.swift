import Foundation

// ICU's own regex API, for its time limit: NSRegularExpression has none, and a user's pattern
// like `(a+)+$` on attacker-chosen text backtracks exponentially and would freeze the app.
// libicucore ships with macOS; the C symbols are bound by name (same approach as the JSC watchdog).
@_silgen_name("uregex_open")
private func uregex_open(_ pattern: UnsafePointer<UInt16>, _ length: Int32, _ flags: UInt32,
                         _ parseError: UnsafeMutableRawPointer?, _ status: UnsafeMutablePointer<Int32>) -> OpaquePointer?
@_silgen_name("uregex_setText")
private func uregex_setText(_ regex: OpaquePointer, _ text: UnsafePointer<UInt16>, _ length: Int32, _ status: UnsafeMutablePointer<Int32>)
@_silgen_name("uregex_setTimeLimit")
private func uregex_setTimeLimit(_ regex: OpaquePointer, _ limit: Int32, _ status: UnsafeMutablePointer<Int32>)
@_silgen_name("uregex_find")
private func uregex_find(_ regex: OpaquePointer, _ start: Int32, _ status: UnsafeMutablePointer<Int32>) -> Int8
@_silgen_name("uregex_close")
private func uregex_close(_ regex: OpaquePointer)

public enum SafeRegex {
    public enum Failure: Error, Equatable { case invalidPattern, tooSlow }

    /// Only the first 8 KB of the text is searched.
    public static let maxText = 8 * 1024
    static let timeLimit: Int32 = 500  // ICU match-engine steps (a few hundred ms at most)
    static let timedOut: Int32 = 66322  // U_REGEX_TIME_OUT

    public static func matches(_ pattern: String, in text: String) throws -> Bool {
        var status: Int32 = 0
        let p = Array(pattern.utf16)
        guard !p.isEmpty, let re = p.withUnsafeBufferPointer({ uregex_open($0.baseAddress!, Int32(p.count), 0, nil, &status) }),
              status <= 0 else { throw Failure.invalidPattern }
        defer { uregex_close(re) }
        uregex_setTimeLimit(re, timeLimit, &status)
        var t = Array(text.utf16.prefix(maxText))
        if t.isEmpty { t = [0] }  // ICU needs a valid pointer; a lone NUL never matches a real pattern meaningfully
        let length = text.isEmpty ? 0 : Int32(t.count)
        return try t.withUnsafeBufferPointer { buf in
            uregex_setText(re, buf.baseAddress!, length, &status)
            let found = uregex_find(re, 0, &status)
            if status == timedOut { throw Failure.tooSlow }
            guard status <= 0 else { throw Failure.invalidPattern }
            return found != 0
        }
    }
}
