import AppKit
import Carbon

final class GlobalCaptureHotKey {
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?
  private var action: (() -> Void)?

  deinit {
    unregister()
  }

  @discardableResult
  func register(action: @escaping () -> Void) -> OSStatus {
    self.action = action
    guard hotKey == nil else {
      return noErr
    }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let hotKey = Unmanaged<GlobalCaptureHotKey>.fromOpaque(userData).takeUnretainedValue()
        hotKey.action?()
        return noErr
      },
      1,
      &eventType,
      userData,
      &eventHandler
    )
    guard handlerStatus == noErr else {
      return handlerStatus
    }

    let hotKeyID = EventHotKeyID(
      signature: Self.fourCharacterCode("O2CP"),
      id: 1
    )
    let hotKeyStatus = RegisterEventHotKey(
      UInt32(kVK_Return),
      UInt32(cmdKey | controlKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    if hotKeyStatus != noErr {
      unregister()
    }
    return hotKeyStatus
  }

  func unregister() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  private static func fourCharacterCode(_ raw: String) -> OSType {
    var result: OSType = 0
    for byte in raw.utf8.prefix(4) {
      result = (result << 8) + OSType(byte)
    }
    return result
  }
}
