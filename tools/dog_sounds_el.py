"""어나더 팸 소리 (0.9.0): 일레븐랩스 효과음 만들기(eleven_text_to_sound_v3)로 실제 녹음 같은 말티즈 소리를 만듦.
사용: ELEVEN_KEY=... python3 tools/dog_sounds_el.py  →  _el_raw/ 에 후보(mp3), ios/AnotherFam/Sounds/ 에 고른 wav.
소리 하나에 후보를 여러 개 만들고, 앞뒤 빈 곳·끊김·찌그러짐·길이·사건 수를 재서 가장 깨끗한 것을 고름 (사람이 듣지 않아도 되게).
키는 저장소에 넣지 않음 (환경 변수로만)."""
import json, os, subprocess, sys, time, urllib.request, wave
import numpy as np

KEY = os.environ.get("ELEVEN_KEY", "")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "ios/AnotherFam/Sounds")
RAW = os.environ.get("EL_RAW", os.path.join(ROOT, "tools/_el_raw"))
SR = 44100

# 공통 녹음 조건: 가까이 대고 건조하게, 한 마리, 배경·음악·사람 소리 없음
REC = ("Realistic field recording, close microphone about 30 cm away, dry quiet indoor room, no reverb, "
       "no background noise, no music, no people, no other animals. Isolated single sound.")
DOG = "a small Maltese dog (toy breed, about 3 kg, white long-haired)"
PUP = "a tiny Maltese puppy (toy breed, about 8 weeks old, 700 g)"
NEW = "a newborn Maltese puppy (5 days old, eyes still closed, 150 g)"
OLD = "an elderly small Maltese dog (14 years old, frail, slightly hoarse voice)"

