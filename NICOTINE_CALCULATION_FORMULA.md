# Nicotine Calculation Formula Documentation

## Complete Mathematical Model

This document describes the complete nicotine calculation model used in nicnark-2 app.

---

## Overview

Blood **level** (Levels tab, widget, Live Activity, sleep prediction) uses a
**one-compartment model**: zero-order input of `A × D` over the pouch timer, plus
first-order elimination the whole time (`ke = ln(2) / 2h`).

Classic oral Bateman (`N = (F D ka)/(ka−ke) × (e^{−ke t} − e^{−ka t})`) is **not**
used. Pouch Tmax tracks use duration (~30–35 min for 30-min use, ~60–65 min for
60-min use). A fixed `ka` would pin Tmax independent of the timer.

Insights **"absorbed mg"** is still cumulative systemic *input*
`D × A × min(t / T, 1)` — how much entered, not remaining plasma.

The **total nicotine level** at any time is the **sum of plasma contributions from all pouches** (last 10 hours).

---

## Constants

| Symbol | Value | Description |
|--------|-------|-------------|
| **A** | 0.30 | Absorption fraction (30% of stated mg is deliverable) |
| **T₁/₂** | 7200 seconds (120 minutes) | Nicotine half-life in bloodstream |
| **ke** | ln(2) / T₁/₂ | First-order elimination rate |
| **T / FULL_RELEASE_TIME** | 1800, 2700, or 3600 s | Zero-order input window (30 / 45 / 60 min) |

---

## Plasma (blood level)

Input rate while delivering: `R = (D × A) / T` for `0 ≤ t < t_input`, else `0`.
`t_input = min(time in mouth, T)`.

During input:
```
N(t) = (R / ke) × (1 − e^{−ke t})
```

After input stops (timer elapsed **or** recorded removal, whichever first):
```
N(t) = N(t_input) × e^{−ke (t − t_input)}
```

At small t this matches the old linear ramp (`N ≈ R t`). At T it is **below** `D×A`
because some nicotine already cleared during use (~8% lower peak for a 30-min 6mg pouch).

Insights cumulative input (not plasma):
```
input(t) = D × A × min(t_in_mouth / T, 1.0)
```

---

## After input stops

Same `ke`. `t_input` is min(time in mouth, T) — timer end while still in, or recorded removal, whichever comes first. Holding an exhausted pouch does not hold plasma up.

Half-life checks (from the level at input-end, not from D×A):
- +2 h → 50% of N(t_input) remains
- +4 h → 25%
- +10 h → ~3.1% (lookback window)

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
- **N_i(t)** = plasma contribution from pouch i (`calculatePlasmaLevel`)

### Process:
1. Fetch all pouches from last 10 hours (≈5 half-lives)
2. For each pouch, apply the infusion + elimination closed form
3. Sum contributions

---

## Complete Examples

### Example 1: Single Active Pouch
**Scenario:** 6mg pouch inserted 15 minutes ago, still in mouth

**Calculation** (plasma, not cumulative input):
```
R = (6 × 0.30) / 1800
N = (R / ke) × (1 − e^{−ke × 900})  ≈ 0.86 mg
```
(Old linear-no-elimination value was 0.90 mg.)

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
  - `calculatePlasmaLevel()` — bloodstream level
  - `calculateAbsorbedNicotine()` — cumulative input (Insights)
  - `calculateDecayedNicotine()` — exp decay helper
- **Usage calculator:** `nicnark-2/NicotineCalculator.swift`
  - `calculatePouchContribution()` → `calculatePlasmaLevel`
  - `calculateTotalNicotineLevel()` — sums contributions
- **Widget calculator:** `AbsorptionTimerWidget/WidgetNicotineCalculator.swift`
  - Byte-matched plasma closed form

### Graph Display:
- **Nicotine Level View:** `nicnark-2/NicotineLevelView.swift`
  - Samples nicotine levels every 15 minutes for last 24 hours
  - Creates visual timeline using Charts framework
  - Color-codes segments (green=increasing, red=decreasing)

