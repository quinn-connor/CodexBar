import AppKit

extension StatusItemController {
    func wireAgentSessionUpdates() {
        self.agentSessions.onUpdate = { [weak self] in
            guard let self else { return }
            if let latestActivityAt = self.agentSessions.latestLocalActivityAt {
                self.store.noteCodingActivityObserved(at: latestActivityAt)
            } else {
                self.store.clearCodingActivityObservation()
            }
            if self.settings.agentSessionsEnabled {
                self.invalidateMenus(refreshOpenMenus: true)
            }
        }
    }

    func synchronizeAgentSessionsForSettingsChange() {
        let sessionConfigurationChanged = self.settings.agentSessionsEnabled != self.lastAgentSessionsEnabled
        let monitoringChanged =
            self.settings.refreshFrequency != self.lastAgentSessionsRefreshFrequency ||
            self.settings.adaptiveActivityScanningEnabled != self.lastAdaptiveActivityScanningEnabled
        guard sessionConfigurationChanged || monitoringChanged else { return }

        self.lastAgentSessionsEnabled = self.settings.agentSessionsEnabled
        self.lastAgentSessionsRefreshFrequency = self.settings.refreshFrequency
        self.lastAdaptiveActivityScanningEnabled = self.settings.adaptiveActivityScanningEnabled
        if !self.settings.adaptiveActivityScanningEnabled {
            self.store.clearCodingActivityObservation()
        }
        self.agentSessions.settingsDidChange()
    }

    @objc func focusAgentSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String,
              let session = self.agentSessions.localSessions.first(where: { $0.id == sessionID })
        else { return }
        self.agentSessions.focus(session)
    }
}
