# LoRA Training Frontend Integration

本文记录前端如何接入 `LLMTrainingService` 的端上 LoRA training PoC：如何调用、会收到什么事件、结果保存在哪里，以及 UI 应该展示哪些字段。

## 当前能力边界

`LLMTrainingService` 是一个保守的端上训练 smoke test，不是完整训练产品流。

它负责：

- 使用 bundled Llama 3.2 1B GGUF 模型启动 QVAC LoRA finetune。
- 将前端传入的文本样本写成临时训练 dataset。
- 保存训练出来的 LoRA adapter。
- 记录内存、温度、App 前后台/锁屏状态、主线程卡顿、训练 step 日志。
- 通过事件流把进度传给前端。

它暂时不负责：

- 数据清洗和标注质量控制。
- 大规模训练队列。
- adapter 管理 UI。
- 训练后自动切换到新 adapter 推理。
- 后台长时间训练保活。

## 入口文件

核心入口：

```swift
Reply Recommendation Demo/Backend/LLMTrainingService.swift
```

底层 native bridge：

```swift
Reply Recommendation Demo/Backend/TrainingBridge/FinetuneBridge.h
Reply Recommendation Demo/Backend/TrainingBridge/FinetuneBridge.mm
Reply Recommendation Demo/ReplyRecommendationDemo-Bridging-Header.h
```

## 最简单调用方式

```swift
let service = LLMTrainingService()

let report = try await service.runConservativeLoRATest(
    samples: [
        "User: Are you free tonight?\nAssistant: I can make time after 8.",
        "User: Can you review this?\nAssistant: Sure, send it over."
    ]
) { event in
    // 前端在这里更新训练状态、日志、图表
}
```

`samples` 是纯文本数组。当前 native bridge 会把它们写入一个 plain-text dataset 文件，然后做 next-token LoRA training。

建议前端先用小数据测试：

```text
5-20 条样本
每条样本尽量短
先验证流程能完成，再扩大数据
```

## 默认训练参数

默认参数来自：

```swift
LLMTrainingOptions.conservativeLlama32OneB()
```

当前值：

```swift
modelResourceName: "Llama-3.2-1B-Instruct-Q4_K_M"
outputAdapterFileName: "reply-lora-smoke.gguf"
contextSize: 256
threadCount: 2
batchSize: 32
microBatchSize: 16
epochs: 1
loraRank: 4
loraAlpha: 8
learningRate: 0.00001
validationSplit: 0
targetModules: 0
seed: 42
flashAttention: false
gpuLayers: 999
```

说明：

- `modelResourceName` 对应 App bundle 内的 `Llama-3.2-1B-Instruct-Q4_K_M.gguf`。
- 如果实际模型文件名不同，前端或调用方需要传自定义 `LLMTrainingOptions`。
- `targetModules = 0` 表示交给 native bridge 使用默认 LoRA target：attention Q/K/V/O。
- `flashAttention = false` 是为了端上训练稳定性。
- `gpuLayers = 999` 对齐当前 QVAC fork 的“尽量 GPU offload”语义。

自定义示例：

```swift
var options = LLMTrainingOptions.conservativeLlama32OneB()
options.modelResourceName = "Your-1B-Model-Name"
options.epochs = 1
options.contextSize = 256

let report = try await service.runConservativeLoRATest(
    samples: samples,
    options: options,
    onEvent: handleTrainingEvent
)
```

## 前端会收到什么

事件类型：

```swift
enum LLMTrainingEvent {
    case started(runID: String, message: String, snapshot: TrainingMonitorSnapshot)
    case log(runID: String, message: String, latestStep: LLMTrainingStepMetric?)
    case completed(LLMTrainingReport)
    case failed(LLMTrainingReport)
}
```

### `.started`

训练开始时发送一次。

前端建议：

- 设置状态为 `running`。
- 清空旧日志。
- 展示 `runID`。
- 开始显示 memory / thermal / app state panel。

### `.log`

native training bridge 输出日志时触发。部分日志会被解析成 step metric。

字段：

```swift
runID: String
message: String
latestStep: LLMTrainingStepMetric?
```

前端建议：

- `message` 放进训练日志列表。
- 如果 `latestStep != nil`，更新 step progress、loss、accuracy、step 耗时、当前内存、温度状态。

### `.completed`

训练成功结束。

前端建议：

- 设置状态为 `completed`。
- 展示 adapter 保存路径。
- 展示总耗时、峰值内存、最终 loss、主线程卡顿次数。

### `.failed`

native training 返回失败，或 Swift service 捕获失败。

