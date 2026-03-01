// AbsorptionConstants.swift
// nicnark-2
//
// Contains all the mathematical models and constants for nicotine absorption and decay
// This file handles the core calculations that power the app's timing and level predictions

import Foundation
import CoreData

// MARK: - Global Constants
/**
 * ABSORPTION_FRACTION: What percentage of nicotine gets absorbed into bloodstream
 * Based on research showing ~30% of nicotine in pouches is actually absorbed
 * For example: 6mg pouch → ~1.8mg absorbed into bloodstream
 */
public let ABSORPTION_FRACTION: Double = 0.30

/**
 * FULL_RELEASE_TIME: How long it takes for maximum absorption
 * v2.0: Now configurable - 30, 45, or 60 minutes based on user preference
 * Research shows peak nicotine absorption varies by individual
 */
public var FULL_RELEASE_TIME: TimeInterval {
    // Access the saved duration directly from UserDefaults to avoid actor isolation issues
    let savedValue = UserDefaults.standard.integer(forKey: "selectedTimerDuration")
    if let duration = TimerDuration(rawValue: savedValue) {
        return duration.timeInterval
    } else {
        return TimerDuration.defaultDuration.timeInterval
    }
}

/**
 * AbsorptionConstants: Contains all the mathematical models for nicotine calculations
 * 
 * This singleton handles:
 * - Calculating how much nicotine is absorbed over time
 * - Modeling nicotine decay after pouch removal
 * - Converting time periods to absorption percentages
 * - Providing consistent calculations across the entire app
 */
public struct AbsorptionConstants: Sendable {
    // MARK: - Singleton Pattern
    // Use .shared instead of creating new instances for better performance and consistency
    public static let shared = AbsorptionConstants()
    
    // MARK: - Scientific Constants
    /**
     * nicotineHalfLife: How long it takes for nicotine levels to drop by 50%
     * Medical research shows nicotine half-life is approximately 2 hours
     * This means after 2 hours, only half the nicotine remains in your system
     */
    static let nicotineHalfLife: TimeInterval = 2 * 3600 // 2 hours in seconds
    
    /**
     * maxAbsorptionRate: Maximum absorption rate (100% = 1.0)
     * Used to cap calculations and prevent impossible values
     */
    static let maxAbsorptionRate: Double = 1.0
    
    // Private initializer - encourages using .shared instance
    internal init() {}

    // MARK: - Absorption Calculations

    /**
     * calculateAbsorbedNicotine: Main calculation for how much nicotine has been absorbed
     * 
     * This uses a linear absorption model for the active pouch phase:
     * - Absorption increases steadily from 0% to 30% over FULL_RELEASE_TIME
     * - Maximum 30% of the pouch content gets absorbed (ABSORPTION_FRACTION)
     * 
     * Formula: absorbed(t) = D × A × min(t / FULL_RELEASE_TIME, 1.0)
     * Where:
     * - D = nicotine dose/content of pouch (mg)
     * - A = absorption fraction (0.30 = 30%)
     * - t = time pouch has been in mouth (seconds)
     * - FULL_RELEASE_TIME = configurable duration (30, 45, or 60 minutes)
     * 
     * Example: 6mg pouch after 15 minutes (with 30min FULL_RELEASE_TIME)
     *   = 6 × 0.30 × (15/30) = 6 × 0.30 × 0.5 = 0.9mg absorbed
     * 
     * @param nicotineContent: Total nicotine in the pouch (e.g., 6mg)
     * @param useTime: How long the pouch has been in mouth (in seconds)
     * @return: Amount of nicotine absorbed into bloodstream (in mg)
     */

    public func calculateAbsorbedNicotine(nicotineContent: Double, useTime: TimeInterval) -> Double {
        return calculateAbsorbedNicotine(nicotineContent: nicotineContent, useTime: useTime, fullReleaseTime: FULL_RELEASE_TIME)
    }

    /// Duration-aware variant of `calculateAbsorbedNicotine`.
    /// Use this when a pouch has a custom absorption duration (e.g. per-can duration).

    public func calculateAbsorbedNicotine(nicotineContent: Double, useTime: TimeInterval, fullReleaseTime: TimeInterval) -> Double {
        let release = max(1, fullReleaseTime)

        // Calculate what fraction of the absorption period has elapsed
        let fractionalTime = useTime / release

        // Calculate absorption fraction (max 30%, scales with time)
        let absorbedFraction = min(ABSORPTION_FRACTION * fractionalTime, ABSORPTION_FRACTION)

        // Return total nicotine multiplied by absorption fraction
        return nicotineContent * absorbedFraction
    }

