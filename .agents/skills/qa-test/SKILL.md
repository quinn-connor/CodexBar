---
name: qa-test
description: "AgentBar app QA: validate provider behavior, packaged app contents, menus, and credential handling without relying on a bundled CLI."
---

# AgentBar QA

Use for live provider testing, release smoke tests, menu verification, or debugging provider failures.

## Rules

- Work from the repository checkout.
- Never run broad `env`, `set`, or secret-regex dumps.
- Treat browser-cookie and Keychain flows as prompt-risky. Prefer unit tests and `KeychainNoUIQuery`-safe checks unless the user explicitly requests live UI.
- Do not launch the app while automated tests are running.
- For current API behavior, use official provider documentation.

## Verification

1. Run focused tests for the changed provider or feature.
2. Run `make check` and `CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 make test`.
3. Package the app with `Scripts/package_app.sh` when bundle layout or signing changed.
4. Inspect the packaged bundle and entitlements directly.
5. Use app UI automation only when the user requested live behavior proof.

## Credential safety

- Never print API keys, cookies, OAuth tokens, Keychain values, or full configuration files.
- Verify secret persistence through the secret-store abstraction and metadata-only Keychain queries.
- If live credentials are unavailable, report the exact authentication blocker rather than weakening checks.

## Fix triage

- Missing auth/session: configure it only when authorized; otherwise leave the provider disabled or report blocked authentication.
- Wrong provider API/spec: inspect official docs, then patch the fetcher, settings UI, and tests together.
- User-facing behavior changes need a changelog entry.
