# Nicotine Calculation Formula Documentation

## Complete Mathematical Model

This document describes the complete nicotine calculation model used in nicnark-2 app.

---

## Overview

The app uses a **two-phase model** to calculate nicotine levels in the bloodstream:
1. **Absorption Phase** - Linear absorption while pouch is in mouth
2. **Decay Phase** - Exponential decay after pouch removal

The **total nicotine level** at any time is the **sum of contributions from all pouches** (active and removed).

---

## Constants

| Symbol | Value | Description |
|--------|-------|-------------|
| **A** | 0.30 | Absorption fraction (30%) |
| **T₁/₂** | 7200 seconds (120 minutes) | Nicotine half-life in bloodstream |
| **FULL_RELEASE_TIME** | 1800, 2700, or 3600 seconds | Duration for complete absorption (30, 45, or 60 minutes, user-configurable) |

---

## Phase 1: Absorption (While Pouch is in Mouth)

**Applies when:** `t_insertion ≤ t_current ≤ t_removal`

### Formula:
```
N_absorbed(t) = D × A × min(t_elapsed / FULL_RELEASE_TIME, 1.0)
```

### Where:
- **N_absorbed(t)** = Amount of nicotine absorbed at time t (mg)
- **D** = Nicotine dose/content of pouch (mg) - e.g., 6mg, 10mg
- **A** = Absorption fraction = 0.30 (30% of total nicotine is absorbed)
- **t_elapsed** = Time pouch has been in mouth = t_current - t_insertion (seconds)
- **FULL_RELEASE_TIME** = Time for complete absorption (seconds)

### Characteristics:
- **Linear absorption** from 0% to 30% over FULL_RELEASE_TIME
- At t=0: N_absorbed = 0 mg (no absorption yet)
- At t=FULL_RELEASE_TIME: N_absorbed = D × 0.30 (maximum absorption reached)
- After FULL_RELEASE_TIME: Absorption remains constant at D × 0.30

### Example:
For a 6mg pouch after 15 minutes (with 30-minute FULL_RELEASE_TIME):
```
N_absorbed(15 min) = 6 × 0.30 × (900/1800)
                   = 6 × 0.30 × 0.5
                   = 0.9 mg
```

---

## Phase 2: Decay (After Pouch Removal)

**Applies when:** `t_current > t_removal`

### Formula:
```
N_i(t) = N_max × 0.5^((t - t_removal) / T₁/₂)
```

### Where:
- **N_i(t)** = Remaining nicotine from pouch i at time t (mg)
- **N_max** = Maximum absorbed nicotine = D × A × min(t_in_mouth / FULL_RELEASE_TIME, 1.0)
- **t - t_removal** = Time elapsed since pouch removal (seconds)
- **T₁/₂** = Nicotine half-life = 7200 seconds (120 minutes)
- **0.5^x** = Exponential decay using half-life

### Characteristics:
- **Exponential decay** based on 2-hour half-life
- After 1 hour (3600s): ~70.7% remains
- After 2 hours (7200s): ~50% remains (one half-life)
- After 4 hours: ~25% remains
- After 6 hours: ~12.5% remains
- After 10 hours: ~3.1% remains (negligible)

### Mathematical Equivalence:
This formula is mathematically equivalent to:
```
N_i(t) = N_max × e^(-ln(2) × (t - t_removal) / T₁/₂)
```
Because: `0.5^x = e^(-ln(2) × x)`

### Example:
For a pouch that absorbed 1.8mg (6mg × 0.30) and was removed 1 hour ago:
```
N_i(t) = 1.8 × 0.5^(3600 / 7200)
       = 1.8 × 0.5^0.5
       = 1.8 × 0.7071
       ≈ 1.27 mg
```

---

## Total Nicotine Level Calculation

### Formula:
```
N_total(t) = Σ N_i(t)
             i=1 to n
```

### Where:
- **N_total(t)** = Total nicotine in bloodstream at time t
- **n** = Number of pouches used in last 10 hours
- **N_i(t)** = Contribution from pouch i, calculated using:
  - Absorption formula if pouch is still in mouth
  - Decay formula if pouch has been removed

### Process:
1. Fetch all pouches from last 10 hours (≈5 half-lives, covers 96.9% of decay)
2. For each pouch i:
   - If pouch is still active (not removed): Calculate using **Absorption Phase** formula
   - If pouch was removed: Calculate using **Decay Phase** formula
