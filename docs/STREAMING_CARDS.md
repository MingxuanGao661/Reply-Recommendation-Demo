# 逐张卡片渐进式生成 — 更新说明

## 背景

之前的实现：一次 LLM 调用生成全部三条建议，等全部完成后一次性推送给前端，用户体验"卡住"感很强。

## 新的交互体验

- 点击生成按钮 → **按钮变成 spinner**，卡片区域保持空白
- 第 1 条（Natural）生成完 → 卡片**淡入出现**，文字**逐词打出**
- 第 2、3 条依次出现，各自独立打字
- 全部完成 → spinner 恢复为 sparkles 图标

## 数据流

```
用户点击生成
  → suggestions = []，isGenerating = true
  → LLM 串行生成 Natural → onSuggestionReady → suggestions = [card1] → UI 淡入 + 打字
  → LLM 生成 Polite      → onSuggestionReady → suggestions = [card1, card2]
  → LLM 生成 Like You    → onSuggestionReady → suggestions = [card1, card2, card3]
  → isGenerating = false
```

## 修改文件

### `Backend/LLMService.swift`
- 提取 `generate(prompt: String)` 方法，让 `generate(input:)` 直接复用
- `LocalReplyEngine` 可传入单语气 prompt，无需改动核心推理逻辑

### `Backend/PromptBuilder.swift`
- 新增 `buildLlamaPromptSingle(input:userDefaultProfile:toneLabel:)`
- 针对单个语气（Natural / Polite / Like You）生成专用 prompt，输出 `{"label": "...", "text": "..."}`

### `Features/Common/ReplySuggestionEngine.swift`
- 协议新增 `generateSuggestionsProgressive(onSuggestionReady:)`
- 默认实现：批量交付（向后兼容）
- `MockReplyEngine`：每 200ms 交付一条
- `LocalReplyEngine`：3 次串行 LLM 调用，每完成一条立即回调

### `Features/Chat/ChatViewModel.swift`
- `generateSuggestions()` 改用 progressive API，每次回调 `suggestions.append(item)`
- 新增 `resolveEngine()` 替代旧 `runSelectedEngine`
- 新增 `normalizeSingleSuggestion()` 处理单条 label 规范化

### `Features/Chat/ChatUI.swift`
- `DemoMessageComposer` 新增 `isGenerating` 参数，加载时按钮换成 `ProgressView` spinner
- `SuggestionShelf` 去掉骨架屏，加载时卡片区域保持空白（`minHeight: 96` 防止布局塌陷）
- 新增 `TypewriterText` 组件（逐词打字，9 词/秒），用于 `SuggestionCard` 的正文
- 卡片出现使用 `.transition(.opacity)` + `.easeInOut(duration: 0.35)` 淡入

### `Features/Chat/ChatScreen.swift`
- `DemoMessageComposer` 调用加入 `isGenerating: viewModel.isGenerating`

## 给前端队友的说明

**`suggestions` 数组现在分三次增长**，`isGenerating == true` 期间可能只有 1~2 个元素，不要假设它要么空要么 3 个。

`SuggestionShelf` 和 `DemoMessageComposer` 的绑定接口没有变化，只是 `DemoMessageComposer` 多了一个 `isGenerating: Bool` 参数。

## 新旧体验对比

| | 旧实现 | 新实现 |
|---|---|---|
| 等待反馈 | 无（纯等待） | 按钮 spinner |
| 第一张卡出现时机 | 全部完成后 | 约 1/3 总时间 |
| 卡片出现方式 | 三张同时弹出 | 依次淡入 |
| 卡片文字 | 瞬间显示 | 逐词打出（打字机效果） |
| 骨架屏 | 有（三个灰色占位） | 无 |