---

## Validation

The formula has been validated to ensure:
1. ✅ Plasma at timer end is below D×A (concurrent elimination)
2. ✅ Early t matches linear input (first-order Taylor)
3. ✅ After input ends, remaining follows 2 h half-life from N(t_input)
4. ✅ Insights absorbed mg still uses cumulative input, not plasma
5. ✅ Multiple pouches sum

See: `nicnark-2Tests/AbsorptionMathTests.swift`

---

## Literature Validation (reviewed June 2026)

The three core parameters were checked against the pharmacokinetics literature. All are
defensible for a personal harm-reduction tracker; **no numeric change was warranted by the
evidence.** Summary of the review:

| Parameter | Value | Verdict | Notes |
|-----------|-------|---------|-------|
| Half-life | 2 h (7200 s) | ✅ Keep | Canonical elimination half-life of nicotine (parent drug, not cotinine). Route-independent. Sits at the low/conservative edge of pouch-specific data (~2.1–2.8 h). |
| Absorption fraction | 0.30 | ✅ Keep | Slightly conservative average of (pouch extraction ~50–59% for tobacco-free) × (oromucosal bioavailability ~30–40%). Central reality for Zyn-style pouches is ~35–45%; 0.30 is a reasonable floor. |
| Linear ramp to 30% cap | over 30/45/60 min | ✅ Keep | Peak-at-removal timing matches clinical Tmax. Curve shape is the only real simplification (true uptake is concave/front-loaded). |

### Known simplifications (acceptable, documented)
1. **Curve shape** — real in-mouth uptake is concave/front-loaded (fastest in the first
   ~5–15 min), not a straight line. The linear ramp understates the early rate and
   overstates late-phase gain.
2. **Absorption fraction is an average, not exact** — true systemic absorption varies with
   product chemistry (tobacco-free pouch vs snus), use duration, swallowing, and individual
   CYP2A6 metabolizer status. The app applies a single 0.30 to all product types, even
   though tobacco snus extracts far less (~19–33% of label) than tobacco-free pouches.
3. **Half-life is a single conservative value** — the ~1–4 h inter-individual range and the
   small ~4–5 h terminal tail are not modeled; negligible over a same-day ~10–12 h horizon.
4. **"Flat after the window"** assumes the pouch is removed at the end of the selected
   duration. If held much longer, real plasma nicotine keeps rising, so the model
   under-counts absorption in that edge case.
5. **Units** — the model tracks an internal "amount absorbed" proxy in mg, not measured
   plasma concentration (ng/mL). It is a relative trend indicator, not a clinical measurement.

## References

- Benowitz NL, Hukkanen J, Jacob P 3rd. *Pharmacology of Nicotine: Addiction,
  Smoking-Induced Disease, and Therapeutics.* Annu Rev Pharmacol Toxicol 2009;49:57–71.
  (PMC2946180) — ~2 h elimination half-life; route-independent clearance via CYP2A6.
- Lunell E, Fagerström K, et al. *Pharmacokinetic Comparison of a Non-tobacco-Based
  Nicotine Pouch (ZYN) With Conventional Swedish Snus and American Moist Snuff.* Nicotine
  Tob Res 2020;22(10):1757–1763. doi:10.1093/ntr/ntaa068 — pouch extraction 50–59% of label
  (tobacco-free) vs 19–33% (snus).
- UK Committee on Toxicity (COT). *Statement on the bioavailability of nicotine from oral
  nicotine pouches.* cot.food.gov.uk — ~30–40% oromucosal bioavailability; ~70% first-pass
  loss of swallowed nicotine.
- *A Randomised Study of Oral Nicotine Pouch Pharmacokinetics.* Eur J Drug Metab
  Pharmacokinet (PMC8917032) — pouch half-life ~2.15–2.82 h; Tmax ~60 min for 60-min use.
- Population PK (PMC8016787) — terminal tail ~4–5 h; average ~2 h with substantial
  inter-individual variability.
