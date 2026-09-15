import Foundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct MobileCallTranscriptDraft: Equatable {
  let title: String
  let body: String

  static func appleTranscript(_ transcript: String, now: Date = Date()) -> Self {
    make(
      transcript: transcript,
      suggestedTitle: nil,
      source: "Apple Phone call transcript",
      now: now
    )
  }

  static func audioTranscript(
    _ transcript: String,
    filename: String,
    now: Date = Date()
  ) -> Self {
    let basename = (filename as NSString).deletingPathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return make(
      transcript: transcript,
      suggestedTitle: basename.isEmpty ? nil : basename,
      source: "Transcribed on iPhone from \(filename)",
      now: now
    )
  }

  private static func make(
    transcript: String,
    suggestedTitle: String?,
    source: String,
    now: Date
  ) -> Self {
    let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = suggestedTitle.map { "Phone call — \($0)" }
      ?? "Phone call — \(titleDateFormatter.string(from: now))"
    return Self(
      title: title,
      body: """
      Source: \(source)

      Transcript:
      \(cleanTranscript)
      """
    )
  }

  private static var titleDateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }
}

@MainActor
final class MobileCallRecordingTranscriber: ObservableObject {
  @Published private(set) var isTranscribing = false
  @Published private(set) var partialTranscript = ""

  private var recognitionTask: SFSpeechRecognitionTask?
  private var activeRecognitionID: UUID?

  func transcribe(url: URL) async throws -> String {
    guard !isTranscribing else {
      throw MobileCallTranscriptionError.alreadyRunning
    }

    let authorization = await requestSpeechAuthorization()
    guard authorization == .authorized else {
      throw MobileCallTranscriptionError.permissionDenied
    }
    guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
      throw MobileCallTranscriptionError.unavailable
    }

    let hasSecurityAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let recognitionID = UUID()
    activeRecognitionID = recognitionID
    isTranscribing = true
    partialTranscript = ""
    defer {
      if activeRecognitionID == recognitionID {
        recognitionTask?.cancel()
        recognitionTask = nil
        activeRecognitionID = nil
        isTranscribing = false
      }
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.addsPunctuation = true

    return try await withCheckedThrowingContinuation { continuation in
      let gate = MobileCallRecognitionCompletion(continuation)
      recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
        let candidate = result?.bestTranscription.formattedString
        Task { @MainActor [weak self] in
          guard let self, self.activeRecognitionID == recognitionID else { return }
          if let candidate {
            self.partialTranscript = candidate
          }
        }

        if let result, result.isFinal {
          let transcript = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if transcript.isEmpty {
            gate.resume(throwing: MobileCallTranscriptionError.emptyTranscript)
          } else {
            gate.resume(returning: transcript)
          }
        } else if let error {
          gate.resume(throwing: error)
        }
      }
    }
  }

  private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = SFSpeechRecognizer.authorizationStatus()
    guard current == .notDetermined else { return current }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
  }
}

private final class MobileCallRecognitionCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, any Error>?

  init(_ continuation: CheckedContinuation<String, any Error>) {
    self.continuation = continuation
  }

  func resume(returning transcript: String) {
    take()?.resume(returning: transcript)
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<String, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let result = continuation
    continuation = nil
    return result
  }
}

private enum MobileCallTranscriptionError: LocalizedError {
  case alreadyRunning
  case permissionDenied
  case unavailable
  case emptyTranscript

  var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "Another recording is already being transcribed."
    case .permissionDenied:
      "Allow Speech Recognition in Settings to transcribe a call recording."
    case .unavailable:
      "Speech recognition is not currently available for this language."
    case .emptyTranscript:
      "No speech was recognized in this recording."
    }
  }
}

struct MobileCallTranscriptImportView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var transcriber = MobileCallRecordingTranscriber()
  @State private var isFileImporterPresented = false
  @State private var errorMessage: String?

  let onImport: (MobileCallTranscriptDraft) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("Use iPhone Call Recording", systemImage: "phone.arrow.down.left")
            .font(.headline)
          Text("Make sure everyone is willing to be recorded. During the call, tap More, then Call Recording. Everyone hears Apple’s recording notice. After the call, open its note and copy the transcript.")
            .foregroundStyle(.secondary)

          LabeledContent {
            PasteButton(payloadType: String.self) { transcripts in
              pasteAppleTranscript(transcripts)
            }
            .accessibilityLabel("Paste Apple Transcript")
          } label: {
            Label("Apple Transcript", systemImage: "doc.on.clipboard")
          }

          if let instructionsURL = URL(string: "https://support.apple.com/121583") {
            Link(destination: instructionsURL) {
              Label("Apple’s call recording instructions", systemImage: "arrow.up.right.square")
            }
          }
        } header: {
          Text("Recommended")
        } footer: {
          Text("Call recording and transcription depend on region and language. Verify the transcript before saving it; Apple’s version can preserve speaker labels.")
        }

        Section {
          Button {
            isFileImporterPresented = true
          } label: {
            if transcriber.isTranscribing {
              HStack(spacing: 10) {
                ProgressView()
                Text("Transcribing recording…")
              }
            } else {
              Label("Choose Audio Recording", systemImage: "waveform.badge.magnifyingglass")
            }
          }
          .disabled(transcriber.isTranscribing)

          if transcriber.isTranscribing, !transcriber.partialTranscript.isEmpty {
            Text(transcriber.partialTranscript)
              .lineLimit(5)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Audio fallback")
        } footer: {
          Text("If Apple did not create a transcript, save or share the call audio to Files and choose it here. OpenOrg uses iOS Speech recognition and leaves the original recording where it is.")
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Import Phone Call")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(transcriber.isTranscribing)
        }
      }
      .interactiveDismissDisabled(transcriber.isTranscribing)
      .fileImporter(
        isPresented: $isFileImporterPresented,
        allowedContentTypes: [.audio],
        allowsMultipleSelection: false
      ) { result in
        importRecording(result)
      }
    }
  }

  private func pasteAppleTranscript(_ transcripts: [String]) {
    guard let transcript = transcripts.lazy
      .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      .first(where: { !$0.isEmpty }) else {
      errorMessage = "Copy the call transcript in Notes, then try again."
      return
    }
    finish(with: .appleTranscript(transcript))
  }

  private func importRecording(_ result: Result<[URL], any Error>) {
    switch result {
    case .failure(let error):
      if (error as NSError).code != NSUserCancelledError {
        errorMessage = "Could not open that recording: \(error.localizedDescription)"
      }
    case .success(let urls):
      guard let url = urls.first else { return }
      errorMessage = nil
      Task {
        do {
          let transcript = try await transcriber.transcribe(url: url)
          finish(with: .audioTranscript(transcript, filename: url.lastPathComponent))
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func finish(with draft: MobileCallTranscriptDraft) {
    onImport(draft)
    dismiss()
  }
}