# (파일 이름(끝 숫자는 붙여 줌), 개수, 요청 길이 s, 잘라 둘 최대 길이 s, 사건 수(소리 덩어리), 설명)
SPEC = [
    # 갓난: 젖 찾을 때·만질 때 가늘게 끙끙·찡찡
    ("mewl", 4, 0.8, 0.6, 1, f"{NEW} making one faint, thin, high squeaky mewling cry while searching for its mother, like a tiny squeak with a little breath, very soft"),
    ("suck", 2, 1.0, 0.25, 1, f"one soft wet suckling smack of {NEW} nursing from a small milk bottle, tiny lips and tongue click"),
    # 아기 강아지
    ("yip", 4, 0.5, 0.35, 1, f"one single short high-pitched playful yip from {PUP}, bright and tiny, clean attack"),
    ("whine_pup", 3, 1.0, 0.9, 1, f"{PUP} giving one short soft pleading whine, rising then falling, gentle and breathy, not a siren"),
    ("whimper_pup", 2, 0.8, 0.7, 1, f"{PUP} making one content little squeaky whimper-groan of pleasure while being stroked, very soft and short"),
    ("growl_play_pup", 2, 1.0, 0.9, 1, f"{PUP} doing a tiny playful mock growl while tugging a toy, cute, light and breathy, not scary"),
    ("yawn_pup", 2, 1.2, 1.0, 1, f"{PUP} yawning widely with a tiny squeak at the end of the yawn"),
    # 성견
    ("bark", 4, 0.6, 0.45, 1, f"one single sharp alert bark from {DOG}, high-pitched but full bodied, clean start and natural short tail"),
    ("bark_double", 2, 0.9, 0.75, 2, f"two quick barks in a row from {DOG}, excited, natural spacing"),
    ("woof", 2, 0.6, 0.45, 1, f"one soft low muffled 'boof' from {DOG} with mouth almost closed, quiet curious single woof"),
    ("whine", 3, 1.2, 1.0, 1, f"{DOG} giving one short pleading whine for attention, soft nasal whine that rises and fades, not a siren, not long"),
    ("whimper", 3, 0.8, 0.7, 1, f"{DOG} making one soft contented whimper-groan of pleasure while being petted, low and short, relaxed"),
    ("growl", 1, 1.4, 1.2, 1, f"{DOG} giving one low quiet warning growl, small dog chest rumble"),
    ("growl_play", 2, 1.0, 0.9, 1, f"{DOG} playful growl during a gentle tug of war, breathy and bouncy, not aggressive"),
    ("howl", 1, 2.2, 2.0, 1, f"{DOG} one short soft howl, small dog voice, gentle rise and fall"),
    ("sigh", 3, 1.0, 0.8, 1, f"{DOG} lying down and letting out one relaxed deep sigh through the nose, soft exhale, no voice"),
    ("yawn", 2, 1.4, 1.1, 1, f"{DOG} yawning widely with a little squeaky whine at the end"),
    ("pant", 1, 1.6, 1.4, 1, f"{DOG} panting quickly and lightly after playing, rhythmic small breaths, tongue out"),
    ("sniff", 3, 0.7, 0.55, 1, f"{DOG} sniffing the floor, a quick burst of three or four short rapid sniffs through the nose"),
    ("sneeze", 2, 0.5, 0.4, 1, f"{DOG} one small sneeze, tiny snort-sneeze"),
    ("lick", 2, 0.6, 0.4, 1, f"{DOG} giving one wet lick on a human hand, tongue lap and small lip smack"),
    ("lap", 3, 0.5, 0.2, 1, f"one single lap of {DOG} drinking water from a small ceramic bowl, tongue lapping water once"),
    ("chomp", 4, 0.5, 0.3, 1, f"{DOG} crunching one small dry kibble with its teeth, single crunch"),
    ("chew", 2, 0.6, 0.4, 1, f"{DOG} gnawing on a rubber chew toy, one short chew with teeth squeak"),
    ("shake", 1, 1.4, 1.1, 1, f"{DOG} shaking its whole body after waking, fur and ears flapping, no collar, no jingle"),
    ("scratch", 2, 0.7, 0.5, 1, f"{DOG} scratching behind its ear with a hind paw, quick fur scratching"),
    ("step", 4, 0.5, 0.08, 1, f"one single soft footstep of {DOG} on a hard floor, tiny nail click"),
    ("stepsoft", 2, 0.5, 0.08, 1, f"one single very soft padded footstep of {PUP} on a floor"),
    ("thump", 1, 0.5, 0.25, 1, f"{DOG} landing softly on the floor after hopping down from a sofa, soft thud of small paws"),
    ("squeak", 2, 0.5, 0.25, 1, "one squeak of a small rubber squeaky dog toy being bitten"),
    ("kibble", 1, 1.4, 1.2, 1, "a handful of small dry dog kibble poured into a ceramic pet bowl"),
    ("water", 1, 1.8, 1.6, 1, "fresh water poured from a small jug into a ceramic pet bowl"),
    # 노견
    ("bark_old", 2, 0.7, 0.55, 1, f"one single weak hoarse bark from {OLD}"),
    ("whine_old", 2, 1.2, 1.0, 1, f"{OLD} giving one low soft tired whine"),
    ("sigh_old", 2, 1.4, 1.2, 1, f"{OLD} lying down with one long tired groaning sigh through the nose"),
]
EXTRA = 3          # 개수보다 몇 개 더 만들어 고름


def gen(text, dur, path):
    body = json.dumps({"text": f"{text}. {REC}", "duration_seconds": dur, "prompt_influence": 0.7,
                       "model_id": "eleven_text_to_sound_v3"}).encode()
    for a in range(5):
        try:
            req = urllib.request.Request("https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128",
                                         data=body, headers={"xi-api-key": KEY, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as r:
                cost = r.headers.get("character-cost")
                open(path, "wb").write(r.read())
                return int(cost or 0)
        except Exception as e:
            print("  다시", e, flush=True)
            time.sleep(4 + 4 * a)
    return -1


def load(mp3):
    w = mp3[:-4] + ".wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", mp3, "-ac", "1", "-ar", str(SR), w], check=True)
    with wave.open(w) as f:
        return np.frombuffer(f.readframes(f.getnframes()), np.int16).astype(np.float32) / 32768


