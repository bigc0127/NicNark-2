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
    if #available(iOS 14.0, *) {
        return TimerSettings.shared.currentTimerInterval
    } else {
        return 30 * 60 // Fallback to 30 minutes
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
public struct AbsorptionConstants {
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
     * This uses a linear absorption model:
     * - Absorption increases steadily over 30 minutes
     * - Maximum 30% of the pouch content gets absorbed
     * - Example: 6mg pouch after 15 minutes = 6 * 0.30 * (15/30) = 0.9mg absorbed
     * 
     * @param nicotineContent: Total nicotine in the pouch (e.g., 6mg)
     * @param useTime: How long the pouch has been in mouth (in seconds)
     * @return: Amount of nicotine absorbed into bloodstream (in mg)
     */
    @Sendable
    public func calculateAbsorbedNicotine(nicotineContent: Double, useTime: TimeInterval) -> Double {
        // Calculate what fraction of the 30-minute period has elapsed
        let fractionalTime = useTime / FULL_RELEASE_TIME
        
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
    @Sendable
    public func calculateCurrentNicotineLevel(nicotineContent: Double, elapsedTime: TimeInterval) -> Double {
        return calculateAbsorbedNicotine(nicotineContent: nicotineContent, useTime: elapsedTime)
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
    @Sendable
    public func calculateAbsorptionRate(elapsedTime: TimeInterval) -> Double {
        // Divide elapsed time by total time, cap at 100%
        return min(elapsedTime / FULL_RELEASE_TIME, Self.maxAbsorptionRate)
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
     * Formula: level = initial * e^(-ln(2) * time / half_life)
     * 
     * @param initialLevel: Starting nicotine level when pouch was removed (in mg)
     * @param timeSinceRemoval: Time elapsed since pouch removal (in seconds)
     * @return: Current nicotine level after decay (in mg)
     */
    @Sendable
    public func calculateDecayedNicotine(initialLevel: Double, timeSinceRemoval: TimeInterval) -> Double {
        // Calculate decay factor using exponential decay formula
        // e^(-ln(2) * t / half_life) = mathematical model for half-life decay
        let decayFactor = exp(-log(2.0) * timeSinceRemoval / Self.nicotineHalfLife)
        
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
