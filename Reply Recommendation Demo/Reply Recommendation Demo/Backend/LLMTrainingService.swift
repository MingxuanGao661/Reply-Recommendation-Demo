import Foundation
import QuartzCore
import UIKit

/// Minimal on-device LoRA training harness for conservative smoke tests.
///
/// This service intentionally keeps the Swift layer thin: QVAC's Objective-C++
/// bridge owns the native llama.cpp/ggml training loop, while Swift owns app
/// concerns such as file paths, progress events, memory sampling, thermal state,
/// foreground/background tracking, and main-thread stall detection.
final class LLMTrainingService {
    typealias EventHandler = @Sendable (LLMTrainingEvent) -> Void

    private let bundle: Bundle
    private let fileManager: FileManager
    private let trainingQueue = DispatchQueue(
        label: "reply-demo.local-lora-training",
        qos: .utility
    )

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
    }

    /// Runs a very small LoRA finetuning smoke test against a Llama 3.2 1B GGUF.
    ///
    /// Frontend receives:
    /// - repeated `LLMTrainingEvent` values via `onEvent`
    /// - one final `LLMTrainingReport` return value when training exits
    func runConservativeLoRATest(
        samples: [String],
        options: LLMTrainingOptions = .conservativeLlama32OneB(),
        onEvent: EventHandler? = nil
    ) async throws -> LLMTrainingReport {
        try await withCheckedThrowingContinuation { continuation in
            trainingQueue.async {
                do {
                    let report = try self.runBlocking(
                        samples: samples,
                        options: options,
                        onEvent: onEvent
                    )
                    continuation.resume(returning: report)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBlocking(
        samples: [String],
        options: LLMTrainingOptions,
        onEvent: EventHandler?
    ) throws -> LLMTrainingReport {
        guard !Thread.isMainThread else {
            throw LLMTrainingError.refusingToTrainOnMainThread
        }
        guard !samples.isEmpty else {
            throw LLMTrainingError.emptyDataset
        }
        guard let modelPath = modelPath(for: options.modelResourceName) else {
            throw LLMTrainingError.modelMissing(options.modelResourceName)
        }

        let runID = Self.timestampID()
        let runDirectory = try makeRunDirectory(runID: runID)
        let datasetURL = runDirectory.appendingPathComponent("train.txt")
        let adapterURL = runDirectory.appendingPathComponent(options.outputAdapterFileName)
        try writeDataset(samples, to: datasetURL)

        let monitor = TrainingRuntimeMonitor()
        monitor.start()
        defer { monitor.stop() }

        let logBox = TrainingLogBox(
            runID: runID,
            options: options,
            onEvent: onEvent
        )

        onEvent?(.started(
            runID: runID,
            message: "Starting conservative LoRA training smoke test.",
            snapshot: monitor.snapshot()
        ))

        var nativeOptions = llama_swift_finetune_options()
        nativeOptions.n_ctx = options.contextSize
        nativeOptions.n_threads = options.threadCount
        nativeOptions.n_batch = options.batchSize
        nativeOptions.n_ubatch = options.microBatchSize
        nativeOptions.epochs = options.epochs
        nativeOptions.lora_rank = options.loraRank
        nativeOptions.lora_alpha = options.loraAlpha
        nativeOptions.learning_rate = options.learningRate
        nativeOptions.val_split = options.validationSplit
        nativeOptions.target_modules = options.targetModules
        nativeOptions.seed = options.seed
        nativeOptions.flash_attn = options.flashAttention
        nativeOptions.n_gpu_layers = options.gpuLayers

        let startTime = CACurrentMediaTime()
        let unmanaged = Unmanaged.passRetained(logBox)
        let result = modelPath.withCString { modelCString in
            datasetURL.path.withCString { datasetCString in
                adapterURL.path.withCString { adapterCString in
                    llama_swift_run_lora_finetune(
                        modelCString,
                        datasetCString,
                        adapterCString,
                        &nativeOptions,
                        { message, userData in
                            guard let userData else { return }
                            let box = Unmanaged<TrainingLogBox>
                                .fromOpaque(userData)
                                .takeUnretainedValue()
                            let line = message.map(String.init(cString:)) ?? ""
                            box.receiveLog(line)
                        },
                        unmanaged.toOpaque()
                    )
                }
            }
        }
        unmanaged.release()

        let durationMs = (CACurrentMediaTime() - startTime) * 1000
        let snapshot = monitor.snapshot()
        let success = result == LLAMA_SWIFT_FINETUNE_OK
        let report = LLMTrainingReport(
            runID: runID,
            modelResourceName: options.modelResourceName,
            datasetPath: datasetURL.path,
            outputAdapterPath: adapterURL.path,
            success: success,
            errorCode: Int32(result.rawValue),
            durationMs: durationMs,
            peakMemoryMB: snapshot.peakMemoryMB,
            memorySamples: snapshot.memorySamples,
            thermalSamples: snapshot.thermalSamples,
            appStateEvents: snapshot.appStateEvents,
            mainThreadStalls: snapshot.mainThreadStalls,
            stepMetrics: logBox.stepMetrics,
            logs: logBox.logs
        )

        if success {
            onEvent?(.completed(report))
            return report
        } else {
            onEvent?(.failed(report))
            throw LLMTrainingError.nativeTrainingFailed(
                code: Int32(result.rawValue),
                report: report
            )
        }
    }

    private func modelPath(for preferredName: String) -> String? {
        let candidates = [
            preferredName,
            "Llama-3.2-1B-Instruct-Q4_K_M",
            "Llama-3.2-1B-Instruct-Q4_0",
            "Llama-3.2-1B-Instruct"
        ]
        for name in candidates {
            if let path = bundle.path(forResource: name, ofType: "gguf") {
                return path
            }
        }
        return nil
    }

    private func makeRunDirectory(runID: String) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("LoRATraining", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeDataset(_ samples: [String], to url: URL) throws {
        let cleaned = samples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw LLMTrainingError.emptyDataset
        }

        // QVAC's bridge tokenizes one plain-text file and creates shifted
        // next-token labels. Keep sample separation explicit but simple.
        let text = cleaned.joined(separator: "\n\n<|end_of_text|>\n\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func timestampID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct LLMTrainingOptions: Codable, Equatable, Sendable {
    var modelResourceName: String
    var outputAdapterFileName: String
    var contextSize: Int32
    var threadCount: Int32
    var batchSize: Int32
    var microBatchSize: Int32
    var epochs: Int32
    var loraRank: Int32
    var loraAlpha: Float
    var learningRate: Float
    var validationSplit: Float
    var targetModules: UInt32
    var seed: Int32
    var flashAttention: Bool
    var gpuLayers: Int32

    static func conservativeLlama32OneB() -> Self {
        Self(
            modelResourceName: "Llama-3.2-1B-Instruct-Q4_K_M",
            outputAdapterFileName: "reply-lora-smoke.gguf",
            contextSize: 256,
            threadCount: 2,
            batchSize: 32,
            microBatchSize: 16,
            epochs: 1,
            loraRank: 4,
            loraAlpha: 8,
            learningRate: 0.00001,
            validationSplit: 0,
            targetModules: 0,
            seed: 42,
            flashAttention: false,
            gpuLayers: 999
        )
    }
}

enum LLMTrainingEvent: Codable, Sendable {
    case started(runID: String, message: String, snapshot: TrainingMonitorSnapshot)
    case log(runID: String, message: String, latestStep: LLMTrainingStepMetric?)
    case completed(LLMTrainingReport)
    case failed(LLMTrainingReport)
}

struct LLMTrainingReport: Codable, Sendable {
    let runID: String
    let modelResourceName: String
    let datasetPath: String
    let outputAdapterPath: String
    let success: Bool
    let errorCode: Int32
    let durationMs: Double
    let peakMemoryMB: Double
    let memorySamples: [MemorySample]
    let thermalSamples: [ThermalSample]
    let appStateEvents: [AppStateEvent]
    let mainThreadStalls: [MainThreadStall]
    let stepMetrics: [LLMTrainingStepMetric]
    let logs: [String]
}

struct LLMTrainingStepMetric: Codable, Sendable {
    let epoch: Int
    let totalEpochs: Int
    let phase: String
    let step: Int
    let totalSteps: Int
    let observedDurationMs: Double?
    let loss: Double?
    let accuracyPercent: Double?
    let memoryMB: Double
    let thermalState: String
    let appState: String
    let protectedDataAvailable: Bool
    let timestamp: Date
}

struct TrainingMonitorSnapshot: Codable, Sendable {
    let peakMemoryMB: Double
    let memorySamples: [MemorySample]
    let thermalSamples: [ThermalSample]
    let appStateEvents: [AppStateEvent]
    let mainThreadStalls: [MainThreadStall]
}

struct MemorySample: Codable, Sendable {
    let timestamp: Date
    let residentMB: Double
}

struct ThermalSample: Codable, Sendable {
    let timestamp: Date
    let state: String
    let lowPowerModeEnabled: Bool
}

struct AppStateEvent: Codable, Sendable {
    let timestamp: Date
    let state: String
    let protectedDataAvailable: Bool
    let note: String
}

struct MainThreadStall: Codable, Sendable {
    let timestamp: Date
    let delayMs: Double
}

enum LLMTrainingError: Error, LocalizedError {
    case emptyDataset
    case modelMissing(String)
    case refusingToTrainOnMainThread
    case nativeTrainingFailed(code: Int32, report: LLMTrainingReport)

    var errorDescription: String? {
        switch self {
        case .emptyDataset:
            return "Training dataset is empty."
        case .modelMissing(let name):
            return "Missing bundled Llama 3.2 1B GGUF model: \(name).gguf."
        case .refusingToTrainOnMainThread:
            return "Refusing to run LoRA training on the main thread."
        case .nativeTrainingFailed(let code, _):
            return "Native LoRA training failed with code \(code)."
        }
    }
}

private final class TrainingLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private let runID: String
    private let options: LLMTrainingOptions
    private let onEvent: LLMTrainingService.EventHandler?
    private var lastObservedStepTime: CFTimeInterval?

    private(set) var logs: [String] = []
    private(set) var stepMetrics: [LLMTrainingStepMetric] = []

    init(
        runID: String,
        options: LLMTrainingOptions,
        onEvent: LLMTrainingService.EventHandler?
    ) {
        self.runID = runID
        self.options = options
        self.onEvent = onEvent
    }

    func receiveLog(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        let now = CACurrentMediaTime()
        let metric = Self.parseStepMetric(
            from: line,
            observedDurationMs: lastObservedStepTime.map { (now - $0) * 1000 }
        )
        if metric != nil {
            lastObservedStepTime = now
        }

        lock.lock()
        logs.append(line)
        if let metric {
            stepMetrics.append(metric)
        }
        lock.unlock()

        onEvent?(.log(runID: runID, message: line, latestStep: metric))
    }

    private static func parseStepMetric(
        from line: String,
        observedDurationMs: Double?
    ) -> LLMTrainingStepMetric? {
        let pattern = #"\[epoch\s+(\d+)/(\d+)\]\[(train|eval)\]\s+step\s+(\d+)/(\d+).*loss=([0-9eE+\-.]+).*acc=([0-9eE+\-.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 8 else {
            return nil
        }

        func value(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }

        guard let epoch = value(1).flatMap(Int.init),
              let totalEpochs = value(2).flatMap(Int.init),
              let phase = value(3),
              let step = value(4).flatMap(Int.init),
              let totalSteps = value(5).flatMap(Int.init) else {
            return nil
        }

        return LLMTrainingStepMetric(
            epoch: epoch,
            totalEpochs: totalEpochs,
            phase: phase,
            step: step,
            totalSteps: totalSteps,
            observedDurationMs: observedDurationMs,
            loss: value(6).flatMap(Double.init),
            accuracyPercent: value(7).flatMap(Double.init),
            memoryMB: LLMService.getMemoryMB(),
            thermalState: ProcessInfo.processInfo.thermalState.trainingName,
            appState: UIApplication.shared.applicationState.trainingName,
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            timestamp: Date()
        )
    }
}

private final class TrainingRuntimeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "reply-demo.training-monitor")
    private var sampleTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    private var peakMemoryMB: Double = 0
    private var memorySamples: [MemorySample] = []
    private var thermalSamples: [ThermalSample] = []
    private var appStateEvents: [AppStateEvent] = []
    private var mainThreadStalls: [MainThreadStall] = []

    func start() {
        recordAppState(note: "training_monitor_started")
        recordThermalState()
        installObservers()
        startSampling()
        startMainThreadWatchdog()
    }

    func stop() {
        sampleTimer?.cancel()
        watchdogTimer?.cancel()
        sampleTimer = nil
        watchdogTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        recordAppState(note: "training_monitor_stopped")
    }

    func snapshot() -> TrainingMonitorSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TrainingMonitorSnapshot(
            peakMemoryMB: peakMemoryMB,
            memorySamples: memorySamples,
            thermalSamples: thermalSamples,
            appStateEvents: appStateEvents,
            mainThreadStalls: mainThreadStalls
        )
    }

    private func startSampling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.recordMemorySample()
            self?.recordThermalState()
        }
        timer.resume()
        sampleTimer = timer
    }

    private func startMainThreadWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            let sentAt = CACurrentMediaTime()
            DispatchQueue.main.async {
                let delayMs = (CACurrentMediaTime() - sentAt) * 1000
                if delayMs >= 250 {
                    self?.recordMainThreadStall(delayMs: delayMs)
                }
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "did_enter_background"),
            (UIApplication.willEnterForegroundNotification, "will_enter_foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "protected_data_unavailable"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "protected_data_available"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal_state_changed")
        ]

        observers = names.map { name, note in
            center.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                if name == ProcessInfo.thermalStateDidChangeNotification {
                    self?.recordThermalState()
                } else {
                    self?.recordAppState(note: note)
                }
            }
        }
    }

    private func recordMemorySample() {
        let memory = LLMService.getMemoryMB()
        lock.lock()
        peakMemoryMB = max(peakMemoryMB, memory)
        memorySamples.append(MemorySample(timestamp: Date(), residentMB: memory))
        lock.unlock()
    }

    private func recordThermalState() {
        let sample = ThermalSample(
            timestamp: Date(),
            state: ProcessInfo.processInfo.thermalState.trainingName,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        lock.lock()
        if thermalSamples.last?.state != sample.state ||
            thermalSamples.last?.lowPowerModeEnabled != sample.lowPowerModeEnabled {
            thermalSamples.append(sample)
        }
        lock.unlock()
    }

    private func recordAppState(note: String) {
        let event = AppStateEvent(
            timestamp: Date(),
            state: UIApplication.shared.applicationState.trainingName,
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            note: note
        )
        lock.lock()
        appStateEvents.append(event)
        lock.unlock()
    }

    private func recordMainThreadStall(delayMs: Double) {
        lock.lock()
        mainThreadStalls.append(
            MainThreadStall(timestamp: Date(), delayMs: delayMs)
        )
        lock.unlock()
    }
}

private extension ProcessInfo.ThermalState {
    var trainingName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

private extension UIApplication.State {
    var trainingName: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
