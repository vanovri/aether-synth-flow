// MARK: - FILE: Track36CapstoneAuditTests.swift
// Phase 10 Track 36: End-to-End Capstone Benchmark Verification, Perturbation Sensitivity & Cryptographic Digest Audit

import Foundation
import Testing
import simd

@Suite("Track 36 Capstone Benchmark, Perturbation Sensitivity & Cryptographic Audit Tests")
struct Track36CapstoneAuditTests {

    @Test("12-stage Capstone audit executes real mathematical invariants and maps stage status to 10-phase inventory")
    func verifyNonSyntheticExecutionAndSubsystemInventoryMapping() async throws {
        let report = try await AetherCapstoneBenchmarkSuite.runFullAudit()

        #expect(report.totalStageCount == 12)
        #expect(report.passedStageCount == 12)
        #expect(report.allInvariantsPassed)
        #expect(report.verifyCryptographicDigest())
        #expect(report.overallP50Microseconds > 0.0)
        #expect(report.overallP50Microseconds <= report.overallP95Microseconds)
        #expect(report.overallP95Microseconds <= report.overallP99Microseconds)

        // Ensure Stage 5 and Stage 12 report measured numerical invariants rather than static placeholder text
        let stage5 = try #require(report.stages.first(where: { $0.stageIndex == 5 }))
        #expect(stage5.numericalInvariantSummary.contains("RVQ r4/r1="))
        #expect(stage5.numericalInvariantSummary.contains("perp="))

        let stage7 = try #require(report.stages.first(where: { $0.stageIndex == 7 }))
        #expect(stage7.numericalInvariantSummary.contains("PML=-"))
        #expect(stage7.numericalInvariantSummary.contains("AO400/700="))

        let stage12 = try #require(report.stages.first(where: { $0.stageIndex == 12 }))
        #expect(stage12.numericalInvariantSummary.contains("WAV24="))
        #expect(stage12.numericalInvariantSummary.contains("sha:"))

        // Verify that failing Stage 8 flips Phase 9 in buildSubsystemInventory(stages:)
        var modifiedStages = report.stages
        let idx8 = try #require(modifiedStages.firstIndex(where: { $0.stageIndex == 8 }))
        let orig8 = modifiedStages[idx8]
        modifiedStages[idx8] = StageBenchmarkMetrics(
            stageIndex: orig8.stageIndex,
            stageCode: orig8.stageCode,
            title: orig8.title,
            subsystemName: orig8.subsystemName,
            iterations: orig8.iterations,
            p50Microseconds: orig8.p50Microseconds,
            p95Microseconds: orig8.p95Microseconds,
            p99Microseconds: orig8.p99Microseconds,
            throughputSummary: orig8.throughputSummary,
            numericalInvariantSummary: orig8.numericalInvariantSummary,
            invariantPassed: false
        )
        let mappedInventory = AetherCapstoneBenchmarkSuite.buildSubsystemInventory(stages: modifiedStages)
        let phase9Entry = try #require(mappedInventory.first(where: { $0.phaseNumber == 9 }))
        let phase1Entry = try #require(mappedInventory.first(where: { $0.phaseNumber == 1 }))
        #expect(phase9Entry.verified == false)
        #expect(phase1Entry.verified == true)
    }

    @Test("Stages 7, 8, 9, and 10 metrics respond deterministically to physical and biometric input perturbations")
    func verifyStageMetricsSensitivityToInputPerturbations() async {
        let suite = AetherCapstoneBenchmarkSuite.shared
        let baseConfig = CapstoneBenchmarkConfiguration.canonical

        // 1. Stage 7 (FDTD + PML + Caustics): disabling PML absorption (sigma=0) must fail the PML suppression invariant
        var zeroPMLConfig = baseConfig
        zeroPMLConfig.fdtdPMLMaxSigma = 0.0
        let s7Base = await suite.evaluateStage07FDTDAndCaustics(configuration: baseConfig)
        let s7NoPML = await suite.evaluateStage07FDTDAndCaustics(configuration: zeroPMLConfig)
        #expect(s7Base.invariantPassed == true)
        #expect(s7NoPML.invariantPassed == false)
        #expect(s7Base.numericalInvariantSummary != s7NoPML.numericalInvariantSummary)

        // 2. Stage 8 (EEG RLS + Bispectrum + PAC): perturbing target alpha frequency & PAC coupling alters measured summary
        var perturbedEEGConfig = baseConfig
        perturbedEEGConfig.eegTargetAlphaHz = 8.6
        perturbedEEGConfig.eegThetaGammaCoupling = 0.22
        let s8Base = await suite.evaluateStage08EEGAndPAC(configuration: baseConfig)
        let s8Perturbed = await suite.evaluateStage08EEGAndPAC(configuration: perturbedEEGConfig)
        #expect(s8Base.invariantPassed == true)
        #expect(s8Perturbed.invariantPassed == true)
        #expect(s8Base.numericalInvariantSummary != s8Perturbed.numericalInvariantSummary)

        // 3. Stage 9 (SPWVD + HHT/EMD): perturbing multicomponent carrier frequencies alters SPWVD/EMD summary
        var perturbedSPWVDConfig = baseConfig
        perturbedSPWVDConfig.spwvdPrimaryFreqHz = 32.0
        perturbedSPWVDConfig.spwvdSecondaryFreqHz = 9.0
        let s9Base = await suite.evaluateStage09SPWVDAndHHT(configuration: baseConfig)
        let s9Perturbed = await suite.evaluateStage09SPWVDAndHHT(configuration: perturbedSPWVDConfig)
        #expect(s9Base.invariantPassed == true)
        #expect(s9Perturbed.invariantPassed == true)
        #expect(s9Base.numericalInvariantSummary != s9Perturbed.numericalInvariantSummary)

        // 4. Stage 10 (Quantum MPS + 2-Site DMRG): perturbing entanglement coupling & XXZ anisotropy alters energy and entropy
        var perturbedQuantumConfig = baseConfig
        perturbedQuantumConfig.quantumEntanglementCoupling = 0.20
        perturbedQuantumConfig.quantumAnisotropyDelta = 1.45
        let s10Base = await suite.evaluateStage10QuantumMPSDMRG(configuration: baseConfig)
        let s10Perturbed = await suite.evaluateStage10QuantumMPSDMRG(configuration: perturbedQuantumConfig)
        #expect(s10Base.invariantPassed == true)
        #expect(s10Perturbed.invariantPassed == true)
        #expect(s10Base.numericalInvariantSummary != s10Perturbed.numericalInvariantSummary)
    }

