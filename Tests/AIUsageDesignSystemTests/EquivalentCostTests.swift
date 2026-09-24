import Foundation
import Testing
import AIUsageCore
@testable import AIUsageDesignSystem

struct EquivalentCostTests {
    @Test func pricedAndPartiallyPricedAmountsUseTheApprovedCopy() {
        let complete = totals(cost: 105, hasUnpricedModels: false)
        let partial = totals(cost: 105, hasUnpricedModels: true)

        #expect(equivalentCostHelp(complete, language: .english)
            == "Equivalent cost at API rates for the current weekly period. This is an estimate.")
        #expect(equivalentCostHelp(partial, language: .english)
            == equivalentCostHelp(complete, language: .english))
        #expect(equivalentCostHelp(partial, language: .spanish)
            == "Coste equivalente a tarifas API durante el periodo semanal actual. Estimación.")
        #expect(equivalentCost(complete, language: .english) == "~$105")
        #expect(equivalentCost(partial, language: .english) == "~$105")
    }

    @Test func unavailablePriceIsNotPresentedAsAnEstimate() {
        let unpriced = totals(cost: nil, hasUnpricedModels: true)
        #expect(equivalentCost(unpriced, language: .english) == "N/A")
        #expect(equivalentCostHelp(unpriced, language: .english)
            == "No public API rate or model breakdown is available for this period. Tokens and limits still update normally.")
    }

    private func totals(cost: Double?, hasUnpricedModels: Bool) -> WeeklyUsageTotals {
        WeeklyUsageTotals(
            inputTokens: 1,
            cachedInputTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            equivalentCostUSD: cost,
            hasUnpricedModels: hasUnpricedModels,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 1)
        )
    }
}
