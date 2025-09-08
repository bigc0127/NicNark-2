# NicNark 🚭

[![iOS](https://img.shields.io/badge/iOS-17.0+-blue.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/License-CC%20BY--NC%204.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc/4.0/)

A privacy-first iOS app for tracking personal nicotine consumption patterns. Built with SwiftUI, Core Data, and designed with zero data collection.

## ⚠️ Important Disclaimer

**This app is for personal tracking purposes only and does not provide medical advice.** It is not intended to promote, endorse, or encourage nicotine use. Nicotine is addictive and harmful to health. Please consult healthcare professionals for medical guidance regarding nicotine use or cessation.

## ✨ Features

- **🔒 Complete Privacy**: Zero data collection - all data stays on your device
- **📊 Usage Tracking**: Log nicotine consumption with customizable amounts
- **⏱️ Live Activities**: Real-time absorption tracking on Lock Screen and Dynamic Island
- **📈 Interactive Charts**: Visualize nicotine levels and usage patterns over time
- **🏠 Home Screen Widgets**: Quick access and status overview
- **🗣️ Siri Shortcuts**: Voice-activated logging with iOS Shortcuts integration
- **☁️ iCloud Sync**: Optional sync between your devices (your personal iCloud only)
- **🌙 Dark Mode**: Full support for iOS dark mode
- **📱 iPad Compatible**: Optimized for iPad with iPhone-style interface

## 📱 Screenshots

*Screenshots will be added once the app is live on the App Store*

## 🛠️ Technical Details

### Built With
- **SwiftUI** - Modern iOS UI framework
- **Core Data** - Local data persistence with CloudKit sync
- **WidgetKit** - Home screen widgets and Live Activities
- **Charts** - SwiftUI Charts for data visualization
- **Shortcuts** - Siri and iOS Shortcuts integration
- **TipKit** - In-app guidance system

### Architecture
- **MVVM Pattern** - Clean separation of concerns
- **Core Data + CloudKit** - Reliable local storage with optional sync
- **No Third-Party Dependencies** - Pure iOS frameworks only
- **Privacy by Design** - No analytics, tracking, or data collection

### Requirements
- iOS 17.0+ (iOS 18.0+ recommended)
- Xcode 15.0+
- Swift 5.9+

## 🚀 Getting Started

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/ConnorNeedling/nicnark.git
   cd nicnark
   ```

2. **Open in Xcode**
   ```bash
   open nicnark-2.xcodeproj
   ```

3. **Configure App Group** (Required for widgets)
   - Update the App Group identifier in all targets
   - Format: `group.YourTeamID.nicnark-2`
   - Update in `WidgetPersistenceHelper.swift`

4. **Update Bundle Identifiers**
   - Main app: `YourTeamID.nicnark-2`
   - Widget: `YourTeamID.nicnark-2.AbsorptionTimerWidget`
-   Shortcuts: (none) — App Intents are built into the main app target (no separate extension)

5. **Build and Run**
   - Select your development team in Xcode
   - Choose your target device
   - Build and run (⌘+R)

### Development Setup

1. **Enable Core Data CloudKit Sync** (Optional)
   - Configure CloudKit container in Apple Developer Portal
   - Enable CloudKit in app capabilities

2. **Configure Live Activities** (iOS 16.1+)
   - Activities are automatically configured
   - Test on physical device (Live Activities don't work in Simulator)

3. **Test Widgets**
   - Long-press home screen → Add Widget → NicNark
   - Test timeline updates and data display

## 📖 Usage

### Basic Tracking
1. **Log a Pouch**: Tap preset buttons (3mg, 6mg) or create custom amounts
2. **Monitor Progress**: View real-time absorption countdown and progress
3. **Remove Pouch**: Tap "Remove Pouch" when finished
4. **View History**: Check the "Levels" and "Usage" tabs for historical data

### Advanced Features
- **Widgets**: Add to home screen for quick status overview
- **Live Activities**: Monitor active pouches on Lock Screen
- **Siri Shortcuts**: Create voice commands for logging
- **Data Export**: Use Settings → "Delete All Data" to clear everything

## 🔒 Privacy

NicNark is built with **privacy by design**:

- ✅ **Zero data collection** - We never see your data
- ✅ **Local storage only** - All data stays on your device
- ✅ **No analytics or tracking** - No third-party services
- ✅ **Optional iCloud sync** - Uses your personal Apple account
- ✅ **No account required** - No sign-up or personal information needed
- ✅ **Transparent code** - Full source code available for audit

[Read our Privacy Policy](https://connorneedling.github.io/NicNark-2/privacy-policy)

## 🤝 Contributing

We welcome contributions! This is a community-driven project.

### How to Contribute
1. **Fork the repository**
2. **Create a feature branch** (`git checkout -b feature/AmazingFeature`)
3. **Commit your changes** (`git commit -m 'Add AmazingFeature'`)
4. **Push to the branch** (`git push origin feature/AmazingFeature`)
5. **Open a Pull Request**

### Areas for Contribution
- 🌍 **Localization** - Translate to other languages
- 🎨 **UI/UX Improvements** - Better designs and user experience
- 📊 **Data Visualizations** - New chart types and insights
- 🔧 **Feature Additions** - New functionality (must maintain privacy-first approach)
- 🐛 **Bug Fixes** - Report and fix issues
- 📚 **Documentation** - Improve docs and guides

### Development Guidelines
- Maintain **privacy-first** principles - no data collection
- Follow **SwiftUI best practices**
- Write **clear, documented code**
- Test on **multiple iOS versions** and devices
- Ensure **iPad compatibility**

## 📝 License

This project is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International License**.

**This means you can:**
- ✅ Use the code for personal projects
- ✅ Modify and adapt the code
- ✅ Share the code with others
- ✅ Create derivative works

**But you cannot:**
- ❌ Use the code for commercial purposes
- ❌ Sell apps based on this code
- ❌ Remove attribution to original authors

[View License](LICENSE.md) | [Human-Readable Summary](https://creativecommons.org/licenses/by-nc/4.0/)

## 🆕 Recent Updates

### Version 2.0.1
- **🔔 Smart Inventory Alerts** - Low inventory alerts now respect a 24-hour cooldown per can to prevent repetitive notifications
- **🧪 Enhanced Testing** - Added comprehensive unit tests for notification cooldown functionality
- **🔧 Improved Reliability** - Better notification management and cleanup of stale alert records

## 🎯 Roadmap

### Planned Features
- [ ] **Apple Watch App** - Native watchOS companion
- [ ] **Export Data** - CSV/JSON export functionality  
- [ ] **Usage Goals** - Set and track reduction goals
- [ ] **More Chart Types** - Additional data visualizations
- [ ] **Themes** - Custom app themes and colors
- [ ] **Advanced Analytics** - Deeper usage insights

### Community Requests
Have an idea? [Open an issue](https://github.com/bigc0127/NicNark-2/issues) and let's discuss it!

## 🆘 Support

### Getting Help
- 📖 **Documentation** - Check this README and code comments
- 🐛 **Bug Reports** - [Open an issue](https://github.com/bigc0127/NicNark-2/issues)
- 💡 **Feature Requests** - [Start a discussion](https://github.com/ConnorNeedling/NicNark-2/discussions)
- 💬 **Questions** - Use GitHub Discussions for general questions

### App Store Version
The official App Store version is maintained by Connor Needling and may include additional features or optimizations.

## ⚖️ Legal

- **Not Medical Software** - This app is not intended for medical use
- **No Warranties** - Provided as-is with no guarantees
- **User Responsibility** - Users are responsible for their nicotine consumption decisions
- **Compliance** - Ensure compliance with local laws and regulations

## 🙏 Acknowledgments

- **Apple** - For the excellent iOS development frameworks
- **SwiftUI Community** - For inspiration and best practices
- **Open Source Community** - For making collaborative development possible
- **Privacy Advocates** - For promoting privacy-first software design

## 📧 Contact

**Connor Needling**
- GitHub: [@ConnorNeedling](https://github.com/ConnorNeedling)
- App Store: [NicNark on App Store](https://apps.apple.com/app/nicnark) *(coming soon)*

---

**⚠️ Health Warning**: Nicotine is addictive and harmful to health. This app does not provide medical advice. Consult healthcare professionals for guidance on nicotine use or cessation. This project does not endorse or promote nicotine use.

**Made with ❤️ for the open source community**
