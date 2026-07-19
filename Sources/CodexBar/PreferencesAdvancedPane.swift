import CodexBarCore
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.$settings.hidePersonalInfo) {
                    SettingsRowLabel(L("hide_personal_info_title"), subtitle: L("hide_personal_info_subtitle"))
                }

                Toggle(isOn: self.$settings.debugDisableKeychainAccess) {
                    SettingsRowLabel(
                        L("disable_keychain_access_title"),
                        subtitle: L("disable_keychain_access_subtitle"))
                }
            } header: {
                Text(L("section_privacy"))
            } footer: {
                SettingsSectionFooter(L("keychain_access_caption"))
            }

            Section {
                Toggle(isOn: self.$settings.providerStorageFootprintsEnabled) {
                    SettingsRowLabel(
                        L("show_provider_storage_usage_title"),
                        subtitle: L("show_provider_storage_usage_subtitle"))
                }

                Toggle(isOn: self.$settings.debugMenuEnabled) {
                    SettingsRowLabel(L("show_debug_settings_title"), subtitle: L("show_debug_settings_subtitle"))
                }
            } header: {
                Text(L("section_diagnostics"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
    }
}