前端建议：

- 设置状态为 `failed`。
- 展示 `errorCode` 和最后几条 `logs`。
- 保留 `report`，用于 debug。

## Step Metric 字段

```swift
struct LLMTrainingStepMetric {
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
```

UI 推荐展示：

- Progress：`step / totalSteps`
- Epoch：`epoch / totalEpochs`
- Phase：`train` 或 `eval`
- Loss：`loss`
- Accuracy：`accuracyPercent`
- Step time：`observedDurationMs`
- Memory：`memoryMB`
- Thermal：`thermalState`

`protectedDataAvailable == false` 通常表示设备进入锁屏/受保护数据不可用状态，可作为训练期间锁屏风险提示。

## 最终 Report 字段

```swift
struct LLMTrainingReport {
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
```

前端成功页建议展示：

- `outputAdapterPath`
- `durationMs`
- `peakMemoryMB`
- `stepMetrics.last?.loss`
- `thermalSamples.map(\.state)`
- `mainThreadStalls.count`
- 最近 10 条 `logs`

失败页建议展示：

- `errorCode`
- 最近 20 条 `logs`
- `peakMemoryMB`
- 最后一个 `thermalSamples.last`
- 最后一个 `appStateEvents.last`

## 结果保存在哪里

每次训练会创建一个独立 run 目录：

```text
Application Support/LoRATraining/{runID}/
```

里面包含：

```text
train.txt
reply-lora-smoke.gguf
```

`train.txt` 是本次训练生成的 dataset 文件。

`reply-lora-smoke.gguf` 是输出 LoRA adapter，路径在：

```swift
report.outputAdapterPath
```

前端不要硬编码路径，应使用 `report.outputAdapterPath`。

## 训练结果如何用于推理

当前 service 只负责保存 adapter，不会自动让聊天推理使用它。

后续接入方式建议：

1. 训练完成后保存 `report.outputAdapterPath` 到 App settings / adapter registry。
2. 用户选择某个 adapter。
3. 创建 `LocalReplyEngine` / `LLMService` 时传入该 adapter path。
4. 重新加载 model + adapter 后再推理。

目前 `LocalReplyEngine` 主要从 bundle 查找 LoRA resource。若要使用训练生成的 adapter，需要后续增加“从文件路径加载 LoRA”的入口。

## 推荐 UI 状态机

```text
idle
  -> preparing
  -> running
  -> completed
  -> failed
```

建议 UI 数据模型：

```swift
struct TrainingViewState {
    var status: TrainingStatus
    var runID: String?
    var logs: [String]
    var latestStep: LLMTrainingStepMetric?
    var report: LLMTrainingReport?
    var errorMessage: String?
}
```

事件处理伪代码：

```swift
func handleTrainingEvent(_ event: LLMTrainingEvent) {
    DispatchQueue.main.async {
        switch event {
        case .started(let runID, let message, _):
            state.status = .running
            state.runID = runID
            state.logs = [message]

        case .log(_, let message, let latestStep):
            state.logs.append(message)
            if let latestStep {
                state.latestStep = latestStep
            }

        case .completed(let report):
            state.status = .completed
            state.report = report

        case .failed(let report):
            state.status = .failed
            state.report = report
            state.errorMessage = report.logs.last
        }
    }
}
```

## 注意事项

- 不要在主线程调用训练。
- 首次训练会有模型加载和 Metal 初始化成本。
- 端上训练期间设备可能发热，`thermalState` 到 `serious` 或 `critical` 时建议提示用户停止训练。
- 如果 App 进入后台，训练不一定能长期持续，前端应显示 `appStateEvents`。
- 如果 `mainThreadStalls` 持续增加，说明训练期间 UI 仍被影响，需要降低参数或调整调度。
- 如果 `errorCode != 0`，先看 `logs`，native bridge 会输出失败阶段。

## Native Error Code

来自 `FinetuneBridge.h`：

```text
0 OK
1 INVALID_ARGUMENT
2 MODEL_LOAD
3 CONTEXT_CREATE
4 DATASET
5 TRAINING_INIT
6 SAVE
```

常见含义：

- `2 MODEL_LOAD`：模型文件名不对，或 bundle 中没有 1B GGUF。
- `3 CONTEXT_CREATE`：训练参数太大，Metal/内存初始化失败。
- `4 DATASET`：样本太短，无法形成 `contextSize + 1` 个 token 的训练窗口。
- `5 TRAINING_INIT`：LoRA 参数或训练图初始化失败。
- `6 SAVE`：adapter 输出目录或保存失败。

