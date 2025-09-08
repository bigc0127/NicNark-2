# iOS Compatibility Guide

## Deployment Target: iOS 18.4+

The app now supports iOS 18.4 and later, with enhanced features for newer iOS versions.

## Feature Availability by iOS Version

### Core Features (iOS 18.4+)
✅ All core functionality works on iOS 18.4 and later:
- Pouch logging and tracking
- Timer functionality (30/45/60 minute options)
- Can inventory system
- Barcode scanning
- CloudKit sync
- Background processing
- Local notifications
- Widgets
- Siri Shortcuts
- CSV export

### Enhanced Features (iOS 16.1+)
These features require iOS 16.1 or later (already available on iOS 18.4):
- **Live Activities**: Real-time pouch timer in Dynamic Island and Lock Screen
- **ActivityKit**: Interactive widgets with live updates

### Optimal Experience (iOS 26+)
When running on iOS 26 (latest beta), users get:
- Latest SwiftUI performance optimizations
- Enhanced system integration
- Improved animations and transitions
- Better memory management
- Latest security features

## Compatibility Notes

1. **Backward Compatibility**: All features work on iOS 18.4+
2. **Forward Compatibility**: App automatically uses newer iOS features when available
3. **Testing**: Test on both iOS 18.4 (minimum) and iOS 26 (latest) devices
4. **App Store**: Can be submitted with iOS 18.4 minimum requirement

## Build Requirements

- Xcode 16.0 or later (beta for iOS 26 support)
- macOS 15.0 or later
- Swift 5.9+

## Testing Checklist

- [ ] Test on iOS 18.4 device/simulator
- [ ] Test on iOS 26 device/simulator
- [ ] Verify Live Activities work (iOS 16.1+)
- [ ] Verify CloudKit sync works
- [ ] Verify widgets update properly
- [ ] Test Siri Shortcuts
- [ ] Test background processing
