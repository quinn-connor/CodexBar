# Agent Sessions (prototype)

Track live local Codex + Claude Code agent sessions and surface them in the CodexBar menu with click-to-focus of the owning terminal window.

## Why in CodexBar

CodexBar already parses `~/.claude/projects` JSONL for local cost scans. Agent Sessions reuses that local parsing infrastructure without a daemon, network discovery, or SSH.

## Data model (CodexBarCore)

```swift
public struct AgentSession: Codable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable { case codex, claude }
    public enum Source: String, Codable, Sendable { case cli, desktopApp, ide, unknown }
    public enum State: String, Codable, Sendable { case active, idle }

    public var id: String            // session UUID when resolvable, else "pid:<pid>"
    public var provider: Provider
    public var source: Source
    public var state: State
    public var pid: Int32?           // nil for file-only (e.g. Codex desktop) sessions
    public var cwd: String?
    public var projectName: String?  // last path component of cwd
    public var startedAt: Date?
    public var lastActivityAt: Date? // transcript mtime
    public var transcriptPath: String?
    public var host: String          // local hostname, or remote host label
}
```

`active` = last activity ≤ 120 s ago. `idle` = live process (or recent file) with older activity. Constants live in one `SessionScanConfig` struct (activeWindow 120 s, fileOnlyWindow 30 min) so thresholds are tunable/testable.

## Local scanner (CodexBarCore, no new deps)

`LocalAgentSessionScanner` combines two signals:

1. **Process scan** — parse `ps -axo pid=,ppid=,lstart=,command=`.
   - Claude: command basename `claude` (skip obvious non-agent helpers). Source: path contains `Application Support/Claude/claude-code` → `.desktopApp`, else `.cli`. Deduplicate the wrapper/child pair (desktop spawns `disclaimer` parent + `claude` child with same argv; keep the child).
   - Codex: basename `codex` with no `app-server` argument → `.cli` (TUI or `exec`). `codex app-server` marks the desktop app as present but is not itself a session.
   - cwd per pid via one batched `lsof -a -d cwd -Fn -p <pid,pid,…>` call (parse `p`/`n` records). Failure → cwd nil, session still listed.
2. **Transcript correlation**
   - Claude: cwd → `~/.claude/projects/<escaped-cwd>/` (escape: every non-alphanumeric ASCII → `-`), newest `*.jsonl` by mtime → session id (filename UUID), lastActivityAt (mtime). Also reuse `ClaudeDesktopProjectsLocator` roots so desktop local-agent-mode sessions resolve.
   - Codex: enumerate `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` for today + yesterday (`$CODEX_HOME` respected). Read only the first line (`session_meta`: `session_id`, `cwd`, `originator`, `source`). File with mtime ≤ fileOnlyWindow and no matching live pid → file-only session, source from `originator` (`codex_exec`/`exec` → `.cli`; ide-ish originators → `.ide`; desktop → `.desktopApp`). Live `codex` pids match to rollouts by cwd (newest wins); unmatched live pid still listed with nil transcript.
   - Never read more than the first line of any JSONL; never load whole transcripts.

Scanner is `Sendable`, pure functions where possible; ps/lsof output parsing lives in dedicated parser types fed by strings so tests use fixtures.

## Menu UI (CodexBar app)

- Menu section **Agent Sessions (N)** above the settings/footer area, built through the existing `MenuDescriptor` seam so it is testable headless.
- Row: state dot (● active / ○ idle), provider glyph, `projectName — provider · source · 12m`.
- Click a row to invoke `SessionWindowFocuser` locally.
- Settings: a single opt-in enable toggle persisted in `SettingsStore`.

## Focus (macOS app)

`SessionWindowFocuser`:

1. pid → walk ppid chain to the nearest ancestor whose `NSRunningApplication.bundleIdentifier` is a known terminal/editor host: Ghostty, iTerm2, Apple Terminal, Warp, WezTerm, kitty, Alacritty, VS Code, Cursor, Zed, Claude desktop (`com.anthropic.claudefordesktop`). Fallback: the app owning the pid.
2. Activate the app, then AX (`AXUIElementCreateApplication` → `AXWindows`): raise the window whose title contains projectName or the cwd tail; fallback to frontmost window of that app. Requires Accessibility permission — call `AXIsProcessTrustedWithOptions` with prompt on first use; degrade gracefully (activate app only) when untrusted.
3. File-only sessions (no pid): Claude desktop → activate Claude.app; Codex desktop → activate Codex.app; otherwise no-op with log.

tmux pane / terminal-tab precision is out of scope for the prototype.

## Tests (Tests/CodexBarTests)

Fixture-driven, no live processes, no Keychain/AX:

- ps output parser: desktop `disclaimer`+`claude` dedupe, codex vs `codex app-server`, weird argv.
- lsof `-Fn` parser.
- Claude cwd escaping → project dir mapping; newest-jsonl selection (temp dirs).
- Codex rollout first-line parse → AgentSession (fixture JSONL), file-only window cutoff.
- Menu section descriptor: local counts and empty-state rendering.

## Non-goals (prototype)

Claude.ai chat sessions; Codex cloud tasks; historical session browsing/analytics; "waiting on permission" state; tmux pane/tab focus; remote discovery or SSH; Bonjour/mDNS; or persistent remote daemon or push transport. No new SPM dependencies.

## Proof

`make check` clean; `make test` (or focused `swift test --filter` covering the new tests) green.
