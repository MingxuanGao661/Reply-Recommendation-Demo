import json
import random

with open("sample_dialogue_data/dummy_data.json", "r") as f:
    raw = json.load(f)

SPEAKER_MAP = {"user": "me", "system": "other"}

TONES = ["warm", "friendly", "neutral", "enthusiastic", "calm"]
STYLES = ["casual", "chill", "conversational", "relaxed"]

def estimate_length(text):
    words = len(text.split())
    if words <= 8:
        return "short"
    elif words <= 20:
        return "medium"
    return "long"

samples = []

for dialog in raw:
    turns = dialog.get("turns", [])
    if len(turns) < 3:
        continue

    last_me_idx = None
    for i in range(len(turns) - 1, -1, -1):
        if turns[i]["speaker"] == "user":
            last_me_idx = i
            break

    if last_me_idx is None or last_me_idx == 0:
        continue

    conversation = []
    for t in turns[:last_me_idx]:
        conversation.append({
            "speaker": SPEAKER_MAP[t["speaker"]],
            "text": t["utterance"]
        })

    draft = turns[last_me_idx]["utterance"]

    sample = {
        "conversation": conversation,
        "draft": draft.lower().rstrip(".!?") if random.random() < 0.5 else draft,
        "profile": {
            "tone": random.choice(TONES),
            "length": estimate_length(draft),
            "style": random.choice(STYLES)
        }
    }
    samples.append(sample)

random.seed(42)
selected = random.sample(samples, min(10, len(samples)))

with open("test_samples.json", "w") as f:
    json.dump(selected, f, indent=2, ensure_ascii=False)

print(f"已生成 {len(selected)} 条测试样本 → test_samples.json")