    /**
     * calculateCurrentNicotineLevel: Wrapper for absorption calculation
     * 
     * This is just an alias for calculateAbsorbedNicotine with a clearer name
     * Used when we want to emphasize we're getting the "current level" in bloodstream
     * 
     * @param nicotineContent: Total nicotine in the pouch (e.g., 6mg)
     * @param elapsedTime: How long the pouch has been in mouth (in seconds)
     * @return: Current nicotine level in bloodstream (in mg)
     */

    public func calculateCurrentNicotineLevel(nicotineContent: Double, elapsedTime: TimeInterval) -> Double {
        return calculateAbsorbedNicotine(nicotineContent: nicotineContent, useTime: elapsedTime)
    }

    /// Duration-aware variant of `calculateCurrentNicotineLevel`.

    public func calculateCurrentNicotineLevel(nicotineContent: Double, elapsedTime: TimeInterval, fullReleaseTime: TimeInterval) -> Double {
        return calculateAbsorbedNicotine(nicotineContent: nicotineContent, useTime: elapsedTime, fullReleaseTime: fullReleaseTime)
    }

    /**
     * calculateAbsorptionRate: Returns absorption progress as a percentage
     * 
     * This calculates how "complete" the absorption process is:
     * - 0.0 = just started (0%)
     * - 0.5 = halfway done (50%)
     * - 1.0 = fully absorbed (100%)
     * 
     * Used for progress bars and visual indicators
     * 
     * @param elapsedTime: How long the pouch has been in mouth (in seconds)
     * @return: Completion percentage from 0.0 to 1.0
     */

    public func calculateAbsorptionRate(elapsedTime: TimeInterval) -> Double {
        return calculateAbsorptionRate(elapsedTime: elapsedTime, fullReleaseTime: FULL_RELEASE_TIME)
    }

    /// Duration-aware variant of `calculateAbsorptionRate`.

    public func calculateAbsorptionRate(elapsedTime: TimeInterval, fullReleaseTime: TimeInterval) -> Double {
        let release = max(1, fullReleaseTime)
        return min(elapsedTime / release, Self.maxAbsorptionRate)
    }

    /**
     * calculateDecayedNicotine: Models nicotine decay after pouch removal
     * 
     * Uses exponential decay based on nicotine's 2-hour half-life:
     * - After 1 hour: ~70% remains
     * - After 2 hours: ~50% remains (half-life)
     * - After 4 hours: ~25% remains
     * - After 6 hours: ~12.5% remains
     * 
     * Formula: N_i(t) = D_i × A × 0.5^((t-t_i)/T_1/2)
     * Where:
     * - N_i(t) = remaining absorbed nicotine (mg) from pouch i at time t
     * - D_i = nicotine dose of pouch i (mg)
     * - A = absorption fraction (0.30 for 30%)
     * - t - t_i = elapsed time since pouch removal (in seconds)
     * - T_1/2 = nicotine half-life (120 minutes = 7200 seconds)
     * 
     * Note: This formula using pow(0.5, x) is mathematically identical to
     * the previous e^(-ln(2) * x) form, but matches the published scientific
     * model more directly for clarity and verification.
     * 
     * @param initialLevel: Starting nicotine level when pouch was removed (in mg)
     * @param timeSinceRemoval: Time elapsed since pouch removal (in seconds)
     * @return: Current nicotine level after decay (in mg)
     */

    public func calculateDecayedNicotine(initialLevel: Double, timeSinceRemoval: TimeInterval) -> Double {
        // Calculate decay factor using half-life formula: 0.5^(t / T_1/2)
        // This directly models the exponential decay where nicotine level
        // halves every 2 hours (7200 seconds)
        let decayFactor = pow(0.5, timeSinceRemoval / Self.nicotineHalfLife)
        
        // Apply decay to the initial level
        return initialLevel * decayFactor
    }
}

// MARK: - Core Data Extensions
extension PouchLog {
    /// Returns the duration the pouch was/is in mouth
    var duration: TimeInterval {
        guard let insertion = self.insertionTime else { return 0 }
        let end = self.removalTime ?? Date()
        return max(end.timeIntervalSince(insertion), 0)
    }

    /// Returns the nicotine content
    var nicotineContent: Double {
        return self.nicotineAmount
    }

    /// Calculates absorbed nicotine for this pouch
    func calculateAbsorbedAmount() -> Double {
        return AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: self.nicotineContent,
            useTime: self.duration
        )
    }

    /// Calculates current absorption rate (0.0 to 1.0)
    func calculateAbsorptionRate() -> Double {
        return AbsorptionConstants.shared.calculateAbsorptionRate(elapsedTime: self.duration)
    }
}
