# Live Activities Bug Fixes

## Issues Identified

### 1. Duplicate Live Activities
- When a pouch timer completed, a new Live Activity would be created for the removed pouch
- Multiple Live Activities could be created for the same pouch
- Race conditions between foreground timers, background tasks, and CloudKit sync

### 2. Live Activity Creation After Removal
- When removing a pouch, the background maintainer could see it as "inactive" and try to create a new activity
- Race condition between marking pouch as removed in Core Data and ending the Live Activity

## Root Causes

1. **No authoritative check**: Code wasn't consistently checking Core Data to verify if a pouch was still active before creating activities
2. **Race conditions**: Multiple code paths (foreground timer, background tasks, CloudKit sync) could create/end activities simultaneously
3. **Tracking dictionary issues**: The `activeActivitiesByPouchId` dictionary wasn't being properly cleaned up when activities ended
4. **Order of operations**: Pouch was marked as removed in Core Data before the Live Activity was ended

## Fixes Implemented

### 1. Added Core Data Guards (`LiveActivityManager.swift`)
- `isPouchActive(_ pouchId: String)`: Authoritative check against Core Data to verify pouch hasn't been removed
- `activityExists(for pouchId: String)`: Check both tracking dictionary and actual activities to prevent duplicates

### 2. Fixed Activity Creation (`LiveActivityManager.startLiveActivity`)
- Added check for `isPouchActive` before creating any activity
- Use `activityExists` helper to prevent duplicates
- Properly sync tracking dictionary with actual activities
- Added detailed logging to trace activity lifecycle

### 3. Fixed Activity Cleanup (`LiveActivityManager.endLiveActivity`)
- Remove from tracking dictionary FIRST to prevent race conditions
- Added logging to detect tracking mismatches
- Improved `endAllLiveActivities` to clear tracking and log state

### 4. Fixed Pouch Removal (`LogView.removePouch`)
- **Critical change**: End Live Activity BEFORE marking pouch as removed in Core Data
- Stop all timers immediately after ending activity
- Wrap operations in `Task { @MainActor }` for deterministic ordering

### 5. Hardened Background Updates (`BackgroundMaintainer.applyBatchedActivityUpdates`)
- Check `isPouchActive` before updating any activity
- End activities for removed pouches
- Added detailed decision matrix logging
- Prevent creation of activities for inactive pouches

### 6. Fixed CloudKit Sync (`CloudKitSyncManager` & `Persistence.swift`)
- Use `activityExists` helper instead of manual checks
- Double-check `isPouchActive` before creating synced activities
- Pass `isFromSync: true` to prevent ending other activities during sync
- Use Core Data guard for cleanup decisions

## Key Principles Applied

1. **Single Source of Truth**: Core Data is the authoritative source for whether a pouch is active
2. **Fail-Fast**: Check early and often if operations should proceed
3. **Atomic Operations**: Clean up tracking state before async operations
4. **Defensive Programming**: Multiple guards to prevent duplicate creation
5. **Comprehensive Logging**: Track activity lifecycle for debugging

## Testing Recommendations

1. **Normal timer completion**: Start a pouch, wait 30 minutes, verify only one activity that ends properly
2. **Manual removal**: Remove pouch before/after timer completes, verify no duplicate activities
3. **Background scenarios**: Put app in background during timer, verify proper updates
4. **CloudKit sync**: Test with multiple devices, verify activities sync correctly
5. **Edge cases**: Rapid create/remove cycles, app termination during activity

## Expected Behavior After Fixes

- Only ONE Live Activity per active pouch
- When pouch is removed (manually or timer completion), activity ends immediately
- No new activities created for removed pouches
- Background tasks properly update existing activities without creating duplicates
- CloudKit sync respects local device state and doesn't create duplicate activities

## Monitoring

Enable verbose logging by watching for these log prefixes in Console:
- 🎆 Activity creation
- 📱 Activity updates  
- 🛑 Activity ending
- 📊 Background decision matrix
- 🚫 Skipped operations
- ✅ Successful operations
- ⚠️ Warnings/issues
