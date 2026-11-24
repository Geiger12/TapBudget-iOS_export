// App.swift
// TapBudget for iPhone: the app's entry point.
//
// Set up in Xcode 27:
//   1. File > New > Project > iOS > App. Name it TapBudget. Interface: SwiftUI. Language: Swift.
//   2. Replace the generated App file and ContentView.swift with these two files.
//   3. Target > General > Minimum Deployments: iOS 26.0 (the Liquid Glass APIs start there).
//   4. Run. The first launch opens an example budget. To bring in your real one, save a backup file
//      from the web app, then Settings > Back up > Import a backup, and paste it in.

import SwiftUI

@main
struct TapBudgetApp: App {
    @State private var store = BudgetStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(.teal)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.applyAutoPay()       // automatic bills mark themselves paid on their due day
            case .background: store.save()
            default: break
            }
        }
    }
}
