---
name: release-codexbar
description: "AgentBar personal-fork release: versioning, Xcode-managed signing, packaging, and app-only release verification."
---

# AgentBar Release

Use for app-only releases from this personal fork. The fork does not ship Sparkle, a command-line executable, or standalone CLI archives.

## Start

1. Check repository state, version metadata, release scripts, and `CHANGELOG.md`.
2. Run `make check` and `CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 make test`.
3. Build the packaged app through `Scripts/package_app.sh`.
4. Use bundle ID `com.yoyodyne.AgentBar`, team `FSJ87X623Z`, and Xcode automatic signing.
5. Never print certificate, provisioning, API, cookie, OAuth, or Keychain material.

## Verify

```bash
codesign --verify --deep --strict --verbose=2 AgentBar.app
codesign -d --entitlements :- AgentBar.app
find AgentBar.app -type f -perm -111 -print
```

Confirm the executable inventory is intentional and the bundle contains no updater framework, update feed, command-line helper, or WidgetKit extension.

## Closeout

1. Record the version and user-facing changes.
2. Keep release changes in an atomic commit.
3. Creating or pushing a tag or GitHub release requires explicit user confirmation.
