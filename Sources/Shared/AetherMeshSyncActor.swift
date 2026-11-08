// MARK: - FILE: AetherMeshSyncActor.swift

import Foundation
import CryptoKit
#if canImport(Network)
import Network
#endif

// MARK: - 1. Mesh Peer, Handshake & Encrypted Archive Wire Payloads

public enum MeshSyncError: LocalizedError, Sendable, Equatable {
    case invalidPublicKeyLength(Int)
    case invalidSaltLength(Int)
    case missingPeerSessionKey(String)
    case framePayloadTooLarge(Int)
    case malformedWirePacket

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKeyLength(let count):
            return "Expected 32-byte Curve25519 public key, received \(count) bytes."
        case .invalidSaltLength(let count):
            return "Expected non-empty HKDF salt, received \(count) bytes."
        case .missingPeerSessionKey(let peerID):
            return "No derived E2EE session key established for peer \(peerID)."
        case .framePayloadTooLarge(let count):
            return "Mesh wire frame payload (\(count) bytes) exceeds safety limit."
        case .malformedWirePacket:
            return "Malformed mesh wire packet received."
        }
    }
}

public struct MeshPeerSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String { peerID }
    public let peerID: String
    public let displayName: String
    public let lamportClock: UInt64
    public let isConnected: Bool

    public init(
        peerID: String,
        displayName: String,
        lamportClock: UInt64,
        isConnected: Bool
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.lamportClock = lamportClock
        self.isConnected = isConnected
    }

    public var shortFingerprint: String {
        String(peerID.prefix(8))
    }

    public var lastLamportClock: UInt64 {
        lamportClock
    }

    public var isAuthenticated: Bool {
        isConnected
    }
}

public struct MeshHandshakeHello: Codable, Sendable, Equatable {
    public let peerID: String
    public let displayName: String
    public let ephemeralPublicKeyRaw: Data
    public let hkdfSalt: Data
    public let lamportClock: UInt64

    public init(
        peerID: String,
        displayName: String,
        ephemeralPublicKeyRaw: Data,
        hkdfSalt: Data,
        lamportClock: UInt64
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.ephemeralPublicKeyRaw = ephemeralPublicKeyRaw
        self.hkdfSalt = hkdfSalt
        self.lamportClock = lamportClock
    }
}

public struct MeshEncryptedArchiveEnvelope: Codable, Sendable, Equatable {
    public let senderPeerID: String
    public let lamportClock: UInt64
    public let sealedBoxCombined: Data

    public init(
        senderPeerID: String,
        lamportClock: UInt64,
        sealedBoxCombined: Data
    ) {
        self.senderPeerID = senderPeerID
        self.lamportClock = lamportClock
        self.sealedBoxCombined = sealedBoxCombined
    }
}

// MARK: - 2. Deterministic ECDH + HKDF-SHA256 + ChaCha20-Poly1305 Crypto & Framing

public struct MeshCryptoSession: Sendable {
    public static let maxFramePayloadBytes: Int = 32 * 1024 * 1024

    public static func makeKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    public static func makeRandomSalt(byteCount: Int = 16) -> Data {
        let safeCount = max(16, byteCount)
        let key = SymmetricKey(size: .bits256)
        let rawBytes = key.withUnsafeBytes { Data($0) }
        if safeCount <= rawBytes.count {
            return rawBytes.prefix(safeCount)
        }
        var output = Data(capacity: safeCount)
        while output.count < safeCount {
            let chunk = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            output.append(chunk.prefix(safeCount - output.count))
        }
        return output
    }

    /// Deterministically combines two peers' handshake salts in lexicographical order so both sides
    /// feed the exact same 16-byte salt into `deriveSymmetricKey`.
    public static func combineHandshakeSalts(_ first: Data, _ second: Data) -> Data {
        let ordered = first.lexicographicallyPrecedes(second) ? (first, second) : (second, first)
        var combined = Data("AetherMeshSalt.v1|".utf8)
        combined.append(ordered.0)
        combined.append(0x7C)
        combined.append(ordered.1)
        let digest = SHA256.hash(data: combined)
        return Data(digest.prefix(16))
    }

