import BackgroundTasks
import SwiftUI
@preconcurrency import UserNotifications

extension Notification.Name {
  static let org2OpenRemoteThread = Notification.Name("org2.openRemoteThread")
}

final class Org2MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  static let replyRefreshTaskIdentifier = "org.org2.mobile.thread-refresh"

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.replyRefreshTaskIdentifier,
      using: nil
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.scheduleReplyRefresh()
      let operation = Task { @MainActor in
        let store = MobileRemoteStore()
        let succeeded = await store.refreshReplyNotificationsInBackground()
        refreshTask.setTaskCompleted(success: succeeded)
      }
      refreshTask.expirationHandler = {
        operation.cancel()
      }
    }
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    Self.scheduleReplyRefresh()
  }

  static func scheduleReplyRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: replyRefreshTaskIdentifier)
    let request = BGAppRefreshTaskRequest(identifier: replyRefreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard notification.request.content.categoryIdentifier == MobileRemoteNotification.replyCategory else {
      completionHandler([])
      return
    }
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard response.notification.request.content.categoryIdentifier == MobileRemoteNotification.replyCategory,
          let rawThreadID = response.notification.request.content.userInfo["threadID"] as? String,
          UUID(uuidString: rawThreadID) != nil
    else {
      completionHandler()
      return
    }
    UserDefaults.standard.set(rawThreadID, forKey: MobileRemoteNotification.pendingReplyThreadIDKey)
    completionHandler()
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .org2OpenRemoteThread,
        object: nil,
        userInfo: ["threadID": rawThreadID]
      )
    }
  }
}

@main
struct Org2MobileApp: App {
  @UIApplicationDelegateAdaptor(Org2MobileAppDelegate.self) private var appDelegate
  @StateObject private var store = CorpusStore()
  @StateObject private var mobileRemote = MobileRemoteStore()

  var body: some Scene {
    WindowGroup {
      StartupHostView()
        .environmentObject(store)
        .environmentObject(mobileRemote)
    }
  }
}

private struct StartupHostView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var mobileRemote: MobileRemoteStore
  @Environment(\.scenePhase) private var scenePhase
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
        mobileRemote.setAppActive(scenePhase == .active)
        isReady = true
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        store.clearNotificationBadge()
      }
      mobileRemote.setAppActive(phase == .active)
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
