// MARK: - FILE: OfflineStemExporter.swift

import Foundation
import SwiftUI
import UniformTypeIdentifiers

public enum WAVBitDepth: String, Codable, CaseIterable, Sendable, Identifiable {
    case pcm24Bit = "pcm_24bit"
    case ieeeFloat32Bit = "float_32bit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pcm24Bit: return "24-Bit PCM WAV"
        case .ieeeFloat32Bit: return "32-Bit Float WAV"
        }
    }

    public var audioFormatCode: UInt16 {
        switch self {
        case .pcm24Bit: return 1        // WAVE_FORMAT_PCM
        case .ieeeFloat32Bit: return 3  // WAVE_FORMAT_IEEE_FLOAT
        }
    }

    public var bitsPerSample: UInt16 {
        switch self {
        case .pcm24Bit: return 24
        case .ieeeFloat32Bit: return 32
        }
    }

    public var bytesPerSample: Int {
        Int(bitsPerSample / 8)
    }
}

public enum WAVEncodingError: LocalizedError, Sendable, Equatable {
    case emptyFrameBuffer
    case invalidRIFFHeader
    case mismatchedChannelLengths

    public var errorDescription: String? {
        switch self {
        case .emptyFrameBuffer:
            return "Cannot encode an empty audio buffer."
        case .invalidRIFFHeader:
            return "Malformed RIFF/WAVE binary header."
        case .mismatchedChannelLengths:
            return "Left and right stereo buffers have unequal lengths."
        }
    }
}

public struct WAVHeaderMetadata: Sendable, Equatable {
    public let riffChunkSize: UInt32
    public let audioFormatCode: UInt16
    public let channelCount: UInt16
    public let sampleRate: UInt32
    public let byteRate: UInt32
    public let blockAlign: UInt16
    public let bitsPerSample: UInt16
    public let dataByteCount: UInt32
    public let frameCount: Int
}

// MARK: - Spec-Compliant RIFF/WAVE 24-Bit PCM & 32-Bit IEEE Float Binary Codec