3. Sum all individual contributions to get total level

---

## Complete Examples

### Example 1: Single Active Pouch
**Scenario:** 6mg pouch inserted 15 minutes ago, still in mouth

**Calculation:**
```
N_total = 6 × 0.30 × (15×60 / 30×60)
        = 6 × 0.30 × 0.5
        = 0.9 mg
```

---

### Example 2: Single Removed Pouch
**Scenario:** 4mg pouch was in mouth for 30 minutes, removed 1 hour ago

**Step 1:** Calculate maximum absorbed
```
N_max = 4 × 0.30 × min(30/30, 1.0)
      = 4 × 0.30 × 1.0
      = 1.2 mg
```

**Step 2:** Apply decay for 1 hour
```
N_total = 1.2 × 0.5^(3600 / 7200)
        = 1.2 × 0.5^0.5
        = 1.2 × 0.7071
        ≈ 0.85 mg
```

---

### Example 3: Multiple Pouches (Mixed)
**Scenario:**
- Pouch A: 6mg, inserted 10 minutes ago (active)
- Pouch B: 4mg, was in for 30 min, removed 30 minutes ago
- Pouch C: 8mg, inserted 5 minutes ago (active)

**Pouch A (absorption):**
```
N_A = 6 × 0.30 × (10/30)
    = 6 × 0.30 × 0.333
    = 0.6 mg
```

**Pouch B (decay):**
```
N_max_B = 4 × 0.30 = 1.2 mg
N_B = 1.2 × 0.5^(1800 / 7200)
    = 1.2 × 0.5^0.25
    = 1.2 × 0.841
    ≈ 1.01 mg
```

**Pouch C (absorption):**
```
N_C = 8 × 0.30 × (5/30)
    = 8 × 0.30 × 0.167
    = 0.4 mg
```

**Total:**
```
N_total = N_A + N_B + N_C
        = 0.6 + 1.01 + 0.4
        ≈ 2.01 mg
```

---

## Edge Cases

### Case 1: Pouch Just Inserted (t = 0)
```
N_absorbed = D × 0.30 × (0 / FULL_RELEASE_TIME) = 0 mg
```

### Case 2: Pouch at Exactly FULL_RELEASE_TIME
```
N_absorbed = D × 0.30 × (FULL_RELEASE_TIME / FULL_RELEASE_TIME)
           = D × 0.30 × 1.0
           = D × 0.30 mg (maximum absorption)
```

### Case 3: Pouch Removed Early (e.g., after 10 minutes of 30-minute duration)
```
N_max = D × 0.30 × (10/30) = D × 0.10 mg (only 10% absorbed)
Then decay starts from this lower level
```

### Case 4: Very Old Pouch (>10 hours ago)
```
Filtered out by lookback window (not included in calculation)
```

---

## Implementation Notes

### Code Location:
- **Main calculator:** `nicnark-2/AbsorptionConstants.swift`
  - `calculateAbsorbedNicotine()` - Absorption phase
  - `calculateDecayedNicotine()` - Decay phase
- **Usage calculator:** `nicnark-2/NicotineCalculator.swift`
  - `calculatePouchContribution()` - Determines which phase applies
  - `calculateTotalNicotineLevel()` - Sums all contributions
- **Widget calculator:** `nicnark-2/WidgetSupport/WidgetNicotineCalculator.swift`
  - Mirror of main calculator for widget use

### Graph Display:
- **Nicotine Level View:** `nicnark-2/NicotineLevelView.swift`
  - Samples nicotine levels every 15 minutes for last 24 hours
  - Creates visual timeline using Charts framework
  - Color-codes segments (green=increasing, red=decreasing)

---

## Validation

The formula has been validated to ensure:
1. ✅ Main app and widget calculators produce identical results
2. ✅ Absorption is linear and reaches exactly 30% at FULL_RELEASE_TIME
3. ✅ Decay follows exponential half-life (50% every 2 hours)
4. ✅ Multiple pouches sum correctly
5. ✅ Edge cases (t=0, full absorption) handled properly

See: `nicnark-2Tests/NicotineLevelParityTests.swift` for comprehensive unit tests.

---

## References

This model is based on scientific research on nicotine absorption from oral pouches:
- Absorption fraction: ~25-30% of stated nicotine content
- Half-life: ~2 hours (120 minutes) in most adults
- Absorption pattern: Linear increase during usage period
- Decay pattern: First-order exponential decay after removal
