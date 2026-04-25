import Combine
import Foundation

protocol LocalTrainingServiceProtocol {
    func runConservativeLoRATest(
        samples: [String],
        options: LLMTrainingOptions,
        onEvent: LLMTrainingService.EventHandler?
    ) async throws -> LLMTrainingReport
}

extension LLMTrainingService: LocalTrainingServiceProtocol { }

enum TrainingRunStatus: Equatable {
    case idle
    case preparing
    case running
    case completed
    case failed

    var isActive: Bool {
        self == .preparing || self == .running
    }

    var displayName: String {
        switch self {
        case .idle: return "Not started"
        case .preparing: return "Preparing"
        case .running: return "Training"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

@MainActor
final class TrainingSettingsViewModel: ObservableObject {
    @Published private(set) var status: TrainingRunStatus = .idle
    @Published private(set) var runID: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var latestStep: LLMTrainingStepMetric?
    @Published private(set) var report: LLMTrainingReport?
    @Published private(set) var errorMessage: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var sampleCount: Int = 0

    private let settingsStore: AppSettingsStore
    private let trainingService: LocalTrainingServiceProtocol

    init(
        settingsStore: AppSettingsStore,
        trainingService: LocalTrainingServiceProtocol
    ) {
        self.settingsStore = settingsStore
        self.trainingService = trainingService
    }

    var progress: Double? {
        guard let latestStep, latestStep.totalSteps > 0 else { return nil }
        return min(max(Double(latestStep.step) / Double(latestStep.totalSteps), 0), 1)
    }

    var progressPercentText: String {
        guard let progress else { return "--" }
        return "\(Int((progress * 100).rounded()))%"
    }

    var elapsedText: String {
        guard let startedAt else { return "Not started" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return Self.durationText(seconds: seconds)
    }

    var etaText: String {
        guard let startedAt, let progress, progress > 0 else { return "--" }
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let remaining = max(0, Int((elapsed / progress) - elapsed))
        return Self.durationText(seconds: remaining)
    }

    var stepText: String {
        guard let latestStep else { return "Step -- / --" }
        return "Step \(latestStep.step) / \(latestStep.totalSteps)"
    }

    var chunkText: String {
        guard let latestStep else {
            return sampleCount > 0 ? "Chunk 0 / \(sampleCount)" : "Chunk -- / --"
        }
        let total = max(latestStep.totalSteps, sampleCount)
        let current = min(max(latestStep.step, 0), total)
        return "Chunk \(current) / \(total)"
    }

    var thermalState: String? {
        latestStep?.thermalState ?? report?.thermalSamples.last?.state
    }

    private static func durationText(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }

    var recentLogs: [String] {
        Array(logs.suffix(12))
    }

    func startTraining() async {
        guard settingsStore.localTrainingEnabled, !status.isActive else { return }

        status = .preparing
        runID = nil
        logs = []
        latestStep = nil
        report = nil
        errorMessage = nil
        startedAt = Date()
        let dataset = Self.resolvedSmokeTrainingSamples()
        sampleCount = dataset.samples.count
        logs = [
            "[dataset] source=\(dataset.source) samples=\(dataset.samples.count)"
        ]

        do {
            let finalReport = try await trainingService.runConservativeLoRATest(
                samples: dataset.samples,
                options: .conservativeLlama32OneB(),
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handle(event)
                    }
                }
            )
            if status != .completed {
                applyCompletedReport(finalReport)
            }
        } catch LLMTrainingError.nativeTrainingFailed(_, let failedReport) {
            applyFailedReport(failedReport)
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
            logs.append(error.localizedDescription)
        }
    }

    func handle(_ event: LLMTrainingEvent) {
        switch event {
        case .started(let runID, let message, _):
            status = .running
            self.runID = runID
            if logs.first?.hasPrefix("[dataset]") == true {
                logs = [logs[0], message]
            } else {
                logs = [message]
            }
            latestStep = nil
            report = nil
            errorMessage = nil

        case .log(let runID, let message, let latestStep):
            status = .running
            self.runID = runID
            logs.append(message)
            if let latestStep {
                self.latestStep = latestStep
            }

        case .completed(let report):
            applyCompletedReport(report)

        case .failed(let report):
            applyFailedReport(report)
        }
    }

    private func applyCompletedReport(_ report: LLMTrainingReport) {
        status = .completed
        self.report = report
        runID = report.runID
        errorMessage = nil
        settingsStore.recordLocalTrainingReport(report)
    }

    private func applyFailedReport(_ report: LLMTrainingReport) {
        status = .failed
        self.report = report
        runID = report.runID
        errorMessage = "Training failed with code \(report.errorCode)."
        logs = report.logs.isEmpty ? logs : report.logs
    }

    private struct SmokeDatasetSelection {
        let samples: [String]
        let source: String
    }

    /// Preferred smoke dataset file in app bundle (without extension).
    private static let preferredSmokeDatasetResource = "social_300_shakespeare_smoke_test_ondevice_train"
    private static let smokeSampleSeparator = "<|end_of_text|>"

    private static func resolvedSmokeTrainingSamples(bundle: Bundle = .main) -> SmokeDatasetSelection {
        if let loaded = loadSamplesFromBundledTXT(bundle: bundle), !loaded.isEmpty {
            return SmokeDatasetSelection(
                samples: loaded,
                source: "bundle:\(preferredSmokeDatasetResource).txt"
            )
        }
        return SmokeDatasetSelection(
            samples: fallbackSmokeTrainingSamples,
            source: "fallback:inline_smoke_samples"
        )
    }

    private static func loadSamplesFromBundledTXT(bundle: Bundle) -> [String]? {
        guard let url = bundle.url(forResource: preferredSmokeDatasetResource, withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let samples = raw
            .components(separatedBy: smokeSampleSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return samples.isEmpty ? nil : samples
    }

    private static let fallbackSmokeTrainingSamples: [String] = [
        "User: hey are you free tonight? Assistant: I can make time after 8 if that works for you.",
        "User: can you review this before tomorrow? Assistant: Yes, send it over and I can take a look tonight.",
        "User: want to grab lunch this week? Assistant: I would be down, Thursday or Friday is probably easiest.",
        "User: I think I messed that up. Assistant: It is okay, I do not think it is as bad as it feels right now.",
        "User: can you send the updated slides? Assistant: Yes, I will send the revised version before the end of the day.",
        "User: should we still go this weekend? Assistant: I am still in, but I can be flexible if the timing is rough.",
        "User: I got the internship. Assistant: That is amazing, I am really proud of you.",
        "User: can I confirm later? Assistant: Of course, just let me know when you have a better sense."
    ]
}
