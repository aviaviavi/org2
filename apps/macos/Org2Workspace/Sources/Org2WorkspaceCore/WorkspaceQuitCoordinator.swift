import Foundation

/// Keeps AppKit out of terminateLater so subsequent Quit events remain actionable.
/// Shutdown is best effort after confirmation; it never owns the right to exit.
@MainActor
public final class WorkspaceQuitCoordinator {
  public enum Prompt: Equatable {
    case activeWork, saveFailed, saveTakingTooLong
  }
  private enum State { case idle, confirming, saving, finished }
  private var state: State = .idle
  private var confirmed = false
  private var saveTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private let save: @MainActor () async -> Bool
  private let showPrompt: @MainActor (Prompt) -> Void
  private let quit: @MainActor () -> Void
  private let deadline: Duration

  public init(
    deadline: Duration,
    save: @escaping @MainActor () async -> Bool,
    showPrompt: @escaping @MainActor (Prompt) -> Void,
    quit: @escaping @MainActor () -> Void
  ) {
    self.deadline = deadline
    self.save = save
    self.showPrompt = showPrompt
    self.quit = quit
  }

  public func requestQuit(hasActiveWork: Bool) {
    guard state != .finished else { return }
    guard state == .idle else { finish(); return }
    if hasActiveWork {
      state = .confirming
      showPrompt(.activeWork)
    } else {
      beginSaving()
    }
  }

  public func respond(to prompt: Prompt, quit: Bool) {
    guard state == .confirming else { return }
    if quit {
      confirmed = true
      if prompt == .activeWork { beginSaving() } else { finish() }
    } else {
      // Once saving has started, Keep Waiting leaves it running. A second
      // Quit still overrides it; no repeated timed prompts interrupt the user.
      state = prompt == .saveTakingTooLong ? .saving : .idle
    }
  }

  private func beginSaving() {
    state = .saving
    saveTask = Task { [weak self] in
      guard let self else { return }
      let saved = await self.save()
      guard self.state != .finished else { return }
      self.deadlineTask?.cancel()
      if saved || self.confirmed {
        self.finish()
      } else {
        self.state = .confirming
        self.showPrompt(.saveFailed)
      }
    }
    deadlineTask = Task { [weak self, deadline] in
      do { try await Task.sleep(for: deadline) } catch { return }
      guard let self, self.state == .saving else { return }
      if self.confirmed {
        self.finish()
      } else {
        self.state = .confirming
        self.showPrompt(.saveTakingTooLong)
      }
    }
  }

  private func finish() {
    guard state != .finished else { return }
    state = .finished
    deadlineTask?.cancel()
    saveTask?.cancel()
    quit()
  }
}
