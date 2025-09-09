# Live Activity Timing Fix

## Issue Identified
The Live Activity timer was using `Date()` (current time) instead of the pouch's actual `insertionTime` from Core Data, causing a mismatch between:
- The Live Activity countdown timer
- The in-app timer display
- The actual nicotine level calculations

This resulted in:
- Incorrect countdown timers in Live Activities
- Mismatched nicotine level calculations between app and Live Activity
- Incorrect timer display when pouches were synced from other devices

## Root Cause
`LiveActivityManager.startLiveActivity()` was using `Date()` for the start time instead of accepting and using the pouch's actual insertion time from Core Data.

## Files Modified

### 1. LiveActivityManager.swift
- Added `insertionTime: Date?` parameter to `startLiveActivity()`
- Modified to use provided insertion time or fall back to current time
- Updated `startForegroundMinuteTicker()` to accept and use the actual start time
- Ensured all timer calculations use the consistent start time

### 2. LogService.swift
- Updated to pass `pouch.insertionTime` when starting Live Activity
- Fixed widget end time calculation to use pouch's specific duration instead of FULL_RELEASE_TIME

### 3. CloudKitSyncManager.swift
- Updated to pass `pouch.insertionTime` when starting Live Activities for synced pouches

### 4. Persistence.swift
- Updated to pass `pouch.insertionTime` when starting Live Activities after CloudKit sync

## Key Changes

### Before:
```swift
// LiveActivityManager.swift
let start = Date()  // Always used current time
```

### After:
```swift
// LiveActivityManager.swift
let start = insertionTime ?? Date()  // Use actual insertion time if provided
```

### LogService Call Before:
```swift
await LiveActivityManager.startLiveActivity(
    for: pouchId, 
    nicotineAmount: mg,
    duration: duration
)
```

### LogService Call After:
```swift
await LiveActivityManager.startLiveActivity(
    for: pouchId, 
    nicotineAmount: mg,
    insertionTime: pouch.insertionTime,  // Pass actual insertion time
    duration: duration
)
```

## Impact
- Live Activity timers now accurately reflect the actual pouch insertion time
- Countdown timers remain synchronized across app restarts
- CloudKit-synced pouches display correct remaining time
- Nicotine level calculations are consistent between all app components

## Testing Recommendations
1. Log a new pouch and verify Live Activity shows correct countdown
2. Edit a pouch's insertion time and verify Live Activity updates correctly
3. Sync a pouch from another device and verify timer shows correct remaining time
4. Background the app and verify Live Activity continues with correct time
5. Check that nicotine levels match between:
   - Live Activity display
   - Main app timer
   - Usage graph view
   - Widget display