public enum WAVBinaryCodec: Sendable {
    public static func encodeStereoWAV(
        left: [Float],
        right: [Float],
        sampleRate: UInt32 = 48_000,
        bitDepth: WAVBitDepth = .pcm24Bit
    ) throws -> Data {
        guard !left.isEmpty else { throw WAVEncodingError.emptyFrameBuffer }
        guard left.count == right.count else { throw WAVEncodingError.mismatchedChannelLengths }

        let frameCount = left.count
        let numChannels: UInt16 = 2
        let bytesPerSample = bitDepth.bytesPerSample
        let blockAlign = UInt16(Int(numChannels) * bytesPerSample)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataByteCount = UInt32(frameCount * Int(blockAlign))
        let riffChunkSize = 36 &+ dataByteCount

        var data = Data()
        data.reserveCapacity(44 + Int(dataByteCount))

        @inline(__always)
        func appendASCII(_ fourCC: StaticString) {
            fourCC.withUTF8Buffer { buf in
                data.append(buf.baseAddress!, count: 4)
            }
        }

        @inline(__always)
        func appendUInt16LE(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        @inline(__always)
        func appendUInt32LE(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        // Canonical 44-byte RIFF/WAVE header
        appendASCII("RIFF")
        appendUInt32LE(riffChunkSize)
        appendASCII("WAVE")

        appendASCII("fmt ")
        appendUInt32LE(16) // PCM / IEEE Float standard fmt payload size
        appendUInt16LE(bitDepth.audioFormatCode)
        appendUInt16LE(numChannels)
        appendUInt32LE(sampleRate)
        appendUInt32LE(byteRate)
        appendUInt16LE(blockAlign)
        appendUInt16LE(bitDepth.bitsPerSample)

        appendASCII("data")
        appendUInt32LE(dataByteCount)

        switch bitDepth {
        case .pcm24Bit:
            // Deterministic TPDF 1-LSB triangular dither prevents quantization distortion
            var rng: UInt64 = 0x24B1_7D5F_9931_CA07
            let fullScale: Float = 8_388_607.0

            @inline(__always)
            func nextDitherLSB() -> Float {
                rng &+= 0x9E37_79B9_7F4A_7C15
                var z = rng
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z = z ^ (z >> 31)
                let u1 = Float((z >> 40) & 0xFFFFFF) / 16_777_216.0
                let u2 = Float((z >> 16) & 0xFFFFFF) / 16_777_216.0
                return (u1 - u2) * 0.5
            }

            var payload = [UInt8](repeating: 0, count: Int(dataByteCount))
            var writeOffset = 0

            for i in 0..<frameCount {
                let sL = min(max(left[i], -1.0), 1.0)
                let sR = min(max(right[i], -1.0), 1.0)

                let qL = Int32(min(max((sL * fullScale + nextDitherLSB()).rounded(), -8_388_608.0), 8_388_607.0))
                let qR = Int32(min(max((sR * fullScale + nextDitherLSB()).rounded(), -8_388_608.0), 8_388_607.0))

                let uL = UInt32(bitPattern: qL)
                payload[writeOffset] = UInt8(truncatingIfNeeded: uL)
                payload[writeOffset + 1] = UInt8(truncatingIfNeeded: uL >> 8)
                payload[writeOffset + 2] = UInt8(truncatingIfNeeded: uL >> 16)

                let uR = UInt32(bitPattern: qR)
                payload[writeOffset + 3] = UInt8(truncatingIfNeeded: uR)
                payload[writeOffset + 4] = UInt8(truncatingIfNeeded: uR >> 8)
                payload[writeOffset + 5] = UInt8(truncatingIfNeeded: uR >> 16)

                writeOffset += 6
            }
            data.append(contentsOf: payload)

        case .ieeeFloat32Bit:
            var payload = [UInt32](repeating: 0, count: frameCount * 2)
            for i in 0..<frameCount {
                let sL = min(max(left[i], -1.0), 1.0)
                let sR = min(max(right[i], -1.0), 1.0)
                payload[i * 2] = sL.bitPattern.littleEndian
                payload[i * 2 + 1] = sR.bitPattern.littleEndian
            }
            payload.withUnsafeBytes { rawBytes in
                data.append(contentsOf: rawBytes)
            }
        }

        return data
    }

    public static func parseHeader(_ data: Data) throws -> WAVHeaderMetadata {
        guard data.count >= 44 else { throw WAVEncodingError.invalidRIFFHeader }

        func readU16(_ offset: Int) -> UInt16 {
            let b0 = UInt16(data[data.startIndex + offset])
            let b1 = UInt16(data[data.startIndex + offset + 1]) << 8
            return b0 | b1
        }

        func readU32(_ offset: Int) -> UInt32 {
            let b0 = UInt32(data[data.startIndex + offset])
            let b1 = UInt32(data[data.startIndex + offset + 1]) << 8
            let b2 = UInt32(data[data.startIndex + offset + 2]) << 16
            let b3 = UInt32(data[data.startIndex + offset + 3]) << 24
            return b0 | b1 | b2 | b3
        }

        let riffTag = String(decoding: data.subdata(in: 0..<4), as: UTF8.self)
        let waveTag = String(decoding: data.subdata(in: 8..<12), as: UTF8.self)
        let fmtTag = String(decoding: data.subdata(in: 12..<16), as: UTF8.self)
        let dataTag = String(decoding: data.subdata(in: 36..<40), as: UTF8.self)

        guard riffTag == "RIFF", waveTag == "WAVE", fmtTag == "fmt ", dataTag == "data" else {
            throw WAVEncodingError.invalidRIFFHeader
        }

        let riffSize = readU32(4)
        let audioFormat = readU16(20)
        let channels = readU16(22)
        let rate = readU32(24)
        let byteRate = readU32(28)
        let blockAlign = readU16(32)
        let bits = readU16(34)
        let dataSize = readU32(40)
        let frames = blockAlign > 0 ? Int(dataSize) / Int(blockAlign) : 0

        return WAVHeaderMetadata(
            riffChunkSize: riffSize,
            audioFormatCode: audioFormat,
            channelCount: channels,
            sampleRate: rate,
            byteRate: byteRate,
            blockAlign: blockAlign,
            bitsPerSample: bits,
            dataByteCount: dataSize,
            frameCount: frames
        )
    }
}

// MARK: - SwiftUI FileDocument & Transferable Wrapper

public struct WAVStemDocument: FileDocument, Transferable, Sendable {
    public static let readableContentTypes: [UTType] = [.wav]

    public var wavData: Data
    public var suggestedFilename: String

    public init(wavData: Data = Data(), suggestedFilename: String = "AetherSynth-Stem.wav") {
        self.wavData = wavData
        self.suggestedFilename = suggestedFilename
    }

    public init(configuration: ReadConfiguration) throws {
        self.wavData = configuration.file.regularFileContents ?? Data()
        self.suggestedFilename = "AetherSynth-Stem.wav"
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: wavData)
    }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .wav) { doc in
            doc.wavData
        }
    }
}

public struct StemRenderRequest: Sendable {
    public var title: String
    public var parameters: SynthParameters
    public var category: FocusCategory
    public var durationSeconds: Double
    public var crossfadeSeconds: Double
    public var sampleRate: UInt32
    public var bitDepth: WAVBitDepth
    public var applyEntrainmentEnvelope: Bool

    public init(
        title: String = "AetherSynth-Stem",
        parameters: SynthParameters,
        category: FocusCategory = .deepWork,
        durationSeconds: Double = 12.0,
        crossfadeSeconds: Double = 1.5,
        sampleRate: UInt32 = 48_000,
        bitDepth: WAVBitDepth = .pcm24Bit,
        applyEntrainmentEnvelope: Bool = true
    ) {
        self.title = title
        self.parameters = parameters
        self.category = category
        self.durationSeconds = durationSeconds
        self.crossfadeSeconds = crossfadeSeconds
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.applyEntrainmentEnvelope = applyEntrainmentEnvelope
    }
}

