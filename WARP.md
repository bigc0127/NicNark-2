# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

**nicnark-2** is an iOS/macOS SwiftUI application for tracking nicotine pouch usage. The app features real-time absorption tracking, Live Activities, background processing, CloudKit sync, Shortcuts integration, and WidgetKit extensions.

## Development Commands

### Building & Running
```bash
# Open project in Xcode (required for building)
open nicnark-2.xcodeproj

# Build for simulator (if Xcode CLI tools are available)
xcodebuild -project nicnark-2.xcodeproj -scheme nicnark-2 -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build for device (requires code signing)
xcodebuild -project nicnark-2.xcodeproj -scheme nicnark-2 -destination generic/platform=iOS build
```

### Testing
```bash
# Run unit tests
xcodebuild test -project nicnark-2.xcodeproj -scheme nicnark-2 -destination 'platform=iOS Simulator,name=iPhone 15'

# Run UI tests  
xcodebuild test -project nicnark-2.xcodeproj -scheme nicnark-2 -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:nicnark-2UITests
```

### Code Analysis
```bash
# Find Swift files
find . -name "*.swift" -type f

# Search for specific functionality
grep -r "LogService" --include="*.swift" .
grep -r "LiveActivity" --include="*.swift" .
```

## Architecture Overview

### Core Data Stack
- **PersistenceController**: CloudKit-enabled Core Data stack with automatic sync
- **Main Entities**: `PouchLog` (usage entries), `CustomButton` (user-defined dosages)
- **Cloud Integration**: iCloud sync via `NSPersistentCloudKitContainer`
- **Model File**: `nicnark_2.xcdatamodeld`

### App Structure
- **Main App**: `nicnark_2App.swift` - App entry point with URL scheme handling
- **Content View**: `ContentView.swift` - Tab-based navigation (Log, Levels, Usage)
- **Core Views**: `LogView.swift`, `NicotineLevelView.swift`, `UsageGraphView.swift`

### Centralized Services
- **LogService**: Unified pouch logging for UI, Shortcuts, and URL schemes
- **NotificationManager**: Local notifications and badge management
- **LiveActivityManager**: iOS 16.1+ Live Activities for real-time tracking
- **BackgroundMaintainer**: Background task processing for data updates

### Extensions & Targets
- **AbsorptionTimerWidget**: WidgetKit extension for home screen widgets
- **App Intents**: Implemented directly in the main app target (no separate Shortcuts extension)
- **URL Scheme**: `nicnark2://log?mg=X` for external app integration

### Key Constants
- `FULL_RELEASE_TIME`: 30 minutes (complete absorption time)
- `ABSORPTION_FRACTION`: 30% (max nicotine absorption rate)
- Nicotine half-life: 2 hours for decay calculations

## Important Implementation Details

### Data Flow
1. **Logging**: All entry points (UI, Shortcuts, URLs) use `LogService.logPouch()`
2. **Live Activities**: Started automatically on pouch creation, updated via background tasks
3. **Notifications**: Scheduled for absorption completion (30 min timer)
4. **Widgets**: Reload triggered after any data changes via `WidgetCenter.shared.reloadAllTimelines()`

### Background Processing
- **Identifiers**: `com.nicnark.nicnark-2.bg.refresh`, `com.nicnark.nicnark-2.bg.process`
- **Purpose**: Keep Live Activities fresh and sync CloudKit data
- **Implementation**: iOS 16.1+ background task scheduling

### Custom URL Scheme
- **Format**: `nicnark2://log?mg=<amount>`
- **Handler**: `LogPouchRouter.handle()` parses and validates URLs
- **Integration**: Both app-level and view-level URL handling

### Multi-Target Dependencies
- **Shared Logic**: `LogService`, `PersistenceController` used across main app and extensions
- **Widget Communication**: Core Data sharing via App Groups
- **Intent Execution**: App Intents run inside the main app target and write directly via Core Data

## Development Notes

### CloudKit Considerations
- Container ID: `iCloud.ConnorNeedling.nicnark-2`
- Automatic history tracking and remote change notifications enabled
- Merge policy: `NSMergeByPropertyObjectTrumpMergePolicy`

### iOS Version Requirements
- **Live Activities**: iOS 16.1+ (`@available` checks throughout)
- **Background Tasks**: iOS 13+ BGTaskScheduler
- **App Intents**: iOS 16+ for Shortcuts integration

### Testing Approach
- **Preview Data**: `PersistenceController.preview` with sample data
- **In-Memory Store**: Used for unit tests and previews
- **Core Data Validation**: Error handling with debug crashes in DEBUG builds

### Widget & Extension Architecture
- **Widget Bundle**: Single Live Activity widget type
- **Data Sharing**: Core Data model shared via App Groups
- **Update Strategy**: Timeline reload after every data mutation
