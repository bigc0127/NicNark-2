//
//  AbsorptionConstants+Brand.swift
//  nicnark-2
//
//  Brand-aware overloads. Original methods keep A = 0.30; these take an explicit cap.
//

import Foundation

extension AbsorptionConstants {

    public func calculateAbsorbedNicotine(
        nicotineContent: Double,
        useTime: TimeInterval,
        fullReleaseTime: TimeInterval,
        absorptionFraction: Double
    ) -> Double {
        let release = max(1, fullReleaseTime)
        let cap = max(0, absorptionFraction)
        let fractionalTime = useTime / release
        let absorbedFraction = min(cap * fractionalTime, cap)
        return nicotineContent * absorbedFraction
    }

    public func calculateCurrentNicotineLevel(
        nicotineContent: Double,
        elapsedTime: TimeInterval,
        fullReleaseTime: TimeInterval,
        absorptionFraction: Double
    ) -> Double {
        calculatePlasmaLevel(
            nicotineContent: nicotineContent,
            timeSinceInsertion: elapsedTime,
            timeInMouth: elapsedTime,
            fullReleaseTime: fullReleaseTime,
            absorptionFraction: absorptionFraction
        )
    }

    public func calculatePlasmaLevel(
        nicotineContent: Double,
        timeSinceInsertion: TimeInterval,
        timeInMouth: TimeInterval,
        fullReleaseTime: TimeInterval,
        absorptionFraction: Double
    ) -> Double {
        let t = max(0, timeSinceInsertion)
        let T = max(1, fullReleaseTime)
        let tMouth = min(max(0, timeInMouth), t)
        let tInput = min(tMouth, T)
        let deliverable = max(0, nicotineContent) * max(0, absorptionFraction)
        guard deliverable > 0, tInput > 0 else { return 0 }

        let ke = Self.eliminationRateConstant
        let infusionRate = deliverable / T
        let levelAtInputEnd = (infusionRate / ke) * (1 - exp(-ke * tInput))
        let tAfterInput = t - tInput
        if tAfterInput <= 0 {
            return max(0, levelAtInputEnd)
        }
        return max(0, levelAtInputEnd * exp(-ke * tAfterInput))
    }
}
