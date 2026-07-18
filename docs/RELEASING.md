---
summary: "AgentBar distribution boundaries and signing notes."
read_when:
  - Packaging or distributing AgentBar
  - Updating signing or bundle metadata
---

# AgentBar distribution

AgentBar is a personal fork with no in-app updater or inherited release feed. Do not publish builds under the
upstream CodexBar bundle identifier, Team ID, app group, update feed, or signing identity.

## Identity

- Bundle ID: `com.yoyodyne.AgentBar`
- Debug bundle ID: `com.yoyodyne.AgentBar.debug`
- Apple Developer Team: `FSJ87X623Z`
- Widget bundle ID: the app bundle ID plus `.widget`
- App group: the Team ID plus the app bundle ID

Xcode selects the signing certificate and provisioning assets automatically. Do not commit certificates,
provisioning profiles, App Store Connect keys, or exported signing credentials.

## Local packaging

`./Scripts/package_app.sh` creates `AgentBar.app` with ad hoc signing by default. This is suitable for local
verification only. A distributable build must be signed by the configured Apple Developer team, notarized, stapled,
and verified on a clean Mac before use.

The fork deliberately has no automated publishing script. Distribution is a separate, explicit operation so a fork
build cannot inherit an upstream feed or release credential by accident.
