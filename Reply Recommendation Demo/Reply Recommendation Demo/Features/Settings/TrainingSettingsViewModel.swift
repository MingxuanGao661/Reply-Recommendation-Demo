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

        do {
            let finalReport = try await trainingService.runConservativeLoRATest(
                samples: Self.smokeTrainingSamples,
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
            logs = [message]
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

    private static let smokeTrainingSamples: [String] = [
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
