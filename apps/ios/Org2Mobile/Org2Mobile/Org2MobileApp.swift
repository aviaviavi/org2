import SwiftUI

@main
struct Org2MobileApp: App {
  @StateObject private var store = CorpusStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .task {
          await store.restoreCorpus()
        }
    }
  }
}
