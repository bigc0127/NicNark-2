# Live Activity Single-Activity Policy Fix

## Issue Description
When loading multiple pouches (e.g., 12mg + 6mg), the app was creating **multiple Live Activities** instead of just one. This resulted in:
- "2" being displayed on the lock screen instead of "1"
- Visual clutter with duplicate timers
- Potential iOS throttling due to multiple activities

## Root Cause
The CloudKit sync manager (`CloudKitSyncManager.syncLiveActivitiesAcrossDevices()`) was looping through all active pouches and creating a separate Live Activity for each one that didn't have an activity. This happened even when the local code in `LogView.startTimerWithLoadedPouches()` correctly created only one activity.

### Flow:
1. User loads 2 pouches (12mg + 6mg)
2. `LogView.startTimerWithLoadedPouches()` creates **ONE** Live Activity with:
   - Total nicotine: 18mg (12 + 6)
   - Timer: Longest duration
3. CloudKit sync triggers immediately after save
4. `CloudKitSyncManager.syncLiveActivitiesAcrossDevices()` sees 2 active pouches
5. OLD BEHAVIOR: Creates a Live Activity for each pouch → **2 activities total** ❌
6. NEW BEHAVIOR: Sees activity already exists → **1 activity total** ✅

## Solution

### 1. Strengthened `LiveActivityManager.startLiveActivity()` (Lines 217-223)
Added extra safety guard for sync operations:

```swift
} else {
    // CRITICAL: If this is from sync and ANY activity already exists, do not create another one
    // We enforce a strict one-activity-at-a-time policy across all pouches
    if !Activity<PouchActivityAttributes>.activities.isEmpty {
        log.info("Sync attempted to create activity but one already exists - blocking to maintain single-activity policy")
        return false
    }
}
```

**Why this matters:** Even if CloudKit sync tries to create an activity, this guard ensures that if ANY activity already exists, we block creation. This prevents the "second activity sneaking through" bug.

### 2. Refactored `CloudKitSyncManager.syncLiveActivitiesAcrossDevices()` (Lines 162-271)

#### Old Logic (Bug):
```swift
// Loop through ALL active pouches
for pouch in activePouches {
    if !LiveActivityManager.activityExists(for: pouchId) {
        // Create activity for THIS pouch
        await LiveActivityManager.startLiveActivity(...)
    }
}
// Result: Multiple activities (one per pouch) ❌
```

#### New Logic (Fixed):
```swift
// STEP 1: Clean up ended activities
for activity in currentActivities { ... }

// STEP 2: Check if ANY activity exists after cleanup
if !remainingActivities.isEmpty {
    return  // Already have one - don't create more ✅
}

// STEP 3: Find pouch with longest remaining time
// STEP 4: Sum ALL nicotine amounts
for pouch in activePouches {
    totalNicotine += pouch.nicotineAmount
    if remaining > longestRemainingTime {
        longestPouch = pouch
    }
}

// STEP 5: Create ONE activity with aggregated data
await LiveActivityManager.startLiveActivity(
    for: longestPouchId,
    nicotineAmount: totalNicotine,  // Total: 18mg
    duration: longestDuration        // Longest timer
)
// Result: ONE activity representing all pouches ✅
```

## Single-Activity Policy

### Why One Activity?
1. **iOS Limitations**: iOS throttles Live Activities per app
2. **User Experience**: Multiple activities create visual clutter
3. **Aggregated Data**: Users want to see total info at a glance

### Selection Criteria
When multiple pouches are active, ONE Live Activity shows:
- **Timer**: Pouch with the **LONGEST** remaining duration
- **Nicotine**: **SUM** of all active pouches' nicotine amounts
- **Progress**: Based on longest timer's progress

### Example
```
Active Pouches:
- Pouch 1: 12mg, 30 min (inserted 10 min ago → 20 min remaining)
- Pouch 2: 6mg, 20 min (inserted 5 min ago → 15 min remaining)

Live Activity Shows:
- "18mg Pouch" (12 + 6)
- Timer: 20:00 (longest remaining)
- Progress bar: Based on Pouch 1's 30-min duration
```

## Files Modified

### 1. `LiveActivityManager.swift`
- **Lines 217-223**: Added sync safety guard
- Prevents any activity creation if one already exists during sync

### 2. `CloudKitSyncManager.swift`
- **Lines 162-271**: Complete refactor of `syncLiveActivitiesAcrossDevices()`
- Added comprehensive documentation block
- Implements single-activity selection logic
- Calculates total nicotine across all pouches
- Selects representative pouch (longest timer)

## Testing Recommendations

### Unit Tests (TODO)
- Create `LiveActivityDuplicationTests.swift`:
  - Test: Two sync calls with `isFromSync: true` → only one activity created
  - Test: Sync with existing activity → no new activity created
  - Test: Multiple pouches → single activity with correct total nicotine

### Manual Testing
1. ✅ Load 2 pouches (12mg + 6mg) → verify ONE Live Activity shows 18mg
2. ✅ Check lock screen → should show "1" not "2"
3. ✅ Verify timer matches longest duration
4. ✅ Kill app and relaunch (triggers sync) → still one activity
5. ✅ Remove one pouch → activity updates with remaining pouch
6. ✅ Add another pouch while one active → ends old, creates new single activity

## Expected Behavior After Fix

### Scenario 1: Local Multi-Pouch Loading
```
User loads 12mg + 6mg → ONE Live Activity created locally
CloudKit sync triggers → sees activity exists → does nothing
Result: ONE Live Activity ✅
```

### Scenario 2: Cross-Device Sync
```
Device A: User loads 2 pouches → ONE Live Activity
CloudKit syncs to Device B
Device B: Sees 2 active pouches in Core Data
CloudKit sync runs → calculates longest + total → creates ONE Live Activity
Result: ONE Live Activity on both devices ✅
```

### Scenario 3: Adding Pouch to Active Session
```
Current: ONE pouch active (6mg, 15 min remaining)
User adds: 12mg pouch (30 min duration)
Result: 
  - Old activity ended
  - NEW activity created: 18mg total, 30 min timer ✅
```

## Impact
- ✅ Lock screen shows "1" Live Activity instead of "2"
- ✅ No visual clutter from duplicate activities
- ✅ Total nicotine displayed correctly (already working)
- ✅ Progress bar based on all pouches (already working)
- ✅ Timer shows longest duration (already working)
- ✅ CloudKit sync respects single-activity policy
- ✅ Cross-device consistency maintained

## Related Files
- `LiveActivityManager.swift` - Core Live Activity management
- `CloudKitSyncManager.swift` - Cross-device sync logic
- `LogView.swift` - Multi-pouch loading UI
- `LogService.swift` - Single pouch logging (unchanged)
- `LIVE_ACTIVITY_TIMING_FIX.md` - Previous timing fix documentation
