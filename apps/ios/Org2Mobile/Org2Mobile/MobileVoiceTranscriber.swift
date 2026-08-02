import AVFoundation
import Foundation
import Speech

@MainActor
final class MobileVoiceTranscriber: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var transcript = ""
  @Published var errorMessage: String?

  private let audioEngine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer(locale: .current)
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  func start() async {
    guard !isRecording else { return }
    guard await requestSpeechAuthorization() == .authorized else {
      errorMessage = "Allow Speech Recognition in Settings to transcribe a message."
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      errorMessage = "Allow Microphone access in Settings to transcribe a message."
      return
    }
    guard let recognizer, recognizer.isAvailable else {
      errorMessage = "Speech recognition is not currently available."
      return
    }

    stop(cancelRecognition: true)
    transcript = ""
    errorMessage = nil

    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.taskHint = .dictation
      recognitionRequest = request

      let inputNode = audioEngine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      inputNode.removeTap(onBus: 0)
      inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        request.append(buffer)
      }

      audioEngine.prepare()
      try audioEngine.start()
      isRecording = true

      // Speech invokes this callback on an arbitrary queue. Mark it Sendable so
      // Swift does not inherit MobileVoiceTranscriber's main-actor isolation.
      recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
        let nextTranscript = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal == true
        let errorText = error?.localizedDescription
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let nextTranscript {
            self.transcript = nextTranscript
          }
          if isFinal || errorText != nil {
            self.finishRecognition(errorText: isFinal ? nil : errorText)
          }
        }
      }
    } catch {
      stop(cancelRecognition: true)
      errorMessage = "Could not start transcription: \(error.localizedDescription)"
    }
  }

  func stop() {
    guard isRecording else { return }
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    isRecording = false
  }

  func cancel() {
    stop(cancelRecognition: true)
    transcript = ""
  }

  private func finishRecognition(errorText: String?) {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    isRecording = false
    recognitionRequest = nil
    recognitionTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if let errorText, transcript.isEmpty {
      errorMessage = "Transcription stopped: \(errorText)"
    }
  }

  private func stop(cancelRecognition: Bool) {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    if cancelRecognition {
      recognitionTask?.cancel()
    } else {
      recognitionRequest?.endAudio()
    }
    recognitionRequest = nil
    recognitionTask = nil
    isRecording = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      // TCC also responds on an arbitrary queue. Without an explicitly
      // nonisolated callback, Swift 6 traps while checking the main actor.
      SFSpeechRecognizer.requestAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
  }
}