    @Test("SHA-256 certification digest is deterministic across runs and detects any stage or inventory tamper")
    func verifySHA256CertificationDigestDeterminismAndTamperRejection() async throws {
        let reportA = try await AetherCapstoneBenchmarkSuite.runFullAudit(configuration: .canonical)
        let reportB = try await AetherCapstoneBenchmarkSuite.runFullAudit(configuration: .canonical)

        #expect(reportA.cryptographicSHA256Digest.count == 64)
        #expect(reportA.cryptographicSHA256Digest == reportB.cryptographicSHA256Digest)
        #expect(reportA.verifyCryptographicDigest())
        #expect(reportB.verifyCryptographicDigest())

        // Perturbed configuration must yield a distinct certification SHA-256 digest
        var altConfig = CapstoneBenchmarkConfiguration.canonical
        altConfig.quantumAnisotropyDelta = 1.35
        let reportAlt = try await AetherCapstoneBenchmarkSuite.runFullAudit(configuration: altConfig)
        #expect(reportAlt.verifyCryptographicDigest())
        #expect(reportAlt.cryptographicSHA256Digest != reportA.cryptographicSHA256Digest)

        // Tamper 1: Mutate a single stage's numericalInvariantSummary without updating the digest
        var tamperedStages = reportA.stages
        let s0 = tamperedStages[0]
        tamperedStages[0] = StageBenchmarkMetrics(
            stageIndex: s0.stageIndex,
            stageCode: s0.stageCode,
            title: s0.title,
            subsystemName: s0.subsystemName,
            iterations: s0.iterations,
            p50Microseconds: s0.p50Microseconds,
            p95Microseconds: s0.p95Microseconds,
            p99Microseconds: s0.p99Microseconds,
            throughputSummary: s0.throughputSummary,
            numericalInvariantSummary: s0.numericalInvariantSummary + " [tampered]",
            invariantPassed: s0.invariantPassed
        )
        let tamperedReport1 = CapstoneAuditReport(
            schemaVersion: reportA.schemaVersion,
            generatedAtISO8601: reportA.generatedAtISO8601,
            totalWallTimeMilliseconds: reportA.totalWallTimeMilliseconds,
            overallP50Microseconds: reportA.overallP50Microseconds,
            overallP95Microseconds: reportA.overallP95Microseconds,
            overallP99Microseconds: reportA.overallP99Microseconds,
            allInvariantsPassed: reportA.allInvariantsPassed,
            passedStageCount: reportA.passedStageCount,
            totalStageCount: reportA.totalStageCount,
            stages: tamperedStages,
            subsystemInventory: reportA.subsystemInventory,
            cryptographicSHA256Digest: reportA.cryptographicSHA256Digest
        )
        #expect(tamperedReport1.verifyCryptographicDigest() == false)

        // Tamper 2: Flip a subsystem inventory verified flag without updating the digest
        var tamperedInventory = reportA.subsystemInventory
        let inv0 = tamperedInventory[0]
        tamperedInventory[0] = SubsystemInventoryEntry(
            phaseNumber: inv0.phaseNumber,
            trackRange: inv0.trackRange,
            moduleName: inv0.moduleName,
            sourcePath: inv0.sourcePath,
            mathematicalCore: inv0.mathematicalCore,
            verified: !inv0.verified
        )
        let tamperedReport2 = CapstoneAuditReport(
            schemaVersion: reportA.schemaVersion,
            generatedAtISO8601: reportA.generatedAtISO8601,
            totalWallTimeMilliseconds: reportA.totalWallTimeMilliseconds,
            overallP50Microseconds: reportA.overallP50Microseconds,
            overallP95Microseconds: reportA.overallP95Microseconds,
            overallP99Microseconds: reportA.overallP99Microseconds,
            allInvariantsPassed: reportA.allInvariantsPassed,
            passedStageCount: reportA.passedStageCount,
            totalStageCount: reportA.totalStageCount,
            stages: reportA.stages,
            subsystemInventory: tamperedInventory,
            cryptographicSHA256Digest: reportA.cryptographicSHA256Digest
        )
        #expect(tamperedReport2.verifyCryptographicDigest() == false)
    }
}
