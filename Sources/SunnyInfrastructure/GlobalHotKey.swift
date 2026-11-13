// 通过系统热键注册 API 提供固定入口，不要求辅助功能或输入监控权限。
import AppKit
import Carbon

@MainActor public final class GlobalHotKey {
    public var action: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x53554E59 // ASCII: SUNY
    private let identifier: UInt32 = 1

    public init() {}

    /// 重复设置不重复注册；冲突返回系统错误码，展示层负责本地化提示。
    public func setEnabled(_ enabled: Bool) -> OSStatus {
        if !enabled {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            return noErr
        }
        if hotKey != nil { return noErr }
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
                guard let pointer else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &type, context, &eventHandler)
            guard result == noErr else { return result }
        }
        let id = EventHotKeyID(signature: signature, id: identifier)
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    public func stop() {
        _ = setEnabled(false)
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