// MARK: - Background Actor Offline Stem & Seamless Loop Renderer

public actor OfflineStemExporter {
    public init() {}

    public func renderStemDocument(request: StemRenderRequest) throws -> WAVStemDocument {
        let ramp = request.applyEntrainmentEnvelope ? EntrainmentRampSchedule(category: request.category) : nil
        let data = try renderSeamlessLoopWAV(
            baseParameters: request.parameters,
            rampSchedule: ramp,
            durationSeconds: request.durationSeconds,
            loopCrossfadeSeconds: request.crossfadeSeconds,
            sampleRate: request.sampleRate,
            bitDepth: request.bitDepth
        )
        let sanitized = request.title
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let baseName = sanitized.isEmpty ? "AetherSynth-Stem" : sanitized
        return WAVStemDocument(wavData: data, suggestedFilename: "\(baseName).wav")
    }

    public func renderSeamlessLoopWAV(
        baseParameters: SynthParameters,
        rampSchedule: EntrainmentRampSchedule? = nil,
        durationSeconds: Double = 12.0,
        loopCrossfadeSeconds: Double = 1.25,
        sampleRate: UInt32 = 48_000,
        bitDepth: WAVBitDepth = .pcm24Bit
    ) throws -> Data {
        let safeDuration = min(max(durationSeconds, 1.0), 300.0)
        let rateDouble = Double(sampleRate)
        let targetFrames = max(512, Int((safeDuration * rateDouble).rounded()))
        let crossfadeFrames = min(targetFrames / 3, max(128, Int((loopCrossfadeSeconds * rateDouble).rounded())))
        let totalSynthesisFrames = targetFrames + crossfadeFrames

        var activeParams = baseParameters
        activeParams.isMuted = false

        var kernel = ProceduralSynthKernel(sampleRate: rateDouble, snapInitialParameters: activeParams)

        // 1. Settle resonant filters & reverb lines for 2,048 warm-up frames
        let warmupCount = 2_048
        var warmL = [Float](repeating: 0, count: warmupCount)
        var warmR = [Float](repeating: 0, count: warmupCount)
        _ = warmL.withUnsafeMutableBufferPointer { lPtr in
            warmR.withUnsafeMutableBufferPointer { rPtr in
                kernel.renderStereoBlock(
                    leftOutput: lPtr.baseAddress!,
                    rightOutput: rPtr.baseAddress!,
                    frameCount: warmupCount,
                    target: activeParams
                )
            }
        }

        // 2. Render full synthesis timeline in 512-frame DSP blocks with optional Hermite entrainment modulation
        var rawLeft = [Float](repeating: 0, count: totalSynthesisFrames)
        var rawRight = [Float](repeating: 0, count: totalSynthesisFrames)
        let chunkFrames = 512
        var rendered = 0

        while rendered < totalSynthesisFrames {
            let chunk = min(chunkFrames, totalSynthesisFrames - rendered)
            if let ramp = rampSchedule {
                let progress = min(1.0, Double(rendered) / Double(max(1, targetFrames)))
                let splineSample = ramp.sample(at: progress)
                activeParams.carrierFrequencyHz = splineSample.carrierFrequencyHz
                activeParams.binauralBeatHz = splineSample.binauralBeatHz
                activeParams.filterCutoffHz = splineSample.filterCutoffHz
            }

            rawLeft.withUnsafeMutableBufferPointer { lBuf in
                rawRight.withUnsafeMutableBufferPointer { rBuf in
                    _ = kernel.renderStereoBlock(
                        leftOutput: lBuf.baseAddress!.advanced(by: rendered),
                        rightOutput: rBuf.baseAddress!.advanced(by: rendered),
                        frameCount: chunk,
                        target: activeParams
                    )
                }
            }
            rendered += chunk
        }

        // 3. Apply equal-power quarter-sine loop crossfade folding [targetFrames..<totalSynthesisFrames] onto [0..<crossfadeFrames]
        var loopLeft = Array(rawLeft[0..<targetFrames])
        var loopRight = Array(rawRight[0..<targetFrames])

        for k in 0..<crossfadeFrames {
            let phase = (Float(k) / Float(crossfadeFrames)) * (Float.pi * 0.5)
            let headGain = sin(phase)
            let tailGain = cos(phase)
            let tailIndex = targetFrames + k

            loopLeft[k] = min(max(loopLeft[k] * headGain + rawLeft[tailIndex] * tailGain, -1.0), 1.0)
            loopRight[k] = min(max(loopRight[k] * headGain + rawRight[tailIndex] * tailGain, -1.0), 1.0)
        }

        return try WAVBinaryCodec.encodeStereoWAV(
            left: loopLeft,
            right: loopRight,
            sampleRate: sampleRate,
            bitDepth: bitDepth
        )
    }
}
