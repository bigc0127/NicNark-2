import WidgetKit
import SwiftUI

@main
struct AbsorptionTimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        NicotineGraphWidget()
        AbsorptionTimerWidgetLiveActivity()
    }
}
