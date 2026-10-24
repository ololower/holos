import CoreAudio
import IOKit

struct AudioInputDevice: Identifiable, Hashable {
    enum Kind {
        /// Вбудований, USB, Thunderbolt… — те, що варто брати автоматично
        case wired
        /// Bluetooth (навушники переходять у режим гарнітури зі звуком гіршої якості), iPhone, AirPlay
        case wireless
        /// Віртуальні й агрегатні пристрої — не мікрофони; автоматично не беремо
        case virtual
    }

    let id: AudioDeviceID
    let uid: String
    let name: String
    let kind: Kind
    let isBuiltIn: Bool
}

enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            let transport = transportType(id)
            return AudioInputDevice(id: id, uid: uid, name: name, kind: kind(of: transport),
                                    isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// Мікрофон, вибраний у системі за замовчуванням
    static func defaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return inputs().first { $0.id == id }
    }

    /// Мікрофон для запису. Вибраний — якщо під'єднаний, навіть Bluetooth: його обрали явно.
    /// Інакше (або якщо вибрано «Автоматично») — спершу дротові, потім Bluetooth та інші бездротові;
    /// у кожній групі першим — системний за замовчуванням. Вбудований при закритій кришці пропускаємо:
    /// він записує лише тишу. Віртуальні пристрої автоматично не беремо.
    static func resolve(preferredUID: String) -> AudioInputDevice? {
        let all = inputs()
        if !preferredUID.isEmpty, let chosen = all.first(where: { $0.uid == preferredUID }) { return chosen }

        let lidClosed = isLidClosed
        let defaultID = defaultInput()?.id
        let candidates = all.filter { !(lidClosed && $0.isBuiltIn) }
        for kind in [AudioInputDevice.Kind.wired, .wireless] {
            let group = candidates.filter { $0.kind == kind }
            if let device = group.first(where: { $0.id == defaultID }) ?? group.first { return device }
        }
        return nil
    }

    /// Системна гучність входу мікрофона, 0…1; nil — у пристрою її немає (наприклад, iPhone)
    static func inputVolume(of device: AudioInputDevice) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device.id, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    /// Кришка MacBook закрита (працює із зовнішнім монітором)
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool ?? false
    }

    private static func kind(of transport: UInt32) -> AudioInputDevice.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .wireless
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return .virtual
        default:
            return .wired
        }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
