# Security Policy

## Reporting a Vulnerability

Please **do not** open a public issue for security problems. Use GitHub's private vulnerability
reporting instead (**Security → Report a vulnerability** on this repository).

You'll get an acknowledgement within a few days. Once a fix is available it will be released and
the report disclosed, with credit unless you prefer otherwise.

## Scope

NtfyBar handles content that anyone who knows a topic name can send, so these areas matter most:

- **Message content** reaching anything that runs or opens things: user commands (message data is
  passed only through environment variables and stdin), URL opening (http/https only), ntfy action
  buttons, markdown links, regex conditions.
- **The plugin sandbox**: JavaScriptCore runtime, permission enforcement, redaction of topic names
  and server addresses, the marketplace installer and its SHA-256 checks.
- **Credentials and topics** at rest: `~/Library/Application Support/NtfyBar/` (mode 600 files,
  history unencrypted by design), and never in logs.

Out of scope: someone who already knows your topic name sending you messages (that is how ntfy
works — topic names are capabilities; use long random ones), and ntfy servers themselves (report
those to [ntfy](https://github.com/binwiederhier/ntfy)).
