import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeScopedWeeklyPaceMenuCardTests {
    @Test
    func `Fable scoped weekly row renders pace without changing Daily Routines`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let model = try Self.model(
            now: now,
            extraRateWindows: [
                Self.namedWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    usedPercent: 50,
                    resetsAt: now.addingTimeInterval(4 * 24 * 3600)),
                Self.namedWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    usedPercent: 50,
                    resetsAt: now.addingTimeInterval(4 * 24 * 3600)),
            ])

        let fable = try #require(model.metrics.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.detailLeftText == "7% in deficit")
        #expect(fable.detailRightText == "Runs out in 3d")
        #expect(abs((fable.pacePercent ?? 0) - (400.0 / 7.0)) < 0.01)
        #expect(fable.paceOnTop == false)

        let routines = try #require(model.metrics.first { $0.id == "claude-routines" })
        #expect(routines.detailLeftText == nil)
        #expect(routines.detailRightText == nil)
        #expect(routines.pacePercent == nil)
    }

    @Test
    func `Fable scoped weekly pace respects configured work days`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 23,
            hour: 12)))
        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 27,
            hour: 12)))
        let model = try Self.model(
            now: now,
            extraRateWindows: [
                Self.namedWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    usedPercent: 50,
                    resetsAt: resetsAt),
            ],
            workDaysPerWeek: 5)

        let fable = try #require(model.metrics.first)
        #expect(fable.detailLeftText == "10% in reserve")
        #expect(fable.detailRightText == "Lasts until reset")
        #expect(fable.pacePercent == 40)
        #expect(fable.paceOnTop)
    }

    @Test
    func `Fable scoped weekly row hides pace when reset time is unavailable`() throws {
        let model = try Self.model(
            now: Date(timeIntervalSince1970: 0),
            extraRateWindows: [
                Self.namedWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    usedPercent: 50,
                    resetsAt: nil),
            ])

        let fable = try #require(model.metrics.first)
        #expect(fable.title == "Fable only")
        #expect(fable.percentLabel == "50% left")
        #expect(fable.detailLeftText == nil)
        #expect(fable.detailRightText == nil)
        #expect(fable.pacePercent == nil)
    }

    private static func model(
        now: Date,
        extraRateWindows: [NamedRateWindow],
        workDaysPerWeek: Int? = nil) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: extraRateWindows,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Max"))

        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            workDaysPerWeek: workDaysPerWeek,
            now: now))
    }

    private static func namedWindow(
        id: String,
        title: String,
        usedPercent: Double,
        resetsAt: Date?) -> NamedRateWindow
    {
        NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetsAt,
                resetDescription: nil))
    }
}