    /// Performs X25519 ECDH key agreement + `HKDF<SHA256>` with sorted public-key context info
    /// so initiator and responder deterministically derive the identical 256-bit `SymmetricKey`.
    public static func deriveSymmetricKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyRaw: Data,
        hkdfSalt: Data
    ) throws -> SymmetricKey {
        guard peerPublicKeyRaw.count == 32 else {
            throw MeshSyncError.invalidPublicKeyLength(peerPublicKeyRaw.count)
        }
        guard !hkdfSalt.isEmpty else {
            throw MeshSyncError.invalidSaltLength(0)
        }

        let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyRaw)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

        let localPublicKeyRaw = privateKey.publicKey.rawRepresentation
        let sortedPair: (Data, Data) = localPublicKeyRaw.lexicographicallyPrecedes(peerPublicKeyRaw)
            ? (localPublicKeyRaw, peerPublicKeyRaw)
            : (peerPublicKeyRaw, localPublicKeyRaw)

        var contextInfo = Data("AetherMeshSync.ECDH.HKDF.v1|".utf8)
        contextInfo.append(sortedPair.0)
        contextInfo.append(0x7C)
        contextInfo.append(sortedPair.1)

        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: contextInfo,
            outputByteCount: 32
        )
    }

    /// Encrypts `AetherTelemetryArchive` with ChaCha20-Poly1305 AEAD, authenticating
    /// `senderPeerID` + big-endian `lamportClock` as Associated Authenticated Data (AAD).
    public static func sealArchive(
        _ archive: AetherTelemetryArchive,
        senderPeerID: String,
        lamportClock: UInt64,
        key: SymmetricKey
    ) throws -> MeshEncryptedArchiveEnvelope {
        try archive.validateIntegrity()
        let plaintext = try archive.encodePrettyJSON()
        let aad = makeAuthenticatedData(senderPeerID: senderPeerID, lamportClock: lamportClock)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        return MeshEncryptedArchiveEnvelope(
            senderPeerID: senderPeerID,
            lamportClock: lamportClock,
            sealedBoxCombined: sealedBox.combined
        )
    }

    /// Verifies ChaCha20-Poly1305 AEAD tag + AAD (`senderPeerID` + big-endian `lamportClock`)
    /// and validates the inner `AetherTelemetryArchive` FNV-1a integrity digest.
    public static func openArchive(
        _ envelope: MeshEncryptedArchiveEnvelope,
        key: SymmetricKey
    ) throws -> AetherTelemetryArchive {
        let sealedBox = try ChaChaPoly.SealedBox(combined: envelope.sealedBoxCombined)
        let aad = makeAuthenticatedData(
            senderPeerID: envelope.senderPeerID,
            lamportClock: envelope.lamportClock
        )
        let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
        return try AetherTelemetryArchive.decodeAndValidate(from: plaintext)
    }

    /// Encodes a payload with a 4-byte big-endian `UInt32` length header.
    public static func encodeLengthPrefixedFrame(_ payload: Data) -> Data {
        let countUInt32 = UInt32(clamping: payload.count)
        var frame = Data(capacity: 4 + payload.count)
        frame.append(UInt8((countUInt32 >> 24) & 0xFF))
        frame.append(UInt8((countUInt32 >> 16) & 0xFF))
        frame.append(UInt8((countUInt32 >> 8) & 0xFF))
        frame.append(UInt8(countUInt32 & 0xFF))
        frame.append(payload)
        return frame
    }

    /// Extracts all complete 4-byte big-endian length-prefixed frames from `buffer`,
    /// preserving any trailing partial bytes in `buffer` for subsequent TCP reads.
    public static func extractLengthPrefixedFrames(from buffer: inout Data) -> [Data] {
        var extracted: [Data] = []
        var cursor = buffer.startIndex
        let end = buffer.endIndex

        while end - cursor >= 4 {
            let b0 = UInt32(buffer[cursor])
            let b1 = UInt32(buffer[cursor + 1])
            let b2 = UInt32(buffer[cursor + 2])
            let b3 = UInt32(buffer[cursor + 3])
            let payloadLength = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)

            if payloadLength > maxFramePayloadBytes {
                // Reset corrupted oversized stream buffer safely
                buffer.removeAll(keepingCapacity: false)
                return extracted
            }

            let requiredEnd = cursor + 4 + payloadLength
            guard requiredEnd <= end else {
                break
            }

            let payload = Data(buffer[(cursor + 4)..<requiredEnd])
            extracted.append(payload)
            cursor = requiredEnd
        }

        if cursor > buffer.startIndex {
            if cursor == end {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer = Data(buffer[cursor..<end])
            }
        }

        return extracted
    }

    private static func makeAuthenticatedData(senderPeerID: String, lamportClock: UInt64) -> Data {
        var aad = Data("AetherMeshAEAD.v1|".utf8)
        aad.append(contentsOf: senderPeerID.utf8)
        aad.append(0x7C)
        var bigEndianClock = lamportClock.bigEndian
        withUnsafeBytes(of: &bigEndianClock) { rawBuf in
            aad.append(contentsOf: rawBuf)
        }
        return aad
    }
}

