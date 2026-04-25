# 底层推理（Inference）运行时变更说明

本文记录 **Reply Recommendation Demo** 从 Swift Package 的 llama.cpp 封装迁移到仓库内 **`llama.xcframework`** 的架构与工程改动，便于后续维护与对齐其他平台构建。

## 变更动机

- 使用与 **On_Device_Fine_Tuning** 一致的预编译 `llama.xcframework`，便于与端上构建管线、版本和功能（含 LoRA / 训练相关头文件与符号）对齐。
- 减少对远程 SPM（`llama.swift`）版本的耦合，由仓库内二进制统一来源。

## 架构概览（未改动的分层）

应用仍采用分层设计，**仅最底层「与 llama.cpp C API 交互」的一层**发生依赖与少量 API 替换：

| 层级 | 职责 | 是否变更 |
|------|------|----------|
| UI / 状态 | `ChatViewModel`、各 SwiftUI 视图 | 否 |
| 引擎编排 | `LocalReplyEngine`、`ReplySuggestionEngine` | 否 |
| Prompt / 解析 | `PromptBuilder`、`OutputParser`、`Models` | 否 |
| **本地推理** | `LLMService`：加载 GGUF、KV、decode、sampler、LoRA | **是** |

云端（`CloudService`）与 Mock 引擎不受影响。

## 具体改动

### 1. 依赖：`LlamaSwift`（SPM）→ `llama.xcframework`

**之前**

