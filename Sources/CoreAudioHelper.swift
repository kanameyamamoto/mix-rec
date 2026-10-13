import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isBuiltIn: Bool
}

enum RecorderError: LocalizedError {
    case coreAudio(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let text, let status): return "\(text)（エラー \(status)）"
        case .message(let text): return text
        }
    }
}

enum CoreAudioHelper {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func deviceProperty(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        guard err == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        guard let id = deviceProperty(kAudioHardwarePropertyDefaultOutputDevice) else {
            throw RecorderError.message("音の出力先（スピーカーやイヤホン）が見つかりません")
        }
        return id
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        deviceProperty(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return err == noErr ? value : nil
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// マイクとして選べる入力装置の一覧
    static func inputDevices() -> [AudioDevice] {
        allDevices().compactMap { id in
            guard inputChannelCount(id) > 0,
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("MixRec-"), name != "MixRec Tap" else { return nil } // 自分の仮の装置は除く
            let transport = uint32Property(id, kAudioDevicePropertyTransportType)
            return AudioDevice(id: id, name: name, uid: uid,
                               isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }
}
