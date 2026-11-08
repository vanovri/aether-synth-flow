// MARK: - FILE: CoreAudioDeviceManager.swift

import Foundation
import Observation

#if os(macOS)
import CoreAudio
import AudioToolbox

// MARK: - Immutable CoreAudio Output DAC Descriptor

public struct CoreAudioOutputDAC: Identifiable, Sendable, Equatable, Hashable {
    public var id: AudioObjectID { deviceID }
    public let deviceID: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let outputStreamCount: Int
    public let outputChannelCount: Int
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    public let transportName: String
    public let isSystemDefaultOutput: Bool

    public init(
        deviceID: AudioObjectID,
        uid: String,
        name: String,
        manufacturer: String,
        outputStreamCount: Int,
        outputChannelCount: Int,
        nominalSampleRate: Double,
        availableSampleRates: [Double],
        transportName: String,
        isSystemDefaultOutput: Bool
    ) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.outputStreamCount = outputStreamCount
        self.outputChannelCount = outputChannelCount
        self.nominalSampleRate = nominalSampleRate
        self.availableSampleRates = availableSampleRates
        self.transportName = transportName
        self.isSystemDefaultOutput = isSystemDefaultOutput
    }
}

// MARK: - CoreAudio HAL Output Device Enumerator, Sample-Rate Switcher & Hot-Plug Monitor

@Observable
@MainActor
public final class CoreAudioDeviceManager {
    public private(set) var outputDevices: [CoreAudioOutputDAC] = []
    public private(set) var systemDefaultOutputID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    public var selectedOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var activeNominalSampleRate: Double = 48_000.0
    public private(set) var lastRoutingStatus: String = "System Default Output"

    public var onHotPlugDevicesChanged: ((CoreAudioOutputDAC?) -> Void)?

    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {
        refreshOutputDevices()
        installHardwareHotPlugListeners()
    }

    public var selectedDevice: CoreAudioOutputDAC? {
        outputDevices.first(where: { $0.deviceID == selectedOutputDeviceID })
            ?? outputDevices.first(where: \.isSystemDefaultOutput)
            ?? outputDevices.first
    }

    // MARK: - Enumerate Output DACs via CoreAudio HAL C-APIs

