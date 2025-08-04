//
//  nicnark_2App.swift
//  nicnark-2
//
//  Created by Connor Needling on 8/3/25.
//

import SwiftUI

@main
struct nicnark_2App: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
