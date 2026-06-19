import SwiftUI

@main
struct Org2MobileApp: App {
  @StateObject private var store = CorpusStore()

  var body: some Scene {
    WindowGroup {
      StartupHostView()
        .environmentObject(store)
    }
  }
}

private struct StartupHostView: View {
  @EnvironmentObject private var store: CorpusStore
  @State private var isReady = false
  @State private var hasStartedRestore = false

  var body: some View {
    Group {
      if isReady {
        ContentView()
      } else {
        StartupShellView()
      }
    }
    .onAppear {
      guard !hasStartedRestore else { return }
      hasStartedRestore = true

      DispatchQueue.main.async {
        store.startRestoringCorpus()
        isReady = true
      }
    }
  }
}

private struct StartupShellView: View {
  var body: some View {
    ZStack {
      Color(.systemGroupedBackground)
        .ignoresSafeArea()
      Text("Org2")
        .font(.largeTitle.weight(.semibold))
        .foregroundStyle(.primary)
    }
  }
}
