import os

/// Unified logging only (no file log). Read with:
/// `/usr/bin/log show --info --predicate 'subsystem == "com.padina.ntfybar"'`.
/// Never log raw topic strings, server URLs or raw stream lines.
public enum Log {
    public static let subsystem = "com.padina.ntfybar"
    public static let config = Logger(subsystem: subsystem, category: "config")
    public static let stream = Logger(subsystem: subsystem, category: "stream")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let dispatch = Logger(subsystem: subsystem, category: "dispatch")
    public static let command = Logger(subsystem: subsystem, category: "command")
    public static let publish = Logger(subsystem: subsystem, category: "publish")
    public static let plugins = Logger(subsystem: subsystem, category: "plugins")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
