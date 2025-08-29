// AbsorptionConstants.swift
// Widget Extension Version

import Foundation

// MARK: - Global Constants
public let ABSORPTION_FRACTION: Double = 0.30
public let FULL_RELEASE_TIME: TimeInterval = 30 * 60 // 30 minutes

public struct AbsorptionConstants {
    // MARK: - Singleton for performance
    public static let shared = AbsorptionConstants()
    
    // MARK: - Constants
    static let nicotineHalfLife: TimeInterval = 2 * 3600 // 2 hours
    static let maxAbsorptionRate: Double = 1.0
    
    // Internal init - prefer using .shared for better performance
    internal init() {}

    // MARK: - Absorption Calculations

    /// Calculates absorbed nicotine based on time in mouth
    @Sendable
    public func calculateAbsorbedNicotine(nicotineContent: Double, useTime: TimeInterval) -> Double {
        let fractionalTime = useTime / FULL_RELEASE_TIME
        let absorbedFraction = min(ABSORPTION_FRACTION * fractionalTime, ABSORPTION_FRACTION)
        return nicotineContent * absorbedFraction
    }

    /// Calculates current nicotine level during absorption
    @Sendable
    public func calculateCurrentNicotineLevel(nicotineContent: Double, elapsedTime: TimeInterval) -> Double {
        return calculateAbsorbedNicotine(nicotineContent: nicotineContent, useTime: elapsedTime)
    }

    /// Calculates absorption rate as percentage (0.0 to 1.0)
    @Sendable
    public func calculateAbsorptionRate(elapsedTime: TimeInterval) -> Double {
        return min(elapsedTime / FULL_RELEASE_TIME, Self.maxAbsorptionRate)
    }

    /// Calculates nicotine decay after pouch removal
    @Sendable
    public func calculateDecayedNicotine(initialLevel: Double, timeSinceRemoval: TimeInterval) -> Double {
        let decayFactor = exp(-log(2.0) * timeSinceRemoval / Self.nicotineHalfLife)
        return initialLevel * decayFactor
    }
}