// MARK: - 3. Internal Wire Packet Codec

private enum MeshWirePacket: Codable, Sendable {
    case hello(MeshHandshakeHello)
    case encryptedArchive(MeshEncryptedArchiveEnvelope)
}

// MARK: - 4. Bonjour P2P Mesh Synchronization Actor

public actor AetherMeshSyncActor {
    public static let bonjourServiceType = "_aethersynth._tcp"

    public let peerID: String
    private let databaseActor: TelemetryDatabaseActor
    private var localDisplayName: String
    private var lamportClock: UInt64
    private var isMeshActive: Bool = false

    private struct ConnectionSecurityContext {
        let connectionID: UUID
        let localPrivateKey: Curve25519.KeyAgreement.PrivateKey
        let localSalt: Data
        var remotePeerID: String?
        var remoteDisplayName: String?
        var symmetricKey: SymmetricKey?
    }

    private var connectionContexts: [UUID: ConnectionSecurityContext] = [:]
    private var activeConnectionByPeerID: [String: UUID] = [:]
    private var peersByID: [String: MeshPeerSummary] = [:]

    #if canImport(Network)
    private var networkRelay: BonjourMeshNetworkRelay?
    #endif

    public init(
        databaseActor: TelemetryDatabaseActor,
        peerID: String = UUID().uuidString,
        displayName: String = "AetherNode",
        initialLamportClock: UInt64 = 1
    ) {
        self.databaseActor = databaseActor
        self.peerID = peerID
        self.localDisplayName = displayName
        self.lamportClock = max(1, initialLamportClock)
    }

    public init(
        databaseActor: TelemetryDatabaseActor,
        localPeerName: String
    ) {
        self.init(
            databaseActor: databaseActor,
            displayName: localPeerName
        )
    }

    public func startMesh(displayName: String) {
        let sanitizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localDisplayName = sanitizedName.isEmpty ? "AetherNode" : sanitizedName
        guard !isMeshActive else { return }
        isMeshActive = true

        #if canImport(Network)
        let relay = BonjourMeshNetworkRelay(
            localServiceName: peerID,
            serviceType: Self.bonjourServiceType,
            onConnectionReady: { [weak self] connID in
                Task { await self?.handleTransportConnectionReady(connectionID: connID) }
            },
            onFrameReceived: { [weak self] connID, framePayload in
                Task { await self?.handleTransportFrame(connectionID: connID, payload: framePayload) }
            },
            onConnectionClosed: { [weak self] connID in
                Task { await self?.handleTransportConnectionClosed(connectionID: connID) }
            },
            onPeerServiceDiscovered: { [weak self] serviceName in
                Task { await self?.handleDiscoveredServiceName(serviceName) }
            }
        )
        self.networkRelay = relay
        relay.start()
        #endif
    }

    public func stopMesh() {
        isMeshActive = false

        #if canImport(Network)
        networkRelay?.stop()
        networkRelay = nil
        #endif

        connectionContexts.removeAll()
        activeConnectionByPeerID.removeAll()

        for (id, summary) in peersByID {
            peersByID[id] = MeshPeerSummary(
                peerID: summary.peerID,
                displayName: summary.displayName,
                lamportClock: summary.lamportClock,
                isConnected: false
            )
        }
    }

    /// Broadcasts an E2EE-sealed snapshot of the local ledger to all currently authenticated mesh peers.
    /// Returns the number of peers to which the encrypted archive was dispatched.
    @discardableResult
    public func broadcastSyncNow() async throws -> Int {
        lamportClock &+= 1
        let broadcastClock = lamportClock
        let archive = try await databaseActor.exportFullArchive()

        var sentCount = 0
        let encoder = JSONEncoder()

        for (remotePeerID, connID) in activeConnectionByPeerID {
            guard let context = connectionContexts[connID],
                  let key = context.symmetricKey else {
                continue
            }

            let envelope = try MeshCryptoSession.sealArchive(
                archive,
                senderPeerID: peerID,
                lamportClock: broadcastClock,
                key: key
            )
            let packetData = try encoder.encode(MeshWirePacket.encryptedArchive(envelope))
            let framed = MeshCryptoSession.encodeLengthPrefixedFrame(packetData)

            #if canImport(Network)
            networkRelay?.sendFramedData(framed, to: connID)
            #endif
            sentCount += 1
            _ = remotePeerID
        }

        return sentCount
    }

    public func snapshotPeers() -> [MeshPeerSummary] {
        peersByID.values.sorted { $0.peerID < $1.peerID }
    }

    public func currentLamportClock() -> UInt64 {
        lamportClock
    }

    public func startBonjourMesh(displayName: String = "AetherNode") {
        startMesh(displayName: displayName)
    }

    public func stopBonjourMesh() {
        stopMesh()
    }

    public func snapshotMeshStatus() -> (isListening: Bool, lamportClock: UInt64, peers: [MeshPeerSummary]) {
        (isMeshActive, lamportClock, snapshotPeers())
    }

    public func broadcastEncryptedArchiveToAllPeers() async -> Int {
        (try? await broadcastSyncNow()) ?? 0
    }

    /// Deterministic in-memory peer exchange helper enabling full E2EE handshake + Lamport clock + SwiftData CRDT
    /// verification without requiring multicast Bonjour sockets in sandboxed test environments.
    @discardableResult
    public func exchangeDirectEncryptedSync(with remotePeer: AetherMeshSyncActor) async throws -> ArchiveImportSummary {
        let localPriv = MeshCryptoSession.makeKeyPair()
        let localSalt = MeshCryptoSession.makeRandomSalt(byteCount: 16)
        lamportClock &+= 1
        let localHello = MeshHandshakeHello(
            peerID: peerID,
            displayName: localDisplayName,
            ephemeralPublicKeyRaw: localPriv.publicKey.rawRepresentation,
            hkdfSalt: localSalt,
            lamportClock: lamportClock
        )

        let (remoteHello, remoteEnvelope) = try await remotePeer.acceptDirectHandshakeAndExport(initiatorHello: localHello)
        lamportClock = max(lamportClock, remoteHello.lamportClock) + 1

        let sharedSalt = MeshCryptoSession.combineHandshakeSalts(localHello.hkdfSalt, remoteHello.hkdfSalt)
        let sessionKey = try MeshCryptoSession.deriveSymmetricKey(
            privateKey: localPriv,
            peerPublicKeyRaw: remoteHello.ephemeralPublicKeyRaw,
            hkdfSalt: sharedSalt
        )

        let localArchive = try await databaseActor.exportFullArchive()
        lamportClock &+= 1
        let localEnvelope = try MeshCryptoSession.sealArchive(
            localArchive,
            senderPeerID: peerID,
            lamportClock: lamportClock,
            key: sessionKey
        )
        let remoteSummary = try await remotePeer.ingestDirectEncryptedEnvelope(
            localEnvelope,
            initiatorHello: localHello,
            responderSalt: remoteHello.hkdfSalt,
            sessionKey: sessionKey
        )

        let openedRemote = try MeshCryptoSession.openArchive(remoteEnvelope, key: sessionKey)
        lamportClock = max(lamportClock, remoteEnvelope.lamportClock) + 1
        peersByID[remoteHello.peerID] = MeshPeerSummary(
            peerID: remoteHello.peerID,
            displayName: remoteHello.displayName,
            lamportClock: remoteEnvelope.lamportClock,
            isConnected: true
        )

        let localSummary = try await databaseActor.importFullArchive(openedRemote, conflictPolicy: .higherRevisionWins)
        return ArchiveImportSummary(
            importedHabits: localSummary.importedHabits + remoteSummary.importedHabits,
            importedPresets: localSummary.importedPresets + remoteSummary.importedPresets,
            sessionReport: BatchIngestReport(
                insertedSessions: localSummary.sessionReport.insertedSessions + remoteSummary.sessionReport.insertedSessions,
                updatedSessions: localSummary.sessionReport.updatedSessions + remoteSummary.sessionReport.updatedSessions,
                skippedSessions: localSummary.sessionReport.skippedSessions + remoteSummary.sessionReport.skippedSessions,
                affectedTelemetryDays: localSummary.sessionReport.affectedTelemetryDays + remoteSummary.sessionReport.affectedTelemetryDays,
                updatedHabits: localSummary.sessionReport.updatedHabits + remoteSummary.sessionReport.updatedHabits
            ),
            upsertedTelemetryDays: localSummary.upsertedTelemetryDays + remoteSummary.upsertedTelemetryDays
        )
    }

    private func acceptDirectHandshakeAndExport(
        initiatorHello: MeshHandshakeHello
    ) async throws -> (MeshHandshakeHello, MeshEncryptedArchiveEnvelope) {
        let responderPriv = MeshCryptoSession.makeKeyPair()
        let responderSalt = MeshCryptoSession.makeRandomSalt(byteCount: 16)
        lamportClock = max(lamportClock, initiatorHello.lamportClock) + 1

        let responderHello = MeshHandshakeHello(
            peerID: peerID,
            displayName: localDisplayName,
            ephemeralPublicKeyRaw: responderPriv.publicKey.rawRepresentation,
            hkdfSalt: responderSalt,
            lamportClock: lamportClock
        )

        let sharedSalt = MeshCryptoSession.combineHandshakeSalts(initiatorHello.hkdfSalt, responderSalt)
        let sessionKey = try MeshCryptoSession.deriveSymmetricKey(
            privateKey: responderPriv,
            peerPublicKeyRaw: initiatorHello.ephemeralPublicKeyRaw,
            hkdfSalt: sharedSalt
        )

        let archive = try await databaseActor.exportFullArchive()
        lamportClock &+= 1
        let envelope = try MeshCryptoSession.sealArchive(
            archive,
            senderPeerID: peerID,
            lamportClock: lamportClock,
            key: sessionKey
        )

        peersByID[initiatorHello.peerID] = MeshPeerSummary(
            peerID: initiatorHello.peerID,
            displayName: initiatorHello.displayName,
            lamportClock: initiatorHello.lamportClock,
            isConnected: true
        )
        return (responderHello, envelope)
    }

    private func ingestDirectEncryptedEnvelope(
        _ envelope: MeshEncryptedArchiveEnvelope,
        initiatorHello: MeshHandshakeHello,
        responderSalt: Data,
        sessionKey: SymmetricKey
    ) async throws -> ArchiveImportSummary {
        _ = responderSalt
        let archive = try MeshCryptoSession.openArchive(envelope, key: sessionKey)
        lamportClock = max(lamportClock, envelope.lamportClock) + 1
        peersByID[initiatorHello.peerID] = MeshPeerSummary(
            peerID: initiatorHello.peerID,
            displayName: initiatorHello.displayName,
            lamportClock: envelope.lamportClock,
            isConnected: true
        )
        return try await databaseActor.importFullArchive(archive, conflictPolicy: .higherRevisionWins)
    }

    // MARK: - Internal Transport Event Handlers

    private func handleDiscoveredServiceName(_ serviceName: String) {
        guard serviceName != peerID else { return }
        if peersByID[serviceName] == nil {
            peersByID[serviceName] = MeshPeerSummary(
                peerID: serviceName,
                displayName: serviceName,
                lamportClock: 0,
                isConnected: false
            )
        }
    }

    private func handleTransportConnectionReady(connectionID: UUID) {
        guard isMeshActive else { return }
        let privKey = MeshCryptoSession.makeKeyPair()
        let localSalt = MeshCryptoSession.makeRandomSalt(byteCount: 16)
        lamportClock &+= 1

        let context = ConnectionSecurityContext(
            connectionID: connectionID,
            localPrivateKey: privKey,
            localSalt: localSalt,
            remotePeerID: nil,
            remoteDisplayName: nil,
            symmetricKey: nil
        )
        connectionContexts[connectionID] = context

        let hello = MeshHandshakeHello(
            peerID: peerID,
            displayName: localDisplayName,
            ephemeralPublicKeyRaw: privKey.publicKey.rawRepresentation,
            hkdfSalt: localSalt,
            lamportClock: lamportClock
        )

        guard let encoded = try? JSONEncoder().encode(MeshWirePacket.hello(hello)) else { return }
        let framed = MeshCryptoSession.encodeLengthPrefixedFrame(encoded)
        #if canImport(Network)
        networkRelay?.sendFramedData(framed, to: connectionID)
        #endif
    }

    private func handleTransportFrame(connectionID: UUID, payload: Data) async {
        guard isMeshActive,
              let packet = try? JSONDecoder().decode(MeshWirePacket.self, from: payload) else {
            return
        }

        switch packet {
        case .hello(let remoteHello):
            await processHandshakeHello(remoteHello, on: connectionID)
        case .encryptedArchive(let envelope):
            await processEncryptedEnvelope(envelope, on: connectionID)
        }
    }

    private func processHandshakeHello(_ remoteHello: MeshHandshakeHello, on connectionID: UUID) async {
        guard remoteHello.peerID != peerID else {
            #if canImport(Network)
            networkRelay?.closeConnection(connectionID)
            #endif
            connectionContexts.removeValue(forKey: connectionID)
            return
        }

        guard var context = connectionContexts[connectionID] else { return }

        lamportClock = max(lamportClock, remoteHello.lamportClock) + 1
        let combinedSalt = MeshCryptoSession.combineHandshakeSalts(context.localSalt, remoteHello.hkdfSalt)

        guard let derivedKey = try? MeshCryptoSession.deriveSymmetricKey(
            privateKey: context.localPrivateKey,
            peerPublicKeyRaw: remoteHello.ephemeralPublicKeyRaw,
            hkdfSalt: combinedSalt
        ) else {
            #if canImport(Network)
            networkRelay?.closeConnection(connectionID)
            #endif
            connectionContexts.removeValue(forKey: connectionID)
            return
        }

        context.remotePeerID = remoteHello.peerID
        context.remoteDisplayName = remoteHello.displayName
        context.symmetricKey = derivedKey
        connectionContexts[connectionID] = context
        activeConnectionByPeerID[remoteHello.peerID] = connectionID

        peersByID[remoteHello.peerID] = MeshPeerSummary(
            peerID: remoteHello.peerID,
            displayName: remoteHello.displayName,
            lamportClock: remoteHello.lamportClock,
            isConnected: true
        )

        // Immediately push encrypted archive upon completing ECDH key agreement
        guard let localArchive = try? await databaseActor.exportFullArchive() else { return }
        lamportClock &+= 1
        guard let envelope = try? MeshCryptoSession.sealArchive(
            localArchive,
            senderPeerID: peerID,
            lamportClock: lamportClock,
            key: derivedKey
        ),
        let packetBytes = try? JSONEncoder().encode(MeshWirePacket.encryptedArchive(envelope)) else {
            return
        }

        let framed = MeshCryptoSession.encodeLengthPrefixedFrame(packetBytes)
        #if canImport(Network)
        networkRelay?.sendFramedData(framed, to: connectionID)
        #endif
    }

    private func processEncryptedEnvelope(_ envelope: MeshEncryptedArchiveEnvelope, on connectionID: UUID) async {
        guard let context = connectionContexts[connectionID],
              let key = context.symmetricKey,
              let remoteArchive = try? MeshCryptoSession.openArchive(envelope, key: key) else {
            return
        }

        lamportClock = max(lamportClock, envelope.lamportClock) + 1
        let remoteID = context.remotePeerID ?? envelope.senderPeerID
        let remoteName = context.remoteDisplayName ?? remoteID

        peersByID[remoteID] = MeshPeerSummary(
            peerID: remoteID,
            displayName: remoteName,
            lamportClock: envelope.lamportClock,
            isConnected: true
        )

        _ = try? await databaseActor.importFullArchive(
            remoteArchive,
            conflictPolicy: .higherRevisionWins
        )
    }

    private func handleTransportConnectionClosed(connectionID: UUID) {
        if let context = connectionContexts.removeValue(forKey: connectionID),
           let remoteID = context.remotePeerID {
            if activeConnectionByPeerID[remoteID] == connectionID {
                activeConnectionByPeerID.removeValue(forKey: remoteID)
            }
            if let existing = peersByID[remoteID] {
                peersByID[remoteID] = MeshPeerSummary(
                    peerID: existing.peerID,
                    displayName: existing.displayName,
                    lamportClock: existing.lamportClock,
                    isConnected: activeConnectionByPeerID[remoteID] != nil
                )
            }
        }
    }
}

