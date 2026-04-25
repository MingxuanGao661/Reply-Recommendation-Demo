# 前端集成说明 — Reply 建议 Backend API
---

## 1. Profile 两层并行（按字段补全，不整包覆盖）

和「语气 / 长度」相关的配置只有下面两层：

| 层级 | 在哪里 | 用法 |
|------|--------|------|
| **会话** | JSON `conversation_profile` | 跟聊天线程一起存；可只写其中一部分字段。 |
| **用户默认** | `defaultProfile`（service 上） | 设置页保存，启动后赋给 `CloudService` / `LLMService`。也可只填部分字段。 |

**合并规则（并行、不冲突）：**  
- **`tone`：** 会话里带了就用会话的；否则用用户默认的；再没有 → `"warm"`。  
- **`length`：** 同理，最后用 `"short"`。

两层是**同一轴上谁有值用谁**，不是「整包 conversation 优先、整包丢掉 default」。例如：用户默认 `{ "tone": "warm", "length": "long" }`，某会话只写 `{ "tone": "formal" }`，则生效 **formal + long**（语气来自会话，长度来自用户）。

`conversation_profile` 可整段省略；省略的轴全部由 `defaultProfile` 与内置默认补全。

---

## 2. System / User 分工（给模型）

- **System：** 任务说明；Rules 里会**同时写清**：个人（`defaultProfile`）的 tone/length、本会话（`conversation_profile`）的 tone/length、以及**按轴合并后的生效** tone/length。**不包含**整段聊天归档。
- **User：** **近期对话窗口**（由你们在客户端截取，例如最近 N 条）、群提示、`reply_to`、草稿、`Reply with JSON`。`conversation` 数组应已是你们选好的一段上下文，不必传全量历史。

数据仍由你按下面字段传入；后端负责拼进对应 role。

---

## 3. 输出结构

后端返回 **JSON 字符串**（或 decode 后的结构体）：

```json
{
  "suggestions": [
    { "label": "Natural",  "text": "建议回复文案 1" },
    { "label": "Polite",   "text": "建议回复文案 2" },
    { "label": "Like You", "text": "建议回复文案 3" }
  ]
}
```

- `label`：`Natural` / `Polite` / `Like You`（展示可本地化）。
- `text`：可直接填入输入框或作为候选条。

---

## 4. 输入：`ConversationInput`

### 4.1 字段表

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `conversation` | 数组 | **是** | **客户端截取后的近期消息**（如最近 N 条），非必须全线程 |
| `participants` | 数组 | 否 | 默认 `[]`，`speaker` id → 界面展示名 |
| `self_id` | 字符串 | 否 | 默认 `"me"`，当前用户在该会话的 `speaker` id |
| `reply_to` | 字符串 | 否 | 正在回复谁；群聊 @ 时建议传 |
| `draft` | 字符串 | 否 | 输入框草稿；空/省略 = 「从零给三条建议」 |
| `conversation_profile` | 对象 | 否 | 本会话的 `tone` / `length`，见 §4.4 |

### 4.2 `Message`

```json
{ "speaker": "<用户ID>", "text": "消息正文" }
```

- `speaker`：稳定 id（二人聊天对方也用具体 id，如 `"alice"`）。
- 展示名只通过 `participants`，不要在这条里塞 displayName。

### 4.3 `Participant`

```json
{
  "id": "alice",
  "name": "Alice",
  "is_self": false,
  "relationship": "friend"
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `id` | 是 | 与 `conversation[].speaker` 一致 |
| `name` | 是 | 进 prompt 的展示名 |
| `is_self` | 否 | 当前用户可标 `true` |
| `relationship` | 否 | 可选元数据 |

### 4.4 `conversation_profile` / `Profile`

`tone`、`length` 在 JSON 里**均可选**；只传需要的轴即可。

```json
{ "tone": "formal", "length": "short" }
```

或只覆盖语气：

```json
{ "tone": "formal" }
```

| 字段 | 必填 | 含义 | 示例 |
|------|------|------|------|
| `tone` | 否 | 语气 | `warm` / `neutral` / `friendly` / `formal` |
| `length` | 否 | 篇幅 | `short` / `medium` / `long` |

用户侧 `defaultProfile` 同样支持只设其中一项。

---

## 5. JSON 示例

### 5.1 二人聊天 + 草稿 + 会话 profile

```json
{
  "conversation": [
    { "speaker": "alice", "text": "晚上一起吃饭？" },
    { "speaker": "me", "text": "好啊" },
    { "speaker": "alice", "text": "几点方便？" }
  ],
  "participants": [
    { "id": "me", "name": "我", "is_self": true },
    { "id": "alice", "name": "Alice" }
  ],
  "self_id": "me",
  "reply_to": "alice",
  "draft": "7点吧",
  "conversation_profile": {
    "tone": "friendly",
    "length": "short"
  }
}
```

### 5.2 无草稿

```json
{
  "conversation": [
    { "speaker": "bob", "text": "周末爬山去吗？" }
  ],
  "participants": [
    { "id": "me", "name": "我", "is_self": true },
    { "id": "bob", "name": "Bob" }
  ],
  "self_id": "me",
  "reply_to": "bob",
  "conversation_profile": { "tone": "warm", "length": "short" }
}
```

### 5.3 本会话不单独配置风格

省略 `conversation_profile`，由 `defaultProfile`（用户设置）兜底。

```json
{
  "conversation": [
    { "speaker": "alice", "text": "Hi" }
  ],
  "participants": [
    { "id": "me", "name": "我", "is_self": true },
    { "id": "alice", "name": "Alice" }
  ],
  "self_id": "me",
  "reply_to": "alice"
}
```

---

## 6. Swift 调用

```swift
var cloud = try CloudService(apiKey: key, provider: "groq")
cloud.defaultProfile = Profile(tone: "warm", length: "short")

let input = ConversationInput(
    conversation: messages,
    draft: textField.isEmpty ? nil : textField,
    conversationProfile: thread.profile,
    selfId: currentUserSpeakerId,
    replyTo: replyTargetId,
    participants: participantRows
)

let (jsonString, metrics) = try await cloud.generate(input: input)
```

Local：

```swift
let local = try LLMService(modelPath: path, defaultProfile: userDefaultProfile)
let (jsonString, metrics) = try local.generate(input: input)
```

`generate` 宜在后台线程执行（Local 尤其）。

---

## 7. 设计建议

| 数据 | 存哪 | 何时更新 |
|------|------|----------|
| 用户默认 `Profile` | UserDefaults 等 | 设置页「默认回复风格」 |
| `conversation_profile` | Thread / Room 模型 | 会话设置，或新建会话时复制用户默认 |

**`reply_to`：** 私聊一般填对方 id；群聊在回复/@ 某人时填被回复者的 `speaker` id。

**契约：** 字段名与 `Models.swift` 中 `CodingKeys` 一致（`conversation_profile`、`self_id`、`reply_to`）。

---

## 8. 延伸阅读

- 后端对照说明：`CONVERSION_REPORT.md`（仓库根目录）。
