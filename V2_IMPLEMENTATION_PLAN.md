# NicNark v2.0 Implementation Plan

## Version 2.0 Features

### ✅ Completed
1. **Version Bump to 2.0**
   - Updated project version to 2.0
   - Created TimerSettings.swift for configurable timer

### 🚧 In Progress Features

#### 1. Configurable Timer Duration
**Status**: Partially implemented
- [x] Created TimerSettings class with 30/45/60 minute options
- [x] Updated FULL_RELEASE_TIME to use configurable value
- [ ] Add timer duration picker to SettingsView
- [ ] Update all timer logic to use new duration
- [ ] Test with Live Activities

#### 2. CSV Export for All Logs
**Status**: Not started
- [ ] Create ExportManager class
- [ ] Fetch all PouchLog entries (not just 24hr)
- [ ] Format as CSV with proper columns
- [ ] Add export button to Settings
- [ ] Implement UIDocumentPickerViewController

#### 3. Can Inventory Tracking
**Status**: Not started
- [ ] Create Core Data model for Can entity
- [ ] Add barcode, brand, flavor, strength properties
- [ ] Create relationship between PouchLog and Can
- [ ] Build Can inventory UI
- [ ] Replace quick buttons with can cards
- [ ] Implement barcode scanning
- [ ] Handle Siri Shortcuts with can prompts

## Implementation Order

### Phase 1: Timer Configuration (Quick Win)
1. Update SettingsView to include timer picker
2. Test timer changes with existing pouches
3. Verify Live Activities work with new durations

### Phase 2: CSV Export (User Value)
1. Create export functionality
2. Add to Settings
3. Test with various data sizes

### Phase 3: Can Inventory (Major Feature)
1. Update Core Data model
2. Create Can management UI
3. Implement barcode scanning
4. Update LogView interface
5. Handle Siri Shortcuts integration

## Technical Considerations

### Core Data Migration
- Need to add Can entity
- Add optional can relationship to PouchLog
- Create lightweight migration

### Camera Permissions
- Add NSCameraUsageDescription to Info.plist
- Handle permission requests gracefully

### Backwards Compatibility
- Ensure existing shortcuts still work
- Handle logs without can association
- Provide "Ignore Can" option

## Testing Checklist
- [ ] Timer changes persist across app launches
- [ ] CSV export includes all historical data
- [ ] Barcode scanning works reliably
- [ ] Can inventory updates correctly
- [ ] Siri Shortcuts handle can prompts
- [ ] Live Activities work with all timer durations

## Files to Create/Modify

### New Files
- CanInventoryManager.swift
- CanDetailView.swift
- BarcodeScanner.swift
- ExportManager.swift

### Modified Files
- SettingsView.swift (add timer picker, export)
- LogView.swift (replace buttons with cans)
- Core Data model (add Can entity)
- Info.plist (camera permission)
- LogService.swift (handle can association)
