import Foundation

/// Native conditions and actions. Only these (and the user's own topic command) can run
/// commands, open URLs or play sounds; plugin JavaScript goes through the permission bridge.
@MainActor
enum BuiltinProviders {
    static func register(in r: ProviderRegistry) {
        func condition(_ id: String, _ name: String, _ description: String, _ params: [ParamSpec] = [],
                       _ fn: @escaping ProviderRegistry.Condition) {
            r.register(ProviderDescriptor(id: id, kind: .condition, name: name, description: description, params: params), condition: fn)
        }
        func action(_ id: String, _ name: String, _ description: String, _ params: [ParamSpec] = [],
                    _ fn: @escaping ProviderRegistry.Action) {
            r.register(ProviderDescriptor(id: id, kind: .action, name: name, description: description, params: params), action: fn)
        }

        // MARK: conditions

        condition("builtin.priority", "Priority", "Compare the message priority (1 min … 5 urgent).",
                  [ParamSpec("op", "Comparison", .choice, choices: [">=", "==", "<="]), ParamSpec("value", "Priority", .number, placeholder: "4")]) { ctx, p in
            let value = p.int("value") ?? 3
            switch p.string("op") ?? ">=" {
            case "==": return ctx.message.priority == value
            case "<=": return ctx.message.priority <= value
            default: return ctx.message.priority >= value
            }
        }
        condition("builtin.titleContains", "Title contains", "Case-insensitive text in the title.",
                  [ParamSpec("needle", "Text")]) { ctx, p in
            (ctx.message.title ?? "").localizedCaseInsensitiveContains(try p.required("needle"))
        }
        condition("builtin.titleRegex", "Title matches regex", "Regular expression on the title.",
                  [ParamSpec("pattern", "Pattern")]) { ctx, p in
            try matches(ctx.message.title ?? "", p.required("pattern"))
        }
        condition("builtin.messageContains", "Message contains", "Case-insensitive text in the message body.",
                  [ParamSpec("needle", "Text")]) { ctx, p in
            ctx.message.body.localizedCaseInsensitiveContains(try p.required("needle"))
        }
        condition("builtin.messageRegex", "Message matches regex", "Regular expression on the message body.",
                  [ParamSpec("pattern", "Pattern")]) { ctx, p in
            try matches(ctx.message.body, p.required("pattern"))
        }
        condition("builtin.hasTag", "Has tag", "The message carries this tag.", [ParamSpec("tag", "Tag")]) { ctx, p in
            let tag = try p.required("tag")
            return ctx.message.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        condition("builtin.hasClick", "Has click URL", "The message has a click URL.") { ctx, _ in
            !(ctx.message.ntfy.click ?? "").isEmpty
        }
        condition("builtin.hasAttachment", "Has attachment", "The message has an attachment.") { ctx, _ in
            ctx.message.ntfy.attachment != nil
        }
        condition("builtin.isJSON", "Message is JSON", "The message body is a JSON object or array.") { ctx, _ in
            guard let v = JSONValue.parse(ctx.message.body) else { return false }
            if case .object = v { return true }
            if case .array = v { return true }
            return false
        }

        // MARK: actions

        action("builtin.notify", "Show notification", "Post a macOS notification.") { ctx, _ in
            ActionOutput([.notify(ctx.message, label: ctx.label)])
        }
        action("builtin.popup", "Show popup", "Show NtfyBar's popup, with optional overrides and extra buttons.",
               [ParamSpec("timeoutSec", "Timeout (s, 0 = stays)", .number, placeholder: "20"),
                ParamSpec("level", "Level", .choice, choices: PopupSettings.Level.allCases.map(\.rawValue)),
                ParamSpec("position", "Position", .choice, choices: PopupSettings.Position.allCases.map(\.rawValue)),
                ParamSpec("buttonLabel", "Extra button label", placeholder: "Open dashboard"),
                ParamSpec("buttonURL", "Extra button URL template", placeholder: "https://example.com/?q={title}")]) { ctx, p in
            var s = ctx.topic.popup
            s.enabled = true
            if let t = p.int("timeoutSec") { s.timeoutSec = max(0, t) }
            if let l = p.string("level").flatMap(PopupSettings.Level.init(rawValue:)) { s.level = l }
            if let pos = p.string("position").flatMap(PopupSettings.Position.init(rawValue:)) { s.position = pos }
            var buttons: [PopupButton] = []
            if let label = p.string("buttonLabel"), !label.isEmpty, let tpl = p.string("buttonURL") {
                let url = Template.render(tpl, message: ctx.message, topicLabel: ctx.label, urlEncode: true)
                guard SafeOpen.url(url) != nil else { throw ProviderError.badParams("buttonURL must be an http(s) URL") }
                buttons.append(PopupButton(id: "rule-button", label: label, openURL: url))
            }
            return ActionOutput([.popup(PopupRequest(message: ctx.message, label: ctx.label, settings: s, extraButtons: buttons))])
        }
        action("builtin.copy", "Copy to clipboard", "Copy the message, title, click URL, JSON or a template.",
               [ParamSpec("what", "What", .choice, choices: ["message", "title", "click", "json", "template"]),
                ParamSpec("template", "Template", placeholder: "{title}: {message}")]) { ctx, p in
            let m = ctx.message
            let text: String
            switch p.string("what") ?? "message" {
            case "title": text = m.title ?? ""
            case "click": text = m.ntfy.click ?? ""
            case "json": text = m.raw
            case "template": text = Template.render(try p.required("template"), message: m, topicLabel: ctx.label)
            default: text = m.body
            }
            return ActionOutput([.copy(text)])
        }
        action("builtin.runCommand", "Run command", "Run a shell command. Message data arrives in NTFY_* variables and on stdin.",
               [ParamSpec("command", "Command", placeholder: "say \"$NTFY_TITLE\""),
                ParamSpec("timeoutSec", "Timeout (s)", .number, placeholder: "30"),
                ParamSpec("notifyOnFailure", "Notify on failure", .bool)]) { ctx, p in
            let cmd = CommandSettings(command: try p.required("command"), timeoutSec: max(1, p.int("timeoutSec") ?? 30),
                                      notifyOnFailure: p.bool("notifyOnFailure") ?? true)
            return ActionOutput([.runCommand(cmd, ctx.message, label: ctx.label)])
        }
        action("builtin.openClick", "Open click URL", "Open the message's click URL (http/https only).") { ctx, _ in
            guard let url = SafeOpen.url(ctx.message.ntfy.click) else { return ActionOutput() }
            return ActionOutput([.openURL(url)])
        }
        action("builtin.openURL", "Open URL", "Open a URL built from a template; values are URL-encoded.",
               [ParamSpec("template", "URL template", placeholder: "https://example.com/search?q={title}")]) { ctx, p in
            let text = Template.render(try p.required("template"), message: ctx.message, topicLabel: ctx.label, urlEncode: true)
            guard let url = SafeOpen.url(text) else { throw ProviderError.badParams("template must produce an http(s) URL") }
            return ActionOutput([.openURL(url)])
        }
        action("builtin.publish", "Publish message", "Publish to one of your topics (quiet hours apply).",
               [ParamSpec("topicId", "Topic", .topic), ParamSpec("title", "Title template"),
                ParamSpec("message", "Message template", placeholder: "Seen: {title}"),
                ParamSpec("priority", "Priority", .number, placeholder: "3"), ParamSpec("tags", "Tags (comma-separated)")]) { ctx, p in
            guard let id = p.string("topicId").flatMap(UUID.init(uuidString:)), ctx.config.topic(id) != nil else {
                throw ProviderError.badParams("topicId must be one of your topics")
            }
            let title = p.string("title").map { Template.render($0, message: ctx.message, topicLabel: ctx.label) }
            let req = PublishRequest(topicId: id, title: title?.isEmpty == true ? nil : title,
                                     message: Template.render(try p.required("message"), message: ctx.message, topicLabel: ctx.label),
                                     priority: min(5, max(1, p.int("priority") ?? 3)),
                                     tags: (p.string("tags") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return ActionOutput([.publish(req)])
        }
        action("builtin.runShortcut", "Run Shortcut", "Run a macOS Shortcut with the message as input.",
               [ParamSpec("name", "Shortcut name")]) { ctx, p in
            let name = try p.required("name")
            guard !name.hasPrefix("-") else { throw ProviderError.badParams("a Shortcut name can't start with -") }
            return ActionOutput([.runShortcut(name: name, ctx.message)])
        }
        action("builtin.playSound", "Play sound", "Play a system sound (e.g. Glass, Basso, Ping).",
               [ParamSpec("name", "Sound name", placeholder: "Glass")]) { _, p in
            ActionOutput([.playSound(try p.required("name"))])
        }
        action("builtin.ignore", "Skip topic defaults", "Don't run the topic's own notification/popup/copy/command for this message.") { _, _ in
            ActionOutput(suppressDefaults: true)
        }
    }

    static func matches(_ text: String, _ pattern: String) throws -> Bool {
        do {
            return try SafeRegex.matches(pattern, in: text)
        } catch SafeRegex.Failure.tooSlow {
            throw ProviderError.failed("regex took too long on this message (skipped)")
        } catch {
            throw ProviderError.badParams("invalid regex")
        }
    }
}
