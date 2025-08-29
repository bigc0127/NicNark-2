//
// FirstRunDisclaimerView.swift
// nicnark-2
//
// First-run disclaimer popup for App Store compliance and user safety
//

import SwiftUI

struct FirstRunDisclaimerView: View {
    @Binding var isPresented: Bool
    @State private var hasScrolledToBottom = false
    @State private var scrollViewContentOffset: CGFloat = 0
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        
                        Text("Important Disclaimer")
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        Text("Please read carefully before using this app")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                    
                    Divider()
                    
                    // Medical Disclaimer
                    disclaimerSection(
                        title: "⚕️ Medical Disclaimer",
                        content: """
                        This app is designed SOLELY for personal tracking of nicotine consumption and is NOT intended for medical use.
                        
                        • This app does NOT provide medical advice, diagnosis, or treatment
                        • Nicotine calculations and timing are estimates only and should NOT be considered medically accurate
                        • This app does NOT endorse, promote, or condone nicotine use
                        • Consult with healthcare professionals for medical advice regarding nicotine use, addiction, or cessation
                        • If you are trying to quit nicotine, seek professional medical guidance
                        """
                    )
                    
                    Divider()
                    
                    // Health Warning
                    disclaimerSection(
                        title: "⚠️ Health Warning",
                        content: """
                        • Nicotine is an addictive substance that can be harmful to your health
                        • This app is intended for adults (18+) only
                        • Pregnant or nursing individuals should avoid nicotine products entirely
                        • If you experience adverse effects from nicotine use, discontinue immediately and consult a healthcare provider
                        • This app cannot prevent nicotine addiction or guarantee safety
                        """
                    )
                    
                    Divider()
                    
                    // Privacy & Data
                    disclaimerSection(
                        title: "🔒 Your Privacy & Data",
                        content: """
                        Your privacy is important to us:
                        
                        • We do NOT collect, store, or transmit any of your personal data
                        • All your data stays on your device and in your personal iCloud account (if enabled)
                        • No analytics, tracking, or data sharing with third parties
                        • No account creation or personal information required
                        • Your nicotine usage data is private and never leaves your control
                        • Data syncs only through your personal Apple iCloud account between your devices
                        """
                    )
                    
                    Divider()
                    
                    // App Purpose
                    disclaimerSection(
                        title: "📱 App Purpose",
                        content: """
                        This app is designed as a personal utility tool for:
                        
                        • Tracking personal nicotine consumption patterns
                        • Estimating absorption timing (for informational purposes only)
                        • Setting personal usage reminders
                        • Maintaining a private log of your usage
                        
                        This app is NOT designed to:
                        • Provide medical guidance or health advice
                        • Replace professional medical consultation
                        • Endorse or promote nicotine use
                        • Guarantee accuracy of health-related calculations
                        """
                    )
                    
                    Divider()
                    
                    // Legal Disclaimer
                    disclaimerSection(
                        title: "⚖️ Legal Disclaimer",
                        content: """
                        • Use this app at your own risk and discretion
                        • The developer assumes no responsibility for any health consequences from app usage
                        • Information provided is for educational and tracking purposes only
                        • Always comply with local laws and regulations regarding nicotine products
                        • The developer disclaims all warranties, express or implied
                        """
                    )
                    
                    // Agreement Text
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By continuing to use this app, you acknowledge that you:")
                            .font(.headline)
                            .padding(.top)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            agreementPoint("Are 18 years of age or older")
                            agreementPoint("Have read and understand all disclaimers above")
                            agreementPoint("Understand this app does not provide medical advice")
                            agreementPoint("Will not rely on this app for health decisions")
                            agreementPoint("Accept full responsibility for your nicotine use")
                            agreementPoint("Understand the developer collects no personal data")
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical)
                    
                    // Bottom padding for scroll detection
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear {
                                        // Check if user has scrolled to bottom
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            hasScrolledToBottom = true
                                        }
                                    }
                            }
                        )
                }
                .padding()
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onChange(of: geometry.frame(in: .named("scroll"))) { _, frame in
                                scrollViewContentOffset = frame.minY
                                // Enable button when user scrolls near bottom
                                if frame.minY < -100 {
                                    hasScrolledToBottom = true
                                }
                            }
                    }
                )
            }
            .coordinateSpace(name: "scroll")
            .navigationTitle("Disclaimer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(hasScrolledToBottom ? "I Understand & Agree" : "Please Scroll to Continue") {
                        if hasScrolledToBottom {
                            // Mark disclaimer as shown
                            UserDefaults.standard.set(true, forKey: "HasShownFirstRunDisclaimer")
                            isPresented = false
                        }
                    }
                    .disabled(!hasScrolledToBottom)
                    .foregroundColor(hasScrolledToBottom ? .blue : .secondary)
                    .fontWeight(hasScrolledToBottom ? .semibold : .regular)
                }
            }
        }
        .interactiveDismissDisabled() // Prevent dismissal by swiping down
    }
    
    private func disclaimerSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            
            Text(content)
                .font(.body)
                .lineSpacing(2)
        }
    }
    
    private func agreementPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body)
                .foregroundColor(.blue)
            
            Text(text)
                .font(.body)
        }
    }
}

// MARK: - User Defaults Extension
extension UserDefaults {
    var hasShownFirstRunDisclaimer: Bool {
        get { bool(forKey: "HasShownFirstRunDisclaimer") }
        set { set(newValue, forKey: "HasShownFirstRunDisclaimer") }
    }
}

#Preview {
    FirstRunDisclaimerView(isPresented: .constant(true))
}