    public func refreshOutputDevices() {
        let defaultID = Self.readDefaultOutputDeviceID()
        self.systemDefaultOutputID = defaultID

        let allDeviceIDs = Self.readAllHardwareDeviceIDs()
        var discovered: [CoreAudioOutputDAC] = []
        discovered.reserveCapacity(allDeviceIDs.count)

        for devID in allDeviceIDs {
            let streamIDs = Self.readOutputStreamIDs(for: devID)
            guard !streamIDs.isEmpty else { continue }

            let channels = Self.readOutputChannelCount(for: devID)
            guard channels > 0 else { continue }

            let name = Self.readCFStringProperty(
                deviceID: devID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? "CoreAudio DAC #\(devID)"

            let manufacturer = Self.readCFStringProperty(
                deviceID: devID,
                selector: kAudioObjectPropertyManufacturer,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? "Apple / USB Audio"

            let uid = Self.readCFStringProperty(
                deviceID: devID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? "uid-\(devID)"

            let nominalRate = Self.readNominalSampleRate(for: devID)
            let supportedRates = Self.readAvailableNominalSampleRates(for: devID, currentRate: nominalRate)
            let transport = Self.readTransportLabel(for: devID)

            discovered.append(
                CoreAudioOutputDAC(
                    deviceID: devID,
                    uid: uid,
                    name: name,
                    manufacturer: manufacturer,
                    outputStreamCount: streamIDs.count,
                    outputChannelCount: channels,
                    nominalSampleRate: nominalRate,
                    availableSampleRates: supportedRates,
                    transportName: transport,
                    isSystemDefaultOutput: devID == defaultID
                )
            )
        }

        self.outputDevices = discovered

        if !discovered.contains(where: { $0.deviceID == selectedOutputDeviceID }) {
            selectedOutputDeviceID = defaultID != AudioObjectID(kAudioObjectUnknown)
                ? defaultID
                : (discovered.first?.deviceID ?? AudioObjectID(kAudioObjectUnknown))
        }

        if let active = selectedDevice {
            activeNominalSampleRate = active.nominalSampleRate
            installSampleRateListener(for: active.deviceID)
        }
    }

    // MARK: - Route AVAudioEngine & Switch Hardware Sample Rate

    public func routeEngine(
        _ audioEngine: AudioSynthEngine,
        toDeviceID deviceID: AudioObjectID
    ) async {
        guard outputDevices.contains(where: { $0.deviceID == deviceID }) else {
            lastRoutingStatus = "Requested DAC unavailable"
            return
        }

        do {
            try await audioEngine.routeOutputDevice(deviceID: deviceID)
            selectedOutputDeviceID = deviceID
            installSampleRateListener(for: deviceID)
            refreshOutputDevices()
            if let dev = selectedDevice {
                activeNominalSampleRate = dev.nominalSampleRate
                lastRoutingStatus = "Routed → \(dev.name) (\(Int(dev.nominalSampleRate)) Hz)"
            }
        } catch {
            lastRoutingStatus = "DAC Route Error: \(error.localizedDescription)"
        }
    }

    @discardableResult
    public func setNominalSampleRate(_ desiredRateHz: Double, onDeviceID deviceID: AudioObjectID? = nil) -> Bool {
        let targetID = deviceID ?? selectedOutputDeviceID
        guard targetID != AudioObjectID(kAudioObjectUnknown) else { return false }

        var rate = Float64(desiredRateHz)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isSettable: DarwinBoolean = false
        let checkStatus = AudioObjectIsPropertySettable(targetID, &address, &isSettable)
        guard checkStatus == noErr, isSettable.boolValue else {
            lastRoutingStatus = "Sample rate locked by hardware clock"
            return false
        }

        let dataSize = UInt32(MemoryLayout<Float64>.size)
        let setStatus = AudioObjectSetPropertyData(targetID, &address, 0, nil, dataSize, &rate)
        if setStatus == noErr {
            activeNominalSampleRate = desiredRateHz
            lastRoutingStatus = String(format: "Clock set to %.1f kHz", desiredRateHz / 1_000.0)
            refreshOutputDevices()
            return true
        } else {
            lastRoutingStatus = "Sample rate switch failed (\(setStatus))"
            return false
        }
    }

    // MARK: - Hot-Plug & Default Device Property Listeners

    private func installHardwareHotPlugListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshOutputDevices()
                self.onHotPlugDevicesChanged?(self.selectedDevice)
            }
        }
        self.devicesListenerBlock = devBlock
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddress, DispatchQueue.main, devBlock)

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshOutputDevices()
                self.onHotPlugDevicesChanged?(self.selectedDevice)
            }
        }
        self.defaultOutputListenerBlock = defBlock
        _ = AudioObjectAddPropertyListenerBlock(systemObject, &defaultAddress, DispatchQueue.main, defBlock)
    }

    private func installSampleRateListener(for deviceID: AudioObjectID) {
        guard deviceID != sampleRateListenerDeviceID else { return }
        removeSampleRateListener()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshOutputDevices()
            }
        }
        sampleRateListenerDeviceID = deviceID
        sampleRateListenerBlock = block
        _ = AudioObjectAddPropertyListenerBlock(deviceID, &rateAddress, DispatchQueue.main, block)
    }

    private func removeSampleRateListener() {
        guard sampleRateListenerDeviceID != AudioObjectID(kAudioObjectUnknown),
              let block = sampleRateListenerBlock else {
            return
        }
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(sampleRateListenerDeviceID, &rateAddress, DispatchQueue.main, block)
        sampleRateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
        sampleRateListenerBlock = nil
    }

    public func tearDownListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let devBlock = devicesListenerBlock {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &devicesAddress, DispatchQueue.main, devBlock)
            devicesListenerBlock = nil
        }
        if let defBlock = defaultOutputListenerBlock {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(systemObject, &defaultAddress, DispatchQueue.main, defBlock)
            defaultOutputListenerBlock = nil
        }
        removeSampleRateListener()
    }

    // MARK: - Low-Level CoreAudio HAL Property Queries

    private static func readDefaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func readAllHardwareDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteSize
        ) == noErr, byteSize > 0 else {
            return []
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteSize,
                base
            )
        }
        return status == noErr ? ids : []
    }

    private static func readOutputStreamIDs(for deviceID: AudioObjectID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioStreamID>.stride) else {
            return []
        }

        let count = Int(byteSize) / MemoryLayout<AudioStreamID>.stride
        var streams = [AudioStreamID](repeating: 0, count: count)
        let status = streams.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, base)
        }
        return status == noErr ? streams : []
    }

    private static func readOutputChannelCount(for deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, rawPtr) == noErr else {
            return 0
        }

        let ablPtr = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func readCFStringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: Unmanaged<CFString>?
        var byteSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, &unmanagedString)
        guard status == noErr, let cfStr = unmanagedString?.takeRetainedValue() else {
            return nil
        }
        return cfStr as String
    }

    private static func readNominalSampleRate(for deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48_000.0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return (status == noErr && rate > 0) ? rate : 48_000.0
    }

    private static func readAvailableNominalSampleRates(
        for deviceID: AudioObjectID,
        currentRate: Double
    ) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioValueRange>.stride) else {
            return [currentRate]
        }

        let count = Int(byteSize) / MemoryLayout<AudioValueRange>.stride
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        let status = ranges.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, base)
        }
        guard status == noErr else { return [currentRate] }

        let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        var matched: Set<Double> = [currentRate]
        for range in ranges {
            if abs(range.mMaximum - range.mMinimum) < 1.0 {
                matched.insert(range.mMinimum)
            } else {
                for std in standardRates where std >= range.mMinimum && std <= range.mMaximum {
                    matched.insert(std)
                }
            }
        }
        return matched.sorted()
    }

    private static func readTransportLabel(for deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return "CoreAudio"
        }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-In DAC"
        case kAudioDeviceTransportTypeUSB: return "USB Class-Audio"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Digital Display"
        case kAudioDeviceTransportTypeVirtual: return "Virtual Bus"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "External HAL"
        }
    }
}
#endif
