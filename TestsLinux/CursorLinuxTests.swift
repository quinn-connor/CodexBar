#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct CursorLinuxTests {
    @Test
    func `Cursor database path honors absolute XDG config home`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: ["XDG_CONFIG_HOME": "/custom/config"])
        #expect(path == "/custom/config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `Cursor database path falls back to dot config`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: [:])
        #expect(path == "/home/test/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `Cursor database path rejects relative XDG config home`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: ["XDG_CONFIG_HOME": "relative/config"])
        #expect(path == "/home/test/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `Cursor descriptor accepts explicit web source`() {
        #expect(CursorProviderDescriptor.descriptor.fetchPlan.sourceModes.contains(.web))
    }

}
#endif