def env(x, hop=441):
    n = len(x) // hop
    return np.sqrt((x[:n * hop].reshape(n, hop) ** 2).mean(1) + 1e-12)


def trim_score(x, maxlen, events_want):
    """앞뒤 빈 곳을 자르고 점수를 매김 (클수록 좋음). 반환 (점수, 자른 소리)"""
    e = env(x)
    peak = e.max()
    if peak < 1e-3:
        return -99, x
    db = 20 * np.log10(e / peak)
    on = np.where(db > -38)[0]
    a, b = max(0, on[0] - 1), min(len(e), on[-1] + 3)
    y = x[a * 441:b * 441]
    # 길면 가장 센 부분 둘레로 자름
    L = int(maxlen * SR)
    if len(y) > L:
        ey = env(y)
        c = int(np.argmax(ey)) * 441
        s = max(0, min(len(y) - L, c - int(L * 0.3)))
        y = y[s:s + L]
    # 사건 수 (−20dB 위로 올라온 덩어리)
    ey = env(y)
    act = (20 * np.log10(ey / ey.max() + 1e-9) > -20).astype(int)
    k = int(((act[1:] - act[:-1]) == 1).sum() + act[0])
    clip = float((np.abs(x) > 0.985).mean())
    tail = 20 * np.log10(np.sqrt((y[-int(0.03 * SR):] ** 2).mean() + 1e-12) / (np.abs(y).max() + 1e-9))
    head = 20 * np.log10(np.sqrt((y[:int(0.01 * SR)] ** 2).mean() + 1e-12) / (np.abs(y).max() + 1e-9))
    fill = len(y) / L
    sc = 0.0
    sc -= 3 * abs(k - events_want) if events_want <= 2 else 0
    sc -= 400 * clip
    sc += min(0, (-30 - tail)) * -0.0 + (2 if tail < -30 else 0)          # 끝이 조용히 끝남
    sc += 1 if head < -20 else 0                                          # 앞이 갑자기 터지지 않음
    sc += 2 * min(1, fill / 0.5)                                          # 너무 짧게 잘리지 않음
    return sc, y


def finish(y, name):
    # 앞뒤 짧게 부드럽게, 크기 맞춤(최대 −3dB), 16bit
    f = min(len(y) // 4, int(0.004 * SR))
    if f > 0:
        y = y.copy(); y[:f] *= np.linspace(0, 1, f); y[-f * 3:] *= np.linspace(1, 0, f * 3)
    y = y / (np.abs(y).max() + 1e-9) * 0.708
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((y * 32767).astype(np.int16).tobytes())


def main():
    os.makedirs(RAW, exist_ok=True)
    only = set(sys.argv[1:])
    used = 0
    for name, n, dur, maxlen, ev, text in SPEC:
        if only and name not in only:
            continue
        cands = []
        for i in range(n + EXTRA):
            p = os.path.join(RAW, f"{name}_{i}.mp3")
            if not os.path.exists(p) or os.path.getsize(p) < 500:
                c = gen(text, dur, p)
                used += max(0, c)
                if c < 0:
                    continue
            sc, y = trim_score(load(p), maxlen, ev)
            cands.append((sc, i, y))
        cands.sort(key=lambda t: -t[0])
        if not cands:
            print(f"{name}: 실패 — 예전 소리 그대로", flush=True); continue
        # 같은 이름 묶음의 예전(합성) 소리를 지우고 새로 씀
        for f in os.listdir(OUT):
            b = f[:-4].rstrip("0123456789")
            if f.endswith(".wav") and b == name:
                os.remove(os.path.join(OUT, f))
        for j, (sc, i, y) in enumerate(cands[:n]):
            finish(y, f"{name}{j + 1}" if n > 1 else name)
        print(f"{name}: 후보 {len(cands)} → {min(n, len(cands))}개, 점수 {[round(c[0], 1) for c in cands]}, 누적 {used}", flush=True)


if __name__ == "__main__":
    main()
