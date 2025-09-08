//
//  NotificationManagementView.swift
//  nicnark-2
//
//  Comprehensive notification settings interface
//

import SwiftUI

struct NotificationManagementView: View {
    @StateObject private var settings = NotificationSettings.shared
    @State private var showingTimeBasedOptions = false
    @State private var showingLevelBasedOptions = false
    
    var body: some View {
        Form {
            canInventorySection
            usageRemindersSection
            dailySummarySection
            usageInsightsSection
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Can Inventory Alerts
    
    private var canInventorySection: some View {
        Section {
            Toggle("Low Inventory Alerts", isOn: $settings.canLowInventoryEnabled)
                .onChange(of: settings.canLowInventoryEnabled) { _ in
                    NotificationManager.rescheduleNotifications()
                }
            
            if settings.canLowInventoryEnabled {
                Stepper(value: $settings.canLowInventoryThreshold, in: 1...20) {
                    HStack {
                        Text("Alert when below")
                        Spacer()
                        Text("\(settings.canLowInventoryThreshold) pouches")
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: settings.canLowInventoryThreshold) { _ in
                    NotificationManager.rescheduleNotifications()
                }
            }
        } header: {
            Label("Can Inventory", systemImage: "tray.2")
        } footer: {
            if settings.canLowInventoryEnabled {
                Text("You'll be notified when any can drops below \(settings.canLowInventoryThreshold) pouches")
            }
        }
    }
    
    // MARK: - Usage Reminders
    
    private var usageRemindersSection: some View {
        Section {
            Picker("Reminder Type", selection: $settings.reminderType) {
                ForEach(ReminderType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .onChange(of: settings.reminderType) { _ in
                NotificationManager.rescheduleNotifications()
            }
            
            if settings.reminderType == .timeBased {
                timeBasedReminderOptions
            } else if settings.reminderType == .nicotineLevelBased {
                nicotineLevelReminderOptions
            }
        } header: {
            Label("Usage Reminders", systemImage: "bell.badge")
        } footer: {
            reminderFooterText
        }
    }
    
    @ViewBuilder
    private var timeBasedReminderOptions: some View {
        Picker("Interval", selection: $settings.reminderInterval) {
            ForEach(ReminderInterval.allCases, id: \.self) { interval in
                Text(interval.displayName).tag(interval)
            }
        }
        .onChange(of: settings.reminderInterval) { _ in
            NotificationManager.rescheduleNotifications()
        }
        
        if settings.reminderInterval == .custom {
            Stepper(value: $settings.customReminderMinutes, in: 15...480, step: 15) {
                HStack {
                    Text("Custom interval")
                    Spacer()
                    Text("\(settings.customReminderMinutes) minutes")
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: settings.customReminderMinutes) { _ in
                NotificationManager.rescheduleNotifications()
            }
        }
    }
    
    @ViewBuilder
    private var nicotineLevelReminderOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target Nicotine Range")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                VStack(alignment: .leading) {
                    Text("Low: \(String(format: "%.1f", settings.nicotineRangeLow))mg")
                    Slider(value: $settings.nicotineRangeLow, in: 0...5, step: 0.1)
                        .onChange(of: settings.nicotineRangeLow) { _ in
                            NotificationManager.rescheduleNotifications()
                        }
                }
                
                VStack(alignment: .leading) {
                    Text("High: \(String(format: "%.1f", settings.nicotineRangeHigh))mg")
                    Slider(value: $settings.nicotineRangeHigh, in: 0.5...10, step: 0.1)
                        .onChange(of: settings.nicotineRangeHigh) { _ in
                            NotificationManager.rescheduleNotifications()
                        }
                }
            }
            
            HStack {
                Text("Alert threshold")
                Spacer()
                Picker("", selection: $settings.nicotineAlertThreshold) {
                    Text("0.1mg").tag(0.1)
                    Text("0.2mg").tag(0.2)
                    Text("0.3mg").tag(0.3)
                    Text("0.5mg").tag(0.5)
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: settings.nicotineAlertThreshold) { _ in
                    NotificationManager.rescheduleNotifications()
                }
            }
        }
    }
    
    private var reminderFooterText: Text {
        switch settings.reminderType {
        case .disabled:
            return Text("No usage reminders will be sent")
        case .timeBased:
            let interval = settings.reminderInterval == .custom 
                ? "\(settings.customReminderMinutes) minutes" 
                : settings.reminderInterval.displayName.lowercased()
            return Text("You'll be reminded to use a pouch \(interval)")
        case .nicotineLevelBased:
            return Text("You'll be notified when nicotine levels are \(String(format: "%.1f", settings.nicotineAlertThreshold))mg from your target range (\(String(format: "%.1f", settings.nicotineRangeLow))-\(String(format: "%.1f", settings.nicotineRangeHigh))mg)")
        }
    }
    
    // MARK: - Daily Summary
    
    private var dailySummarySection: some View {
        Section(header: Label("Daily Summary", systemImage: "chart.bar.doc.horizontal"),
                footer: dailySummaryFooter) {
            Toggle("Daily Summary", isOn: $settings.dailySummaryEnabled)
                .onChange(of: settings.dailySummaryEnabled) { _ in
                    NotificationManager.rescheduleNotifications()
                }
            
            if settings.dailySummaryEnabled {
                DatePicker("Summary Time", 
                          selection: $settings.dailySummaryDate,
                          displayedComponents: .hourAndMinute)
                    .onChange(of: settings.dailySummaryDate) { _ in
                        NotificationManager.rescheduleNotifications()
                    }
                
                Toggle("Show Previous Day", isOn: $settings.dailySummaryShowPreviousDay)
                    .onChange(of: settings.dailySummaryShowPreviousDay) { _ in
                        NotificationManager.rescheduleNotifications()
                    }
            }
        }
    }
    
    @ViewBuilder
    private var dailySummaryFooter: some View {
        if settings.dailySummaryEnabled {
            Group {
                if settings.dailySummaryShowPreviousDay {
                    Text("You'll receive a summary of yesterday's usage at \(formatTime(settings.dailySummaryDate))")
                } else {
                    Text("You'll receive today's usage summary at \(formatTime(settings.dailySummaryDate))")
                }
            }
        }
    }
    
    // MARK: - Usage Insights
    
    private var usageInsightsSection: some View {
        Section {
            Toggle("Usage Insights", isOn: $settings.insightsEnabled)
                .onChange(of: settings.insightsEnabled) { _ in
                    NotificationManager.rescheduleNotifications()
                }
            
            if settings.insightsEnabled {
                Picker("Compare Period", selection: $settings.insightsPeriod) {
                    ForEach(InsightPeriod.allCases, id: \.self) { period in
                        Text(period.displayName).tag(period)
                    }
                }
                .onChange(of: settings.insightsPeriod) { _ in
                    NotificationManager.rescheduleNotifications()
                }
                
                Stepper(value: $settings.insightsThresholdPercentage, in: 10...50, step: 5) {
                    HStack {
                        Text("Alert threshold")
                        Spacer()
                        Text("+\(Int(settings.insightsThresholdPercentage))%")
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: settings.insightsThresholdPercentage) { _ in
                    NotificationManager.rescheduleNotifications()
                }
            }
        } header: {
            Label("Usage Insights", systemImage: "chart.line.uptrend.xyaxis")
        } footer: {
            if settings.insightsEnabled {
                Text("You'll be notified when usage in the last \(settings.insightsPeriod.displayName) is \(Int(settings.insightsThresholdPercentage))% above your average")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct NotificationManagementView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            NotificationManagementView()
        }
    }
}
