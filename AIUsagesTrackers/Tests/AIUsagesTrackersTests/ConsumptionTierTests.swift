import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - consumptionTier(ratio:)

@Suite("consumptionTier mapping")
struct ConsumptionTierMappingTests {

    @Test("negative ratio maps to comfortable")
    func negativeRatio() {
        #expect(consumptionTier(ratio: -0.5) == .comfortable)
    }

    @Test("zero ratio maps to comfortable")
    func zeroRatio() {
        #expect(consumptionTier(ratio: 0.0) == .comfortable)
    }

    @Test("ratio 0.69 maps to comfortable")
    func justBelowOnTrack() {
        #expect(consumptionTier(ratio: 0.69) == .comfortable)
    }

    @Test("ratio 0.7 maps to onTrack")
    func exactlyOnTrack() {
        #expect(consumptionTier(ratio: 0.7) == .onTrack)
    }

    @Test("ratio 0.89 maps to onTrack")
    func justBelowApproaching() {
        #expect(consumptionTier(ratio: 0.89) == .onTrack)
    }

    @Test("ratio 0.9 maps to approaching")
    func exactlyApproaching() {
        #expect(consumptionTier(ratio: 0.9) == .approaching)
    }

    @Test("ratio 0.99 maps to approaching")
    func justBelowOver() {
        #expect(consumptionTier(ratio: 0.99) == .approaching)
    }

    @Test("ratio 1.0 maps to over")
    func exactlyOver() {
        #expect(consumptionTier(ratio: 1.0) == .over)
    }

    @Test("ratio 1.19 maps to over")
    func justBelowCritical() {
        #expect(consumptionTier(ratio: 1.19) == .over)
    }

    @Test("ratio 1.2 maps to critical")
    func exactlyCritical() {
        #expect(consumptionTier(ratio: 1.2) == .critical)
    }

    @Test("ratio 1.59 maps to critical")
    func justBelowExhausted() {
        #expect(consumptionTier(ratio: 1.59) == .critical)
    }

    @Test("ratio 1.6 maps to exhausted")
    func exactlyExhausted() {
        #expect(consumptionTier(ratio: 1.6) == .exhausted)
    }

    @Test("ratio 2.0 maps to exhausted")
    func highRatio() {
        #expect(consumptionTier(ratio: 2.0) == .exhausted)
    }
}

// MARK: - Comparable ordering

@Suite("ConsumptionTier ordering")
struct ConsumptionTierOrderingTests {

    @Test("tiers are ordered by severity")
    func ordering() {
        #expect(ConsumptionTier.comfortable < .onTrack)
        #expect(ConsumptionTier.onTrack < .approaching)
        #expect(ConsumptionTier.approaching < .over)
        #expect(ConsumptionTier.over < .critical)
        #expect(ConsumptionTier.critical < .exhausted)
    }

    @Test("max of two tiers returns the worse one")
    func maxReturnsWorst() {
        #expect(max(ConsumptionTier.comfortable, .critical) == .critical)
        #expect(max(ConsumptionTier.exhausted, .onTrack) == .exhausted)
    }
}

// MARK: - consumptionRatio

@Suite("consumptionRatio computation")
struct ConsumptionRatioTests {

    @Test("normal case: 50% usage at 50% elapsed = ratio 1.0")
    func normalCase() {
        let result = consumptionRatio(actualPercent: 50, theoreticalFraction: 0.5)
        #expect(result != nil)
        #expect(abs(result! - 1.0) < 0.001)
    }

    @Test("half usage at full elapsed = ratio 0.5")
    func underConsuming() {
        let result = consumptionRatio(actualPercent: 50, theoreticalFraction: 1.0)
        #expect(result != nil)
        #expect(abs(result! - 0.5) < 0.001)
    }

    @Test("full usage at half elapsed = ratio 2.0")
    func overConsuming() {
        let result = consumptionRatio(actualPercent: 100, theoreticalFraction: 0.5)
        #expect(result != nil)
        #expect(abs(result! - 2.0) < 0.001)
    }

    @Test("zero theoretical fraction returns nil")
    func zeroTheoretical() {
        let result = consumptionRatio(actualPercent: 50, theoreticalFraction: 0.0)
        #expect(result == nil)
    }

    @Test("negative theoretical fraction returns nil")
    func negativeTheoretical() {
        let result = consumptionRatio(actualPercent: 50, theoreticalFraction: -0.1)
        #expect(result == nil)
    }

    @Test("zero actual percent returns ratio 0.0")
    func zeroActual() {
        let result = consumptionRatio(actualPercent: 0, theoreticalFraction: 0.5)
        #expect(result != nil)
        #expect(result! == 0.0)
    }
}
