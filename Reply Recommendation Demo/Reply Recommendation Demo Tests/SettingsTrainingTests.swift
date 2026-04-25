import XCTest
@testable import Reply_Recommendation_Demo

@MainActor
final class SettingsTrainingTests: XCTestCase {
    func testLocalTrainingSettingsPersist() {
        let defaults = makeDefaults()
        let settings = AppSettingsStore(defaults: defaults)
        let adapterURL = temporaryAdapterURL()
        FileManager.default.createFile(atPath: adapterURL.path, contents: Data("adapter".utf8))

        settings.localTrainingEnabled = true
        settings.localTrainingOnboardingCompleted = true
        settings.recordLocalTrainingReport(makeReport(outputAdapterPath: adapterURL.path))

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.localTrainingEnabled)
        XCTAssertTrue(reloaded.localTrainingOnboardingCompleted)
        XCTAssertEqual(reloaded.userTrainedLoraAdapterPath, adapterURL.path)
        XCTAssertEqual(reloaded.lastTrainingFinalLoss, 0.42)
        XCTAssertEqual(reloaded.lastTrainingDurationMs, 1200)
        XCTAssertEqual(reloaded.lastTrainingPeakMemoryMB, 512)
        XCTAssertNotNil(reloaded.lastTrainingCompletedAt)
        XCTAssertTrue(reloaded.userTrainedLoraAdapterAvailable)
    }

    func testPrivateAndBundledLoraAreMutuallyExclusive() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        let adapterURL = temporaryAdapterURL()
        FileManager.default.createFile(atPath: adapterURL.path, contents: Data("adapter".utf8))
        settings.userTrainedLoraAdapterPath = adapterURL.path

        settings.loraAdapterEnabled = true
        settings.userTrainedLoraAdapterEnabled = true

        XCTAssertTrue(settings.userTrainedLoraAdapterEnabled)
        XCTAssertFalse(settings.loraAdapterEnabled)

        settings.loraAdapterEnabled = true

        XCTAssertTrue(settings.loraAdapterEnabled)
        XCTAssertFalse(settings.userTrainedLoraAdapterEnabled)
    }

    func testTrainingViewModelHandlesStartedAndLogEvents() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        let viewModel = TrainingSettingsViewModel(
            settingsStore: settings,
            trainingService: MockLocalTrainingService()
        )
        viewModel.handle(.log(runID: "old", message: "old log", latestStep: nil))

        viewModel.handle(.started(
            runID: "run-1",
            message: "started",
            snapshot: makeSnapshot()
        ))
        viewModel.handle(.log(
            runID: "run-1",
            message: "step",
            latestStep: makeMetric(step: 2, totalSteps: 4, loss: 0.5)
        ))

        XCTAssertEqual(viewModel.status, .running)
        XCTAssertEqual(viewModel.runID, "run-1")
        XCTAssertEqual(viewModel.logs, ["started", "step"])
        XCTAssertEqual(viewModel.progress, 0.5)
        XCTAssertEqual(viewModel.latestStep?.loss, 0.5)
    }

    func testTrainingViewModelCompletedSavesAdapterReport() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        let adapterURL = temporaryAdapterURL()
        FileManager.default.createFile(atPath: adapterURL.path, contents: Data("adapter".utf8))
        let viewModel = TrainingSettingsViewModel(
            settingsStore: settings,
            trainingService: MockLocalTrainingService()
        )
        let report = makeReport(outputAdapterPath: adapterURL.path)

        viewModel.handle(.completed(report))

        XCTAssertEqual(viewModel.status, .completed)
        XCTAssertEqual(settings.userTrainedLoraAdapterPath, adapterURL.path)
        XCTAssertEqual(settings.lastTrainingFinalLoss, 0.42)
        XCTAssertTrue(settings.userTrainedLoraAdapterAvailable)
    }

    func testTrainingViewModelFailedPreservesRecentLogsAndError() {
        let settings = AppSettingsStore(defaults: makeDefaults())
        let viewModel = TrainingSettingsViewModel(
            settingsStore: settings,
            trainingService: MockLocalTrainingService()
        )
        let report = makeReport(success: false, errorCode: 5, logs: ["init", "failed"])

        viewModel.handle(.failed(report))

        XCTAssertEqual(viewModel.status, .failed)
        XCTAssertEqual(viewModel.logs, ["init", "failed"])
        XCTAssertEqual(viewModel.errorMessage, "Training failed with code 5.")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsTrainingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryAdapterURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-demo-\(UUID().uuidString).gguf")
    }

    private func makeReport(
        success: Bool = true,
        errorCode: Int32 = 0,
        outputAdapterPath: String = "/tmp/reply-lora-smoke.gguf",
        logs: [String] = ["done"]
    ) -> LLMTrainingReport {
        LLMTrainingReport(
            runID: "run-1",
            modelResourceName: "Llama-3.2-1B-Instruct-Q4_K_M",
            datasetPath: "/tmp/train.txt",
            outputAdapterPath: outputAdapterPath,
            success: success,
            errorCode: errorCode,
            durationMs: 1200,
            peakMemoryMB: 512,
            memorySamples: [MemorySample(timestamp: Date(), residentMB: 512)],
            thermalSamples: [ThermalSample(timestamp: Date(), state: "nominal", lowPowerModeEnabled: false)],
            appStateEvents: [AppStateEvent(timestamp: Date(), state: "active", protectedDataAvailable: true, note: "test")],
            mainThreadStalls: [],
            stepMetrics: [makeMetric(step: 4, totalSteps: 4, loss: 0.42)],
            logs: logs
        )
    }

    private func makeMetric(step: Int, totalSteps: Int, loss: Double?) -> LLMTrainingStepMetric {
        LLMTrainingStepMetric(
            epoch: 1,
            totalEpochs: 1,
            phase: "train",
            step: step,
            totalSteps: totalSteps,
            observedDurationMs: 100,
            loss: loss,
            accuracyPercent: 90,
            memoryMB: 512,
            thermalState: "nominal",
            appState: "active",
            protectedDataAvailable: true,
            timestamp: Date()
        )
    }

    private func makeSnapshot() -> TrainingMonitorSnapshot {
        TrainingMonitorSnapshot(
            peakMemoryMB: 512,
            memorySamples: [],
            thermalSamples: [],
            appStateEvents: [],
            mainThreadStalls: []
        )
    }
}

private final class MockLocalTrainingService: LocalTrainingServiceProtocol {
    func runConservativeLoRATest(
        samples: [String],
        options: LLMTrainingOptions,
        onEvent: LLMTrainingService.EventHandler?
    ) async throws -> LLMTrainingReport {
        LLMTrainingReport(
            runID: "mock-run",
            modelResourceName: options.modelResourceName,
            datasetPath: "/tmp/train.txt",
            outputAdapterPath: "/tmp/mock.gguf",
            success: true,
            errorCode: 0,
            durationMs: 1,
            peakMemoryMB: 1,
            memorySamples: [],
            thermalSamples: [],
            appStateEvents: [],
            mainThreadStalls: [],
            stepMetrics: [],
            logs: []
        )
    }
}