- Xcode 工程依赖远程包 [mattt/llama.swift](https://github.com/mattt/llama.swift)，产品名为 `LlamaSwift`。
- `LLMService.swift` 使用 `import LlamaSwift` 以暴露 C API。

**之后**

- 移除 SwiftPM 中对 `LlamaSwift` 的引用（`project.pbxproj` 中不再包含 `XCRemoteSwiftPackageReference` / `XCSwiftPackageProductDependency`）。
- 将 **`On_Device_Fine_Tuning/llama.xcframework`** 加入主 App Target：
  - **Link Binary With Libraries**：链接该 xcframework。
  - **Embed Frameworks**：`CodeSignOnCopy`、`RemoveHeadersOnCopy`，保证真机与分发时动态库随 App 嵌入并可被加载。

当前工程内 xcframework 的引用路径（相对包含 `.xcodeproj` 的目录）为：

```text
../On_Device_Fine_Tuning/llama.xcframework
```

若需将 Demo 目录单独拷贝到其他仓库，应把整个 `llama.xcframework` 一并拷贝到工程内，并在 Xcode 中更新该引用路径。

### 2. `LLMService.swift`

| 项目 | 说明 |
|------|------|
| 模块导入 | `import LlamaSwift` → `import llama`（与 xcframework 内 `module.modulemap` 中的模块名 `llama` 一致）。 |
| LoRA 挂载 | 与当前 xcframework 所带 **llama.cpp** C API 对齐：`llama_set_adapters_lora`（多 adapter 数组）改为 **`llama_set_adapter_lora(ctx, adapter, scale)`**。 |
| 其余逻辑 | 模型加载、`llama_decode`、batch、`llama_sampler_*`、`llama_get_memory` / `llama_memory_clear`、分词与反分词等 **保持同一套 C API 调用模式**，未重写上层业务。 |

### 3. SwiftPM 解析文件

- 已删除仅服务于原 SPM 的 `Package.resolved`（工程不再通过 SPM 拉取 llama）。

## 明确不需要做的事

- **`On_Device_Fine_Tuning/build/bin` 下的 `.dylib`**：面向 macOS 等本机构建产物，**不应**复制或链接进本 iOS Demo；iOS 应只使用 **xcframework 内各 slice 的 `llama.framework`**。
- **不必**为「能跑 iOS 本地推理」而额外拷贝 `build` 目录中的 dylib；与 `llama.xcframework` 重复且易混淆平台。

## 后续可扩展方向（同一 xcframework）

当前 `llama.xcframework` 随附的头文件中除推理外，还包含 LoRA 适配器与基于 GGML 的优化/训练相关声明（例如 `llama_opt_*`、`ggml_opt_*`）。若要在 Demo 中做 **端上 LoRA 训练 PoC**，仍建议以 **`LLMService` 或新建薄封装** 为边界增量接入，避免扩散到 UI 层。

## 故障排除：Build Failed（`llama.h` / SwiftExplicitPrecompiledModules）

若 Xcode 报错大意如下：

- `llama.h` **has been modified since** the module file …
- 或提示重建 `SwiftExplicitPrecompiledModules/.../llama-...` 下的预编译模块

原因多为：**更换或更新 xcframework 后**，Swift 显式模块缓存仍指向旧的 PCM，与当前头文件时间戳或内容不一致。

**建议按顺序操作：**

1. **Clean**：菜单 **Product → Clean Build Folder**（⇧⌘K）。
2. **删本工程 DerivedData**（最彻底）：关闭 Xcode 后，删除  
   `~/Library/Developer/Xcode/DerivedData/` 下名称包含 **`Reply_Recommendation_Demo`** 的文件夹，再重新打开工程编译。
3. 工程已为 App Target 设置 **`SWIFT_ENABLE_EXPLICIT_MODULES = NO`**（Debug / Release），用于减轻 Xcode 26 下与 **预编译 C 模块（`import llama`）** 相关的缓存不同步问题；若你本地仍偶发，重复步骤 1–2 即可。

**说明**：Issue 导航里若仅有黄色提示「All interface orientations must be supported…」，属于 **Info.plist / 支持的界面方向** 与竖屏-only 配置的常见警告，一般不会单独导致链接失败；当前 Build Failed 以红色 **llama 模块** 错误为准时，按上文清理即可。

## 2026-04-24 运行时修复记录

### 已解决的问题

1. **`LLMService.init/deinit` ownership 崩溃**

   迁移到 `llama.xcframework` 后，真机上曾在 `LLMService.deinit`、`llama_model_free`、`std::vector` / `unordered_map` 析构路径附近出现 `SIGABRT`。处理方式：

   - `llama_backend_init()` 改为 app-level singleton，只初始化一次。
   - 不再在每个 `LLMService.deinit` 中调用 `llama_backend_free()`。
   - `model/context/sampler` 在 init 成功前先用本地 owned 变量持有，失败时按顺序释放，成功后再转交给实例属性。
   - deinit 顺序固定为 sampler → context → model。
   - LoRA adapter 不在 Swift 侧重复 free；当前 QVAC header / 实现中 adapter 生命周期跟随 owning model。

2. **`Failed to create llama context` / Metal BF16 编译失败**

   真机日志曾出现：

   ```text
   ggml_metal_library_init: error ... static_assert failed ...
   Input types must match cooperative tensor types
   llama_init_from_model: failed to initialize Metal backend
   ```

   根因是当前 QVAC 预编译 `llama.xcframework` 默认使用 `GGML_METAL_USE_BF16=ON`。在 iPhone 17 Pro Max / A19 Pro + 当前 iOS SDK / Metal 编译环境下，这条 BF16 cooperative tensor 路径会在 shader 编译阶段遇到 `bfloat` / `half` 类型不匹配。

   处理方式：

   - 切到 QVAC `qvac-fabric-llm.cpp` 的 `fabric-llm-finetune` 分支。
   - 将 `build-xcframework.sh` 中 `GGML_METAL_USE_BF16=ON` 改为 `OFF`。
   - 使用该分支重新 build `llama.xcframework`。
   - 替换 Demo 当前引用的：

     ```text
     /Users/William/LA-Hacks/On_Device_Fine_Tuning/llama.xcframework
     ```

   旧版本备份为：

   ```text
   /Users/William/LA-Hacks/On_Device_Fine_Tuning/llama.xcframework.backup-20260424-003016
   ```

3. **临时 CPU pin 已撤销**

   为了确认 CPU 路径可用，曾临时把 iOS 推理 pin 到 CPU：

   - `n_gpu_layers = 0`
   - `modelParams.devices = CPU`
   - `ctxParams.offload_kqv = false`
   - `ctxParams.op_offload = false`
   - `flash_attn_type = DISABLED`

   CPU 路径验证可跑后，上述 pin 已撤销。当前 App 允许 llama.cpp 使用 Metal backend。

4. **QVAC offload 层数语义修正**

   当前 QVAC fork 中 `llama_model_default_params()` 的默认值是：

   ```cpp
   n_gpu_layers = 999
   ```

   因此 Swift 侧默认 `gpuLayers` 从 `-1` 改为 `999`，以匹配该 fork 的“尽量全量 offload 到 GPU”的语义。

### 当前状态

- Framework：仍启用 Metal。
- BF16 Metal 路径：关闭。
- App CPU pin：已撤销。
- 默认 GPU offload：`gpuLayers = 999`。
- 预期日志中应看到 `offloading ... layers to GPU` 和 Metal buffer / compute buffer 相关输出。

注意：`CPU_Mapped` 不一定等于“纯 CPU 推理”。Apple 设备是 unified memory，Metal buffer 可能以 shared / mapped 形式出现；判断是否真的走 Metal，重点看是否同时出现：

```text
llama_model_load_from_file_impl: using device Metal ...
llm_load_tensors: offloading ... repeating layers to GPU
llm_load_tensors: offloaded .../... layers to GPU
llm_load_tensors: Metal... model buffer size = ...
llama_init_from_model: Metal... compute buffer size = ...
```

如果只看到 `CPU_Mapped model buffer size`，且没有 `offloading ... to GPU` / `Metal ... buffer size`，则仍需要继续排查 Metal device 是否被注册、模型层是否被分配到 Metal，或当前运行是否仍在使用旧 framework / 旧 DerivedData。

### 为什么速度可能和 CPU 差不多

短回复生成场景下，即使 Metal offload 成功，也可能不会明显快很多：

- prompt / token 数少，GPU kernel launch 和调度开销占比高。
- 每次只生成少量 token，decode 是小 batch 串行过程，CPU 采样、JSON 解析、Swift queue 调度也会占时间。
- 首次运行会包含模型加载、KV cache 分配、Metal shader JIT 等冷启动成本。
- Q4_K_M 这类量化模型的某些算子、输入层、输出层、采样仍可能在 CPU/shared memory 路径上。
- Xcode debug build、日志输出、调试器 attach 会显著影响真实性能。

建议对比性能时使用同一条 prompt，跳过首次 warm-up，连续跑多次，观察 steady-state `tokens/s` 或 `latencyMs`。

## 如何在 Xcode / Instruments 看 GPU 使用

### 1. 先确认日志

最直接的第一层验证是看 terminal / Xcode console 中的 llama 日志。应重点搜索：

```text
using device
offloading
Metal
model buffer size
compute buffer size
```

如果没有 `offloading ... to GPU`，Xcode GPU usage 不动是正常的。

### 2. Xcode Debug Navigator

运行真机 App 后：

1. 在 Xcode 左侧打开 **Debug Navigator**。
2. 展开当前运行的 App 进程。
3. 查看 CPU、Memory、Energy、FPS 等 gauges。

说明：Xcode 的 Debug gauges 不一定给 iOS App 显示单独的“GPU usage 百分比”。它更适合看 CPU/内存/能耗/FPS 的变化，不适合作为 Metal compute 是否执行的唯一依据。

### 3. Capture Metal Workload

如果要确认真的有 Metal command 被提交：

1. Xcode 菜单选择 **Product → Scheme → Edit Scheme...**。
2. 选择 **Run → Options**。
3. 确认 **GPU Frame Capture** 为 `Automatically` 或 `Metal`。
4. 真机运行 App。
5. 在推理开始前，点击 debug bar 里的 **Metal Capture** 按钮。
6. 选择 device / command queue / command buffer scope 并 Capture。

捕获成功后，Metal debugger 里应该能看到 compute commands / pipeline states。若捕获不到任何 Metal workload，说明当前推理路径很可能没有提交 Metal command，或 capture scope 没覆盖到推理时段。

Apple 官方参考：

- https://developer.apple.com/documentation/xcode/capturing-a-metal-workload-in-xcode
- https://developer.apple.com/documentation/Xcode/Analyzing-your-Metal-workload

### 4. Instruments

更适合看持续运行期间的 GPU/CPU 占用：

1. Xcode 中选择 **Product → Profile**，或在 Debug gauge 页面点 **Profile in Instruments**。
2. 选择与 Metal / GPU 相关的 template，例如 Metal System Trace、Game Performance、Time Profiler + Metal 相关 counters。
3. 在真机上触发一次或多次本地生成。
4. 观察 GPU command queue、kernel/dispatch 时间、CPU thread 时间。

如果 Instruments 中 GPU dispatch 很短，而 CPU thread 时间长，说明瓶颈可能不在模型矩阵乘本身，而在 prompt 构造、tokenize、采样、JSON parsing、queue serialization、UI update 或小 token 生成的串行开销。

## 变更日期

文档随仓库演进维护；首次记录对应迁移至 **`llama.xcframework`** 与 **`LLMService` / Xcode 工程** 的上述改动。
