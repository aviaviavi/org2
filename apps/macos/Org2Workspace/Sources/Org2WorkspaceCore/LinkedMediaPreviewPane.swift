import AppKit
import AVKit
import SwiftUI

/// Native file view for images and videos opened in the workspace detail pane
/// (from chat links, rendered document links, or run outputs). Media files have
/// no Org source, so they render directly from the file URL, like PDFs do.
struct LinkedMediaPreviewPane: View {
  enum Kind: Equatable {
    case image
    case video
  }

  let file: String
  let kind: Kind
  /// Changes when the file is rewritten on disk; reloads the preview.
  let revision: Int

  var body: some View {
    Group {
      switch kind {
      case .image:
        LinkedImagePreview(url: fileURL, revision: revision)
      case .video:
        LinkedVideoPreview(url: fileURL, revision: revision)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var fileURL: URL {
    URL(fileURLWithPath: file).standardizedFileURL
  }
}

private struct LinkedImagePreview: View {
  @Environment(WorkspaceStore.self) private var store
  let url: URL
  let revision: Int
  @State private var image: NSImage?
  @State private var pixelSize: CGSize?
  @State private var didAttemptLoad = false
  @State private var fitsPane = true

  var body: some View {
    ZStack {
      if let image {
        if fitsPane {
          AnimatedImageView(image: image, scaling: .scaleProportionallyDown)
            .padding(16)
        } else {
          ScrollView([.horizontal, .vertical]) {
            AnimatedImageView(image: image, scaling: .scaleNone)
              .frame(width: image.size.width, height: image.size.height)
              .padding(16)
          }
        }
      } else if didAttemptLoad {
        LinkedMediaUnavailableView(
          systemImage: "photo",
          title: "Image preview unavailable",
          message: "\(url.lastPathComponent) could not be decoded. It may still be syncing.",
          retry: store.retryLinkedMediaPreview
        )
      } else {
        ProgressView("Loading image")
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if image != nil {
        HStack(spacing: 10) {
          if let pixelSize {
            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Divider()
            .frame(height: 14)
          Button(fitsPane ? "Actual Size" : "Fit") {
            fitsPane.toggle()
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .help(fitsPane ? "Show the image at its actual size" : "Fit the image to the pane")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(WorkspaceDesign.hairline))
        .padding(14)
      }
    }
    .task(id: "\(url.path)#\(revision)") {
      await load()
    }
  }

  private func load() async {
    let url = url
    let loaded = await Task.detached(priority: .userInitiated) {
      LoadedImage(image: NSImage(contentsOf: url))
    }.value
    guard !Task.isCancelled else { return }
    // Keep the last good image when a sync client is mid-rewrite.
    if let loadedImage = loaded.image, loadedImage.isValid {
      image = loadedImage
      pixelSize = Self.pixelSize(of: loadedImage)
    } else if image == nil {
      pixelSize = nil
    }
    didAttemptLoad = true
  }

  private static func pixelSize(of image: NSImage) -> CGSize {
    let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
    if let rep, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
      return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    return image.size
  }

  private struct LoadedImage: @unchecked Sendable {
    let image: NSImage?
  }
}

/// NSImageView keeps animated GIFs playing, which SwiftUI's Image does not.
private struct AnimatedImageView: NSViewRepresentable {
  let image: NSImage
  let scaling: NSImageScaling

  func makeNSView(context: Context) -> NSImageView {
    let view = NSImageView()
    view.animates = true
    view.isEditable = false
    view.imageAlignment = .alignCenter
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    view.setAccessibilityLabel("Image preview")
    return view
  }

  func updateNSView(_ view: NSImageView, context: Context) {
    if view.image !== image {
      view.image = image
    }
    view.imageScaling = scaling
  }
}

private struct LinkedVideoPreview: View {
  @Environment(WorkspaceStore.self) private var store
  let url: URL
  let revision: Int
  @State private var player: AVPlayer?
  @State private var isUnplayable = false

  var body: some View {
    ZStack {
      if isUnplayable {
        LinkedMediaUnavailableView(
          systemImage: "film",
          title: "Video preview unavailable",
          message: "\(url.lastPathComponent) could not be played. It may still be syncing, or the format is unsupported.",
          retry: store.retryLinkedMediaPreview
        )
      } else if let player {
        VideoPlayer(player: player)
      } else {
        ProgressView("Loading video")
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: "\(url.path)#\(revision)") {
      await load()
    }
    .onDisappear {
      player?.pause()
    }
  }

  private func load() async {
    player?.pause()
    let asset = AVURLAsset(url: url)
    let playable = (try? await asset.load(.isPlayable)) ?? false
    guard !Task.isCancelled else { return }
    guard playable else {
      player = nil
      isUnplayable = true
      return
    }
    isUnplayable = false
    player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }
}

private struct LinkedMediaUnavailableView: View {
  let systemImage: String
  let title: String
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      Button(action: retry) {
        Label("Retry", systemImage: "arrow.clockwise")
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}
