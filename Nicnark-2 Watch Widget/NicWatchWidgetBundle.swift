//
//  NicWatchWidgetBundle.swift
//  Nicnark-2 Watch Widget
//
//  Entry point for the watchOS complication bundle.
//

import WidgetKit
import SwiftUI

@main
struct NicWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        NicComplication()
    }
}

struct NicComplication: Widget {
    let kind = "NicComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NicComplicationProvider()) { entry in
            NicComplicationEntryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Nicotine")
        .description("Current nicotine in your body and the active pouch timer.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}
