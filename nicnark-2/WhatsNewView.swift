//
// WhatsNewView.swift
// nicnark-2
//
// "What's New" greeter sheet shown once on first launch of this update.
//
// Mirrors the FirstRunDisclaimerView pattern: a NavigationStack-wrapped scrolling
// sheet driven by an `@Binding var isPresented: Bool`, with a single prominent
// dismissal action that flips a UserDefaults flag so we never show it again.
//
// The main agent presents this from ContentView AFTER the first-run disclaimer,
// whenever `UserDefaults.standard.hasShownWhatsNew_v2_6` is still false.
//

import SwiftUI

struct WhatsNewView: View {
    @Binding var isPresented: Bool

    // MARK: - Feature model
    //
    // A tiny value type describing one "what's new" row: an emoji glyph, a short
    // title, and a one-line blurb. Kept local + value-typed so it's trivially
    // Sendable-friendly and safe under Swift 6 strict concurrency.

    private struct Feature: Identifiable {
        let id = UUID()
        let emoji: String
        let title: String
        let blurb: String
    }

    // The EXACT five features shipping in this update, in order.
    private let features: [Feature] = [
        Feature(
            emoji: "📊",
            title: "Insights Dashboard",
            blurb: "The new Insights hub shows your multi-day trends — pouches and estimated mg over today, this week, and this month, all in one glanceable screen."
        ),
        Feature(
            emoji: "🎯",
            title: "Daily Goal",
            blurb: "Set a daily pouch limit and watch a progress ring on your Log screen keep you honest — with adherence tracked in Insights."
        ),
        Feature(
            emoji: "🏆",
            title: "Streaks & Milestones",
            blurb: "Earn milestone badges and keep your streaks alive — days tracked, days you hit your goal, and total pouches logged."
        ),
        Feature(
            emoji: "💰",
            title: "Cost Tracking",
            blurb: "See what your habit really costs — set your price and pouches per tin, and get spend for today, this week, this month, plus a projected monthly total."
        ),
        Feature(
            emoji: "📤",
            title: "Share & Export",
            blurb: "Brag or back up in one tap — share a clean text summary of your stats or export every log as a CSV."
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Friendly header
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)

                        Text("What's New in NicNark")
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)

                        Text("Here's what we added in this update")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)

                    Divider()

                    // One row per feature
                    VStack(spacing: 16) {
                        ForEach(features) { feature in
                            featureRow(feature)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            // Pin the primary action to the bottom so it's always reachable.
            .safeAreaInset(edge: .bottom) {
                Button {
                    // Mark this update's greeter as shown, then dismiss.
                    UserDefaults.standard.hasShownWhatsNew_v2_6 = true
                    isPresented = false
                } label: {
                    Text("Let's go")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .interactiveDismissDisabled() // Require an explicit tap on "Let's go"
    }

    // MARK: - Row builder

    /// A card-styled row: emoji badge on the left, title + blurb stacked on the right.
    /// Uses the app's standard `Color(.secondarySystemBackground)` + rounded-corner look.
    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(feature.emoji)
                .font(.system(size: 34))
                .frame(width: 44, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)
                    .fontWeight(.semibold)

                Text(feature.blurb)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - User Defaults Extension

extension UserDefaults {
    /// Whether the v2.6 "What's New" greeter has been shown. The main agent presents
    /// `WhatsNewView` (after the first-run disclaimer) whenever this is still false.
    var hasShownWhatsNew_v2_6: Bool {
        get { bool(forKey: "hasShownWhatsNew_v2_6") }
        set { set(newValue, forKey: "hasShownWhatsNew_v2_6") }
    }
}

#Preview {
    WhatsNewView(isPresented: .constant(true))
}
