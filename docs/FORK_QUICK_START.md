---
summary: "AgentBar fork identity, security boundary, and development commands."
read_when:
  - Working on the personal AgentBar fork
  - Reviewing fork-specific security changes
---

# AgentBar fork quick start

AgentBar is Quinn's personal CodexBar fork at <https://github.com/quinn-connor/CodexBar>. The upstream project remains
<https://github.com/steipete/CodexBar>.

## Fork boundary

- Bundle ID: `com.yoyodyne.AgentBar`
- Team ID: `FSJ87X623Z`
- Config credentials: Data Protection Keychain
- In-app updates: none
- Release feed: none

AgentBar does not reuse the upstream bundle ID, app group, Keychain service namespace, signing identity, or
update key. Xcode manages signing automatically for the configured team. Never commit exported certificates,
provisioning profiles, or App Store Connect credentials.

## Commands

```bash
swift build
make test
make check
./Scripts/package_app.sh
```

Local packaging creates `AgentBar.app` and uses ad hoc signing unless identity signing is explicitly requested. See
`docs/RELEASING.md` before distributing a build.

## Security notes

- The standalone CLI can inspect only redacted protected config metadata.
- Provider credentials are never written to the JSON config by the macOS app.
- Browser credential access is distinct from app-owned config credential storage.
- Logs and diagnostics must not include raw tokens, cookie headers, response bodies, or subprocess credential output.