// MARK: - 5. Serial-Queue Isolated Network.framework Bonjour Relay

#if canImport(Network)
private final class BonjourMeshNetworkRelay: @unchecked Sendable {
    private let localServiceName: String
    private let serviceType: String
    private let ioQueue: DispatchQueue

    private let onConnectionReady: @Sendable (UUID) -> Void
    private let onFrameReceived: @Sendable (UUID, Data) -> Void
    private let onConnectionClosed: @Sendable (UUID) -> Void
    private let onPeerServiceDiscovered: @Sendable (String) -> Void

    private final class WirePeerSlot {
        let id: UUID
        let connection: NWConnection
        let endpointKey: String?
        var receiveBuffer: Data = Data()
        var didNotifyReady: Bool = false

        init(id: UUID, connection: NWConnection, endpointKey: String?) {
            self.id = id
            self.connection = connection
            self.endpointKey = endpointKey
        }
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var slots: [UUID: WirePeerSlot] = [:]
    private var dialedEndpointKeys: Set<String> = []
    private var isRunning: Bool = false

    init(
        localServiceName: String,
        serviceType: String,
        onConnectionReady: @escaping @Sendable (UUID) -> Void,
        onFrameReceived: @escaping @Sendable (UUID, Data) -> Void,
        onConnectionClosed: @escaping @Sendable (UUID) -> Void,
        onPeerServiceDiscovered: @escaping @Sendable (String) -> Void
    ) {
        self.localServiceName = localServiceName
        self.serviceType = serviceType
        self.ioQueue = DispatchQueue(label: "com.aethersynth.flow.mesh.io.\(UUID().uuidString)")
        self.onConnectionReady = onConnectionReady
        self.onFrameReceived = onFrameReceived
        self.onConnectionClosed = onConnectionClosed
        self.onPeerServiceDiscovered = onPeerServiceDiscovered
    }

    func start() {
        ioQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        ioQueue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    func sendFramedData(_ framedData: Data, to connectionID: UUID) {
        ioQueue.async { [weak self] in
            guard let self, let slot = self.slots[connectionID] else { return }
            slot.connection.send(
                content: framedData,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.teardownSlotOnQueue(connectionID)
                    }
                }
            )
        }
    }

    func closeConnection(_ connectionID: UUID) {
        ioQueue.async { [weak self] in
            self?.teardownSlotOnQueue(connectionID)
        }
    }

    private static func makeTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
        return params
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true

        let params = Self.makeTCPParameters()

        if let createdListener = try? NWListener(using: params) {
            createdListener.service = NWListener.Service(name: localServiceName, type: serviceType)
            createdListener.newConnectionHandler = { [weak self] incomingConnection in
                self?.registerConnectionOnQueue(incomingConnection, endpointKey: nil)
            }
            createdListener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                }
            }
            createdListener.start(queue: ioQueue)
            self.listener = createdListener
        }

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let createdBrowser = NWBrowser(for: descriptor, using: params)
        createdBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResultsOnQueue(results)
        }
        createdBrowser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel()
            }
        }
        createdBrowser.start(queue: ioQueue)
        self.browser = createdBrowser
    }

    private func stopOnQueue() {
        isRunning = false
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil

        let activeIDs = Array(slots.keys)
        for id in activeIDs {
            if let slot = slots.removeValue(forKey: id) {
                slot.connection.cancel()
            }
        }
        dialedEndpointKeys.removeAll()
    }

    private func handleBrowseResultsOnQueue(_ results: Set<NWBrowser.Result>) {
        guard isRunning else { return }
        for result in results {
            if case let .service(name, type, domain, _) = result.endpoint {
                guard name != localServiceName else { continue }
                onPeerServiceDiscovered(name)

                // Deterministic tie-breaker: lexicographically lower peerID initiates outbound dial
                // to prevent duplicate simultaneous TCP streams between two discovering peers.
                guard localServiceName < name else { continue }
                let endpointKey = "\(name).\(type).\(domain)"
                guard !dialedEndpointKeys.contains(endpointKey) else { continue }
                dialedEndpointKeys.insert(endpointKey)

                let outbound = NWConnection(to: result.endpoint, using: Self.makeTCPParameters())
                registerConnectionOnQueue(outbound, endpointKey: endpointKey)
            }
        }
    }

    private func registerConnectionOnQueue(_ connection: NWConnection, endpointKey: String?) {
        guard isRunning else {
            connection.cancel()
            return
        }

        let connID = UUID()
        let slot = WirePeerSlot(id: connID, connection: connection, endpointKey: endpointKey)
        slots[connID] = slot

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let currentSlot = self.slots[connID], !currentSlot.didNotifyReady else { return }
                currentSlot.didNotifyReady = true
                self.onConnectionReady(connID)
                self.receiveNextChunkOnQueue(connectionID: connID)
            case .failed, .cancelled:
                self.teardownSlotOnQueue(connID)
            default:
                break
            }
        }

        connection.start(queue: ioQueue)
    }

    private func receiveNextChunkOnQueue(connectionID: UUID) {
        guard isRunning, let slot = slots[connectionID] else { return }

        slot.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self, let activeSlot = self.slots[connectionID] else { return }

            if let content, !content.isEmpty {
                activeSlot.receiveBuffer.append(content)
                let frames = MeshCryptoSession.extractLengthPrefixedFrames(from: &activeSlot.receiveBuffer)
                for frame in frames {
                    self.onFrameReceived(connectionID, frame)
                }
            }

            if error != nil || isComplete {
                self.teardownSlotOnQueue(connectionID)
            } else {
                self.receiveNextChunkOnQueue(connectionID: connectionID)
            }
        }
    }

    private func teardownSlotOnQueue(_ connectionID: UUID) {
        guard let removed = slots.removeValue(forKey: connectionID) else { return }
        if let key = removed.endpointKey {
            dialedEndpointKeys.remove(key)
        }
        removed.connection.cancel()
        onConnectionClosed(connectionID)
    }
}
#endif
