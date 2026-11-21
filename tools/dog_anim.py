#!/usr/bin/env python3
"""말티즈 움직임 만들기 → ios/AnotherFam/Model/dog_anim.bin
자세(몸 높이·기울기, 등·목·머리, 발 닿는 점)를 적으면 다리는 풀어서(IK) 관절 돌림으로 바꾸고, 동작마다 초당 30장으로 구워 담음.
앱은 이 동작들을 나이에 맞게 골라 이어 붙이고(몸 전체 동작 + 머리 동작 겹치기), 그 위에 숨·눈 깜빡임·꼬리 흔들기·귀 출렁임·바라보기·소리 맞춘 입을 얹음.
사용: python3 tools/dog_anim.py [--sheet]"""
import os, sys, json, struct, copy
import numpy as np
from dogrig import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'ios', 'AnotherFam', 'Model')
FPS = 30
LEGS = ("FL", "FR", "HL", "HR")
D = dict(dx=0., dy=0., dz=0., pitch=0., yaw=0., roll=0., sp=(0., 0., 0.), ch=(0., 0., 0.), nk=(0., 0., 0.), hd=(0., 0., 0.),
         jaw=0., ear=(0., 0.), tail=(0., 0.), FL=(0., 0., 0., 0.), FR=(0., 0., 0., 0.), HL=(0., 0., 0., 0.), HR=(0., 0., 0., 0.),
         lid=0., tongue=0., wag=.3, sq=0.)


def S(base=None, **kw):
    s = copy.deepcopy(base if base is not None else D)
    s.update(kw)
    return s


def lerp(a, b, t):
    if isinstance(a, tuple):
        if a and a[0] == 'a' or b and b[0] == 'a': return a if t < .5 else b
        return tuple(x + (y - x) * t for x, y in zip(a, b))
    return a + (b - a) * t


def mix(a, b, t):
    return {k: lerp(a[k], b[k], t) for k in a}


def solve(s, pre=0.):
    """자세 → (뿌리 옮김 3, 관절 사원수 NJ×4, 덤 4). 디딘 발이 땅에 못 닿으면(다리가 다 펴짐) 몸을 그만큼 내림.
    pre: 미리 내려 둘 몸 높이 (clip 이 앞뒤 장과 이어지게 고른 값)"""
    q = np.tile(QI, (NJ, 1))
    q[IDX["root"]] = qeuler(s["pitch"], s["yaw"], s["roll"])
    for n, k in (("spine", "sp"), ("chest", "ch"), ("neck", "nk"), ("head", "hd")):
        q[IDX[n]] = qeuler(*s[k])
    q[IDX["jaw"]] = rx(s["jaw"])
    q[IDX["earL"]] = qmul(rz(s["ear"][0]), rx(s["ear"][1])); q[IDX["earR"]] = qmul(rz(-s["ear"][0]), rx(s["ear"][1]))
    L, C = s["tail"]
    for n, a in (("tail1", L), ("tail2", C * .5), ("tail3", C * .3), ("tail4", C * .2)): q[IDX[n]] = rx(a)
    pos = np.array([s["dx"], s["dy"] - pre, s["dz"]])
    for it in range(3):
        R, T, _ = fk(q, pos)
        for leg in LEGS:
            side = 1 if leg[1] == "L" else -1
            i0 = IDX[leg + "0"]; par = PARENT[i0]
            v = s[leg]
            if v[0] == 'a':
                q[i0] = qmul(rz(side * v[2]), rx(v[1])); q[i0 + 1] = rx(v[3]); q[i0 + 2] = rx(v[4])
            else:
                paw = PAW_FRONT if leg[0] == "F" else PAW_HIND
                c = STANCE[leg] + np.array([side * v[0], v[1], v[2]])
                tgt = c - qmat(rx(v[3])) @ paw
                pj = T[par] + R[par] @ (REST[i0] - REST[par])
                q[i0], q[i0 + 1], q[i0 + 2] = leg_ik(leg, R[par], pj, tgt, v[3])
        R, T, _ = fk(q, pos)
        err = 0.
        for leg in LEGS:
            v = s[leg]
            if v[0] != 'a' and v[1] <= .021:
                i2 = IDX[leg + "0"] + 2
                cy = (T[i2] + R[i2] @ (PAW_FRONT if leg[0] == "F" else PAW_HIND))[1]
                err = max(err, cy - v[1])
        if err < .002: break
        pos[1] -= err
    return pos, q, np.array([s["lid"], s["tongue"], s["wag"], s["sq"]])


CLIPS = []


def ease(t):
    return t * t * (3 - 2 * t)


def clip(name, keys, loop=False, speed=0., mod=None, events=(), mask=None, tag="", lin=False):
    """keys: [(시각, 자세)]. mod(자세, t) → 자세 (걸음처럼 식으로 만드는 움직임). mask='head' 면 머리 겹치기 동작"""
    dur = keys[-1][0]
    n = max(2, int(round(dur * FPS)) + (0 if loop else 1))
    fr = []; st = []
    for f in range(n):
        t = f / FPS
        k = 0
        while k < len(keys) - 2 and t >= keys[k + 1][0]: k += 1
        t0, a = keys[k]; t1, b = keys[k + 1]
        u = 0 if t1 <= t0 else min(1, max(0, (t - t0) / (t1 - t0)))
        s = mix(a, b, u if lin else ease(u))
        if mod: s = mod(copy.deepcopy(s), t)
        # 다리 방식(풀기/직접)이 바뀌는 구간은 양 끝을 풀어 사원수로 섞음
        swap = [l for l in LEGS if (a[l][0] == 'a') != (b[l][0] == 'a')]
        p, q, e = solve(s)
        if swap and 0 < u < 1:
            _, qa, _ = solve(mix(a, b, 0)); _, qb, _ = solve(mix(a, b, 1))
            for l in swap:
                for j in range(3):
                    i = IDX[l + "0"] + j
                    q[i] = qslerp(qa[i], qb[i], ease(u))
        fr.append((p, q, e)); st.append((s, swap, u, a, b))
    # 0.10.14: 디딘 발이 못 닿아 몸을 내린 만큼(solve)이 장마다 따로라, 걸음마다 몸이 1~2cm 내려갔다가 한 장 만에 툭 올라왔음
    # (걷기·종종걸음·몸 돌리기에서 덜컥거림) → 앞뒤 0.1초 안에서 가장 많이 내린 만큼을 고르게 이어 다시 풂 (발은 늘 땅에 닿음)
    drop = np.array([st[f][0]["dy"] - fr[f][0][1] for f in range(n)])
    if drop.max() > 5e-4:
        W = 3
        idx = lambda f: f % n if loop else min(n - 1, max(0, f))
        env = np.array([max(drop[idx(f + k)] for k in range(-W, W + 1)) for f in range(n)])
        sm = np.array([np.mean([env[idx(f + k)] for k in range(-W, W + 1)]) for f in range(n)])
        for f in range(n):
            s, swap, u, a, b = st[f]
            # 선 몸이고 네 다리 모두 발 닿을 곳으로 푸는 장만 (누운·웅크린 자세는 더 내리면 다리가 접혀 뒤집히고,
            # 다리를 직접 꺾는 장('a')은 몸만 내려가 발이 바닥 아래로 들어감)
            if sm[f] - drop[f] < 2e-4 or s["dy"] < -.03 or swap or any(s[l][0] == 'a' for l in LEGS): continue
            fr[f] = solve(s, pre=sm[f])
    CLIPS.append(dict(name=name, n=n, loop=loop, speed=speed, events=[[round(float(t), 3), e] for t, e in events], mask=mask or "", tag=tag, fr=fr))


def hold(name, s, dur=2.0, mod=None, **kw):
    clip(name, [(0, s), (dur, s)], loop=True, mod=mod, **kw)


def seq(name, steps, **kw):
    """steps: [(걸리는 시간, 자세)] — 첫 항목의 시간은 0"""
    t = 0; ks = []
    for dt, s in steps:
        t += dt; ks.append((t, s))
    clip(name, ks, **kw)


# ---------------- 기본 자세 ----------------
STAND = S()
SIT = S(dy=-.088, pitch=-.62, dz=.03, sp=(.10, 0, 0), ch=(.22, 0, 0), nk=(.14, 0, 0), hd=(.16, 0, 0), tail=(-.15, 0),
        HL=(.014, .012, .112, -1.3), HR=(.014, .012, .112, -1.3))
DOWN = S(dy=-.101, pitch=-.03, nk=(-.25, 0, 0), hd=(.22, 0, 0), tail=(-.25, -.1),
         FL=(.004, .02, .085, -1.45), FR=(.004, .02, .085, -1.45), HL=(.016, .014, .10, -1.3), HR=(.016, .014, .10, -1.3))
REST_ = S(DOWN, nk=(.42, 0, 0), hd=(.2, 0, 0), ear=(.15, 0), lid=.25, wag=0)
SPLOOT = S(DOWN, dy=-.104, HL=('a', 1.45, .35, -.5, .9), HR=('a', 1.45, .35, -.5, .9), tail=(-.5, -.2))
SIDE = S(dy=-.108, roll=1.42, dx=-.02, sp=(0, 0, 0), nk=(.1, 0, -.1), hd=(.1, 0, 0), tail=(-.9, -.5), wag=0,
         FL=('a', -.75, .12, .5, .3), FR=('a', -.55, -.22, .7, .3), HL=('a', -.55, .12, .5, -.2), HR=('a', -.35, -.22, .6, -.2))
CURL = S(DOWN, dy=-.103, roll=.35, sp=(.1, .55, 0), ch=(.1, .45, 0), nk=(.45, .75, 0), hd=(.3, .5, .2), tail=(-.6, .3), lid=1, wag=0,
         HL=(.03, .014, .12, -1.3), HR=(.0, .014, .09, -1.3))
# 배 보이기 (0.10.0): 완전히 뒤집혀 목을 세운 채 버티던 자세(0.9) → 등을 대고 한쪽으로 살짝 기운 채 몸을 C자로 휘고,
# 머리는 옆얼굴을 바닥에 툭 내려놓고, 앞발은 가슴 위로 접고, 뒷다리는 벌려 무릎을 굽힘 (실제 강아지가 배를 내보이며 늘어진 모습)
BELLY = S(dy=-.106, roll=2.6, sp=(0, .22, 0), ch=(0, .16, 0), nk=(-.55, .25, -.35), hd=(-.25, .2, -.7), tail=(-.6, -.4), ear=(.6, .2), jaw=.12, tongue=.3, lid=.35, wag=.3,
          FL=('a', -1.15, .25, 1.9, 1.3), FR=('a', -1.4, .2, 2.0, 1.2), HL=('a', -.6, .9, -1.5, .9), HR=('a', -.45, .7, -1.6, .8))
BOW = S(pitch=.42, dy=-.012, dz=-.01, sp=(-.1, 0, 0), ch=(-.1, 0, 0), nk=(-.45, 0, 0), hd=(.05, 0, 0), tail=(.25, .1), wag=1,
        FL=(.012, .014, .10, -1.3), FR=(.012, .014, .10, -1.3))
BEG = S(SIT, dy=-.082, pitch=-1.2, dz=.055, sp=(.1, 0, 0), ch=(.25, 0, 0), nk=(.45, 0, 0), hd=(.5, 0, 0),
        FL=('a', -.9, .05, 1.5, 1.1), FR=('a', -.9, .05, 1.5, 1.1), HL=(.02, .012, .10, -1.3), HR=(.02, .012, .10, -1.3))
HIND = S(dy=-.035, pitch=-1.15, dz=.085, sp=(.1, 0, 0), ch=(.2, 0, 0), nk=(.5, 0, 0), hd=(.45, 0, 0), wag=1,
         FL=('a', -.7, .05, 1.2, .8), FR=('a', -.7, .05, 1.2, .8), HL=(.01, 0, .05, -.25), HR=(.01, 0, .05, -.25))
CROUCH = S(dy=-.04, pitch=.05, nk=(-.1, 0, 0), FL=(.01, 0, .02, 0), FR=(.01, 0, .02, 0), HL=(.01, 0, .02, 0), HR=(.01, 0, .02, 0))
HELD = S(dy=.0, pitch=-.35, sp=(.15, 0, 0), ch=(.1, 0, 0), nk=(.1, 0, 0), tail=(-.9, -.4), wag=.2,
         FL=('a', -.35, .05, .5, .5), FR=('a', -.3, .05, .6, .5), HL=('a', -.5, .1, -.5, .2), HR=('a', -.4, .1, -.6, .2))
NEWBORN = S(DOWN, dy=-.10, nk=(.3, 0, 0), hd=(.25, 0, 0), lid=1, wag=0, tail=(-.3, 0),
            FL=('a', -.9, .7, .9, .2), FR=('a', -.9, .7, .9, .2), HL=('a', 1.0, .6, -.6, .5), HR=('a', 1.0, .6, -.6, .5))


def sway(a=.01, f=.5, k="roll"):
    def m(s, t):
        s[k] += a * np.sin(2 * np.pi * f * t); return s
    return m


def chain(*ms):
    def m(s, t):
        for x in ms: s = x(s, t)
        return s
    return m


def osc(key, amp, f, ph=0., idx=None):
    def m(s, t):
        v = amp * np.sin(2 * np.pi * (f * t + ph))
        if idx is None: s[key] += v
        else:
            l = list(s[key]); l[idx] += v; s[key] = tuple(l)
        return s
    return m


for nm, p in (("stand", STAND), ("sit", SIT), ("down", DOWN), ("rest", REST_), ("sploot", SPLOOT), ("side", SIDE), ("curl", CURL),
              ("belly", BELLY), ("beg", BEG), ("hind", HIND), ("held", HELD), ("newborn", NEWBORN)):
    hold(nm, p, 2.0, tag="pose")
hold("sit_lazy", S(SIT, roll=.16, dx=-.012, sp=(.1, .12, 0), HL=(.05, .012, .13, -1.3), HR=(-.01, .012, .10, -1.3)), tag="pose")
hold("down_alert", S(DOWN, nk=(-.45, 0, 0), hd=(.3, 0, 0), ear=(.25, -.1), wag=.2), tag="pose")
hold("sleep_side", S(SIDE, lid=1, hd=(.2, 0, 0)), 4.0, tag="pose")
hold("sleep_belly", S(BELLY, lid=1, jaw=.08), 4.0, tag="pose")


def trans(a, b, pa, pb, dur, mids=(), ev=()):
    ks = [(0, pa)] + [(dur * f, m) for f, m in mids] + [(dur, pb)]
    clip(f"{a}>{b}", ks, events=ev, tag="trans")


trans("stand", "sit", STAND, SIT, .7, [(.45, S(SIT, dy=-.05, pitch=-.4, dz=.02))])
trans("sit", "stand", SIT, STAND, .6, [(.5, S(STAND, dy=-.03, pitch=-.2, dz=.015))])
trans("sit", "down", SIT, DOWN, .8, [(.5, S(DOWN, dy=-.085, pitch=-.3, dz=.01, FL=(.004, .0, .05, -.6), FR=(.004, .0, .05, -.6)))], [(.7, "thump")])
trans("down", "sit", DOWN, SIT, .8, [(.5, S(SIT, dy=-.09, pitch=-.3, dz=.015))])
trans("stand", "down", STAND, DOWN, .9, [(.4, S(BOW, pitch=.3, wag=.3, nk=(-.3, 0, 0))), (.75, S(DOWN, dy=-.07, pitch=.1))], [(.8, "thump")])
trans("down", "stand", DOWN, STAND, .8, [(.4, S(DOWN, dy=-.06, pitch=-.2, FL=(0, 0, .02, 0), FR=(0, 0, .02, 0))), (.75, S(STAND, dy=-.02, pitch=.06))])
trans("down", "rest", DOWN, REST_, .8)
trans("rest", "down", REST_, DOWN, .6)
trans("down", "sploot", DOWN, SPLOOT, .8)
trans("sploot", "down", SPLOOT, DOWN, .8)
trans("down", "side", DOWN, SIDE, 1.0, [(.5, S(DOWN, roll=.7, dy=-.104, dx=-.01))], [(.75, "thump")])
trans("side", "down", SIDE, DOWN, 1.0, [(.5, S(DOWN, roll=.7, dy=-.104, dx=-.01))])
trans("down", "curl", DOWN, CURL, 1.2)
trans("curl", "down", CURL, DOWN, 1.0)
trans("side", "belly", SIDE, BELLY, .9, [(.5, S(BELLY, roll=2.2))])
trans("belly", "side", BELLY, SIDE, .8, [(.5, S(SIDE, roll=2.2))])
trans("sit", "beg", SIT, BEG, .6)
trans("beg", "sit", BEG, SIT, .5)
trans("stand", "hind", STAND, HIND, .5, [(.4, S(CROUCH, pitch=-.25))])
trans("hind", "stand", HIND, STAND, .45, ev=[(.38, "step")])
trans("stand", "bow", STAND, BOW, .35)
trans("bow", "stand", BOW, STAND, .35)


# ---------------- 걸음 ----------------
def gait(T, stride, duty, offs, lift, bob=0., pitchA=0., rollA=0., spineA=0., fp=.55, yawA=0., headA=0., nb=2, wide=0.):
    def m(s, t):
        for leg in LEGS:
            ph = (t / T + offs[leg]) % 1
            base = s[leg]
            if ph < duty:
                z = stride / 2 - stride * ph / duty; y = 0; p = .12 * (ph / duty - .5)
            else:
                u = (ph - duty) / (1 - duty)
                z = -stride / 2 + stride * (.5 - .5 * np.cos(np.pi * u)); y = lift * np.sin(np.pi * u) ** .8
                p = fp * np.sin(2 * np.pi * u) * (1 if u < .5 else .45)
            s[leg] = (base[0] + wide, base[1] + y, base[2] + z, base[3] + p)
        w = 2 * np.pi * t / T
        s["dy"] += bob * np.cos(nb * w)
        s["pitch"] += pitchA * np.sin(w * (nb / 2) + .6)
        s["roll"] += rollA * np.sin(w)
        s["yaw"] += yawA * np.sin(w)
        s["sp"] = (s["sp"][0] + spineA * np.sin(w * (nb / 2)), s["sp"][1] - yawA * 1.5 * np.sin(w), s["sp"][2])
        s["nk"] = (s["nk"][0] - pitchA * .8 * np.sin(w * (nb / 2) + .6), s["nk"][1], s["nk"][2] - rollA * .6 * np.sin(w))
        s["hd"] = (s["hd"][0] + headA * np.sin(nb * w + 1.), s["hd"][1], s["hd"][2])
        return s
    return m


def steps(T, offs, n=1):
    ev = []
    for k in range(n):
        for leg in LEGS:
            ev.append((((1 - offs[leg]) % 1 + k) * T % (T * n), "step"))
    return sorted(ev)


LAT = dict(HL=0, FL=.25, HR=.5, FR=.75)
TROT = dict(FL=0, HR=.03, FR=.5, HL=.53)
GAL = dict(HL=0, HR=.09, FL=.42, FR=.52)
BND = dict(HL=0, HR=.03, FL=.45, FR=.48)


def loco(name, base, T, stride, duty, offs, **kw):
    g = gait(T, stride, duty, offs, **{k: v for k, v in kw.items() if k not in ("tag", "extra")})
    m = chain(g, kw["extra"]) if "extra" in kw else g
    clip(name, [(0, base), (T, base)], loop=True, speed=stride / (duty * T), mod=m, events=steps(T, offs), tag="loco", lin=True)


loco("walk", S(tail=(.05, 0), wag=.35), .46, .105, .62, LAT, lift=.018, bob=.0025, rollA=.025, yawA=.03, headA=.02)
# 제자리에서 몸 돌리기 걸음 (0.10.13): 앞으로 나가는 보폭 없이 앞발은 도는 쪽, 뒷발은 반대쪽으로 한 발씩 옮겨 디딤
# (0.10.12 까지 제자리에서 돌 땐 '걷기' 동작을 틀어 발이 앞뒤로 미끄러지며 스케이트 타듯 돌았음)
def pivot(name, sgn, T=.42):
    def m(s, t):
        for leg in LEGS:
            ph = (t / T + LAT[leg]) % 1
            side = 1 if leg[0] == "F" else -1                         # 앞발은 도는 쪽, 뒷발은 반대쪽
            a = .022 * sgn * side
            if ph < .6:
                x = a / 2 - a * ph / .6; y = 0
            else:
                u = (ph - .6) / .4
                x = -a / 2 + a * (.5 - .5 * np.cos(np.pi * u)); y = .016 * np.sin(np.pi * u) ** .8
            b = s[leg]
            s[leg] = (b[0] + x * (1 if leg[1] == "L" else -1), b[1] + y, b[2], b[3])
        s["sp"] = (s["sp"][0], sgn * .08, s["sp"][2]); s["nk"] = (s["nk"][0], sgn * .18, s["nk"][2])
        return s
    clip(name, [(0, S(wag=.35)), (T, S(wag=.35))], loop=True, speed=0., mod=m, events=steps(T, LAT), tag="loco", lin=True)


pivot("pivot_l", 1); pivot("pivot_r", -1)
loco("walk_sniff", S(pitch=.1, nk=(.75, 0, 0), hd=(.5, 0, 0), tail=(-.2, 0), wag=.25), .56, .085, .66, LAT, lift=.014, bob=.002, rollA=.02, yawA=.035,
     extra=osc("hd", .12, 3.2, idx=1))
loco("walk_senior", S(dy=-.006, pitch=.04, nk=(.22, 0, 0), sp=(.06, 0, 0), tail=(-.7, -.3), wag=.12), .68, .075, .7, LAT, lift=.01, bob=.002, rollA=.035, yawA=.02, headA=.03, fp=.3)
loco("stalk", S(dy=-.035, pitch=.06, nk=(.1, 0, 0), hd=(-.1, 0, 0), tail=(-.6, -.2), wag=.1, ear=(.2, -.1)), 1.1, .07, .78, LAT, lift=.012, rollA=.01)
loco("backup", S(dy=-.008, nk=(-.1, 0, 0), tail=(-.4, 0)), .5, -.06, .64, LAT, lift=.014, bob=.002, rollA=.02)
loco("trot", S(nk=(-.06, 0, 0), tail=(.1, 0), wag=.5), .33, .15, .46, TROT, lift=.026, bob=.006, pitchA=.012, rollA=.012, headA=.03)
loco("prance", S(nk=(-.3, 0, 0), hd=(.18, 0, 0), tail=(.25, .1), wag=1, ear=(.2, 0)), .36, .12, .44, TROT, lift=.04, bob=.01, pitchA=.02, rollA=.02, headA=.05, fp=.9)
loco("run", S(dy=-.008, nk=(.1, 0, 0), hd=(-.12, 0, 0), tail=(-.5, -.3), ear=(.5, .5), wag=.2), .29, .30, .30, GAL, lift=.04, bob=.014, pitchA=.11, spineA=.22, nb=1, fp=.9)
loco("bound", S(nk=(-.1, 0, 0), tail=(.1, 0), ear=(.4, .3), wag=.7), .36, .16, .36, BND, lift=.045, bob=.02, pitchA=.16, spineA=.16, nb=1, fp=.8)
loco("toddle", S(dy=-.012, nk=(.1, 0, 0), tail=(-.3, 0), wag=.5), .6, .06, .7, LAT, lift=.012, bob=.004, rollA=.07, yawA=.07, headA=.06, wide=.01,
     extra=chain(osc("roll", .03, .7), osc("yaw", .05, .45, .3)))
loco("crawl", S(NEWBORN, dy=-.10, FL=(.035, .012, .04, -1.2), FR=(.035, .012, .04, -1.2), HL=(.04, .012, .09, -1.2), HR=(.04, .012, .09, -1.2)),
     1.5, .028, .7, LAT, lift=.006, rollA=.06, yawA=.14, wide=0., extra=chain(osc("hd", .25, .66, idx=1), osc("nk", .12, 1.33, idx=0)))
loco("army", S(DOWN, dy=-.096, nk=(-.2, 0, 0), wag=.8, tail=(-.3, 0)), .7, .05, .7, LAT, lift=.008, rollA=.05, yawA=.06)


# 제자리에서 몸을 돌리기 (0.10.13): 몸통 한가운데를 축으로 돌고, 네 발은 땅을 디딘 채로 한 발씩 들어 옮겨 디딤.
# 0.10.12 까지: 뿌리(엉덩이)를 축으로 몸만 돌리고 발 자리는 그대로 둬서 ① 엉덩이·뒷발은 제자리에 박힌 채 머리·앞몸만 360° 빙빙 돌고
# ② 뒷다리가 구부러진 채 제 축으로 비틀려 돌았음 (로봇 다리처럼)
BODY_C = np.array([0., 0., (STANCE["FL"][2] + STANCE["HL"][2]) / 2])
STEP_ORDER = dict(FL=0., HR=.25, FR=.5, HL=.75)


def plant_turn(yaw_fn, T, P, lift=.022):
    """yaw_fn(t): 몸이 바라보는 쪽 (0 → 끝). P: 한 발이 한 번 옮겨 디디는 주기. 발은 디딘 자리에 머물다가 차례가 되면 들어서
    몸이 조금 뒤 바라볼 쪽으로 미리 옮겨 디딤 (몸이 따라옴)"""
    r0 = REST[IDX["root"]]
    def foot_yaw(t, leg):
        off = STEP_ORDER[leg]
        x = t / P - off
        n = np.floor(x); u = x - n
        # k 번째 걸음으로 디딜 곳: 발을 내려놓는 때(.5P)보다 반 걸음(.5P) 뒤 몸이 바라볼 쪽 → 디딘 동안 몸이 발 위를 지나가
        # 발과 몸 사이 비틀림이 ±반 걸음 몫으로 고르게 (0.10.13 은 .75 라 한쪽으로 치우쳐 더 비틀렸음)
        tgt = lambda k: yaw_fn((k + off + 1.0) * P)
        prev = tgt(n - 1) if n >= 0 else yaw_fn(0)
        if n < 0: return yaw_fn(0), 0.
        if u < .5:
            k = ease(u / .5)
            return prev + (tgt(n) - prev) * k, lift * np.sin(np.pi * u / .5) * (1 if abs(tgt(n) - prev) > 1e-3 else 0)
        return tgt(n), 0.
    def m(s, t):
        y = yaw_fn(t)
        Ry = qmat(qeuler(0, y, 0))
        c = BODY_C
        nr = c + Ry @ (np.array([r0[0], 0, r0[2]]) - c)
        s["dx"] += nr[0] - r0[0]; s["dz"] += nr[2] - r0[2]
        s["yaw"] = y
        for leg in LEGS:
            side = 1 if leg[1] == "L" else -1
            fy, h = foot_yaw(t, leg)
            st = STANCE[leg] + np.array([side * s[leg][0], 0, s[leg][2]])
            w = c + qmat(qeuler(0, fy, 0)) @ (st - c)
            v = s[leg]
            s[leg] = ((w[0] - STANCE[leg][0]) * side, v[1] + h, w[2] - STANCE[leg][2], v[3] - .25 * np.sin(np.pi * min(1, h / max(1e-6, lift))))
        return s
    return m


def turn(name, ang):
    # 0.10.14: 한 걸음에 몸이 40° 넘게 돌지 않게 (전에는 90° 를 0.55초 두 걸음에 돌아 디딘 다리가 크게 비틀렸음)
    P = .26
    T = abs(ang) * .55 + .1
    yaw_fn = lambda t: ang * ease(min(1, max(0, t / T)))
    m0 = plant_turn(yaw_fn, T, P, lift=.018)
    def m(s, t):
        s = m0(s, t)
        k = np.sin(np.pi * min(1, t / T))
        s["nk"] = (0, ang * .25 * (1 - ease(min(1, t / T))), 0); s["sp"] = (0, -ang * .1 * k, 0)
        return s
    D_ = T + P * 1.6                                              # 몸이 다 돈 뒤 남은 발을 마저 디딤
    clip(name, [(0, STAND), (D_, STAND)], mod=m, events=[(P * (i + .45), "step") for i in range(int(D_ / P * 2))], tag="turn", lin=True)


turn("turn_l", np.pi / 2); turn("turn_r", -np.pi / 2); turn("turn_back", np.pi)


# ---------------- 서서 하는 동작 ----------------
# 0.10.14: 털기를 초당 7.5~8번으로 흔들었더니 앱이 몸을 다시 그리는 빠르기(초당 수십 번, 일정하지 않음)와 맞물려
# 머리·몸·다리가 한쪽으로 빙글빙글 도는 것처럼 보였음(마차 바퀴 착시). 화면에서 흔들림으로 읽히는 초당 4번 안쪽으로 — 다른 흔들기도 같음
def shake_mod(amp=.22, f=4.0, dur=1.3):
    def m(s, t):
        k = np.sin(np.pi * min(1, t / dur)) ** .7
        a = amp * k * np.sin(2 * np.pi * f * t)
        s["roll"] += a * .35; s["sp"] = (s["sp"][0], 0, a * .8); s["ch"] = (s["ch"][0], 0, a * 1.2 * np.sin(2 * np.pi * f * t + .8) / max(1e-3, abs(np.sin(2 * np.pi * f * t)) + .3))
        s["hd"] = (s["hd"][0], 0, 1.6 * amp * k * np.sin(2 * np.pi * f * t + 1.2)); s["ear"] = (.9 * k, 0); s["lid"] = .8 * k; s["tail"] = (s["tail"][0], s["tail"][1])
        return s
    return m


clip("shake", [(0, STAND), (.15, S(dy=-.008, FL=(.012, 0, 0, 0), FR=(.012, 0, 0, 0), HL=(.012, 0, 0, 0), HR=(.012, 0, 0, 0))), (1.3, S(dy=-.008, FL=(.012, 0, 0, 0), FR=(.012, 0, 0, 0), HL=(.012, 0, 0, 0), HR=(.012, 0, 0, 0))), (1.6, STAND)],
     mod=shake_mod(), events=[(.2, "shake")], tag="act")
clip("shake_sit", [(0, SIT), (1.3, SIT), (1.5, SIT)], mod=shake_mod(.18, 4.0, 1.3), events=[(.1, "shake")], tag="act")
seq("stretch_front", [(0, STAND), (.7, S(BOW, pitch=.5, wag=.2, nk=(-.6, 0, 0), FL=(.0, .014, .13, -1.35), FR=(.0, .014, .13, -1.35), jaw=.0)), (1.2, S(BOW, pitch=.52, wag=.2, nk=(-.7, 0, 0), jaw=.5, lid=.9, FL=(.0, .014, .135, -1.35), FR=(.0, .014, .135, -1.35))), (.6, STAND)], tag="act")
seq("stretch_back", [(0, STAND), (.7, S(pitch=-.22, dz=.04, dy=-.004, nk=(-.3, 0, 0), HL=(0, .0, -.075, .75), HR=(0, 0, -.06, .5), tail=(-.6, -.3))), (.9, S(pitch=-.25, dz=.045, nk=(-.4, 0, 0), HL=(0, .008, -.085, .9), HR=(0, 0, -.06, .5), tail=(-.6, -.3))), (.5, STAND)], tag="act")
clip("bow_wiggle", [(0, BOW), (1.6, BOW)], loop=True, mod=chain(osc("sp", .14, 3.2, idx=1), osc("yaw", .05, 3.2, .25), osc("hd", .12, 1.6, idx=2)), tag="act")
seq("pounce", [(0, CROUCH), (.22, S(CROUCH, dy=-.055, pitch=.12, wag=.8)), (.16, S(dy=.05, pitch=-.3, dz=.06, FL=(0, .07, .08, -.5), FR=(0, .07, .08, -.5), HL=(0, .02, -.04, .6), HR=(0, .02, -.04, .6), ear=(.5, .4))),
               (.16, S(dy=.01, pitch=.35, dz=.12, FL=(0, 0, .14, -.1), FR=(0, 0, .14, -.1), HL=(0, .04, .02, .5), HR=(0, .04, .02, .5))), (.18, S(BOW, dz=.12, HL=(0, 0, .12, 0), HR=(0, 0, .12, 0), FL=(.012, .014, .22, -1.3), FR=(.012, .014, .22, -1.3)))],
    events=[(.38, "step"), (.56, "thump")], speed=0, tag="act")
seq("hop", [(0, STAND), (.14, S(CROUCH, dy=-.03)), (.14, S(dy=.05, FL=(0, .03, 0, .3), FR=(0, .03, 0, .3), HL=(0, .035, 0, .4), HR=(0, .035, 0, .4), ear=(.5, 0))), (.16, S(CROUCH, dy=-.02)), (.14, STAND)], events=[(.42, "step")], tag="act")
seq("jump_up", [(0, STAND), (.22, S(CROUCH, dy=-.06, pitch=-.2, nk=(-.4, 0, 0))), (.2, S(dy=.09, pitch=-.75, dz=.05, FL=('a', -.9, .05, 1.2, .6), FR=('a', -.9, .05, 1.2, .6), HL=(0, .03, -.05, .8), HR=(0, .03, -.05, .8), ear=(.4, .4))),
               (.22, S(dy=.2, pitch=-.2, dz=.14, FL=('a', -.7, .05, .6, .2), FR=('a', -.7, .05, .6, .2), HL=('a', .2, .1, -1.2, .4), HR=('a', .2, .1, -1.2, .4))), (.2, S(dy=.0, dz=.0))], events=[(.2, "step"), (.8, "thump")], tag="jump")
seq("jump_down", [(0, STAND), (.2, S(pitch=.35, dy=-.03, nk=(-.3, 0, 0), FL=(0, 0, .03, 0), FR=(0, 0, .03, 0))), (.2, S(pitch=.6, dy=.02, dz=.08, FL=('a', -1.0, .05, .4, .2), FR=('a', -1.0, .05, .4, .2), HL=(0, .02, -.05, .7), HR=(0, .02, -.05, .7), ear=(.6, 0))),
                 (.2, S(pitch=.25, dy=-.03, dz=.02, nk=(-.3, 0, 0), HL=('a', .3, .1, -1.0, .4), HR=('a', .3, .1, -1.0, .4))), (.2, S(CROUCH, dy=-.03)), (.15, STAND)], events=[(.6, "thump"), (.75, "step")], tag="jump")
clip("greet_jump", [(0, HIND), (.9, HIND)], loop=True, mod=chain(lambda s, t: dict(s, dy=s["dy"] + .03 * abs(np.sin(np.pi * t / .3)), FL=('a', -.7 + .5 * np.sin(2 * np.pi * t / .3), .05, 1.2, .8), FR=('a', -.7 + .5 * np.sin(2 * np.pi * t / .3 + 2.2), .05, 1.2, .8)), osc("sp", .08, 3.3, idx=1)),
     events=[(.3, "step"), (.6, "step"), (.89, "step")], tag="act")
clip("hind_paw", [(0, HIND), (1.2, HIND)], loop=True, mod=lambda s, t: dict(s, FL=('a', -.9 + .45 * np.sin(2 * np.pi * t / .4), .05, 1.2, .8), FR=('a', -.9 + .45 * np.sin(2 * np.pi * t / .4 + np.pi), .05, 1.2, .8), dx=.006 * np.sin(2 * np.pi * t / 1.2)), tag="act")
clip("dig", [(0, S(BOW, pitch=.3, wag=.5, nk=(.2, 0, 0), hd=(.3, 0, 0))), (1.2, S(BOW, pitch=.3, wag=.5, nk=(.2, 0, 0), hd=(.3, 0, 0)))], loop=True,
     mod=lambda s, t: dict(s, FL=(.0, .02 + .02 * max(0, np.sin(2 * np.pi * t / .24)), .05 + .04 * np.cos(2 * np.pi * t / .24), -.6), FR=(.0, .02 + .02 * max(0, np.sin(2 * np.pi * t / .24 + np.pi)), .05 + .04 * np.cos(2 * np.pi * t / .24 + np.pi), -.6)),
     events=[(i * .12, "scratch") for i in range(10)], tag="act")
hold("sniff_ground", S(pitch=.12, nk=(.85, 0, 0), hd=(.55, 0, 0), tail=(-.2, 0), wag=.3), 2.4, mod=chain(osc("hd", .16, 1.25, idx=1), osc("nk", .05, 3.3, idx=0), osc("dz", .004, .8)), events=[(.3, "sniff"), (1.1, "sniff"), (1.9, "sniff")], tag="act")
EAT = S(pitch=.1, nk=(.8, 0, 0), hd=(.42, 0, 0), tail=(-.1, 0), wag=.5)
hold("eat", EAT, 1.6, mod=chain(osc("hd", .09, 2.5, idx=0), osc("jaw", .16, 5, .25), lambda s, t: dict(s, jaw=abs(s["jaw"]))), events=[(.0, "chomp"), (.4, "chomp"), (.8, "chomp"), (1.2, "chomp")], tag="act")
# 몇 입 먹고 고개를 들어 씹기 / 물 마시다 고개 들고 입맛 다시기 (0.10.0)
seq("eat_lift", [(0, EAT), (.35, S(nk=(.15, 0, 0), hd=(.12, 0, 0), wag=.5, jaw=.1)), (1.0, S(nk=(.12, 0, 0), hd=(.15, 0, 0), wag=.5, jaw=.1)), (.4, EAT)],
    mod=lambda s, t: dict(s, jaw=s["jaw"] + (abs(.13 * np.sin(2 * np.pi * 3.2 * t)) if .35 < t < 1.35 else 0)), events=[(.45, "chew"), (.75, "chew"), (1.05, "chew")], tag="act")
seq("drink_lift", [(0, S(EAT, nk=(.86, 0, 0), wag=.2)), (.3, S(nk=(.2, 0, 0), hd=(.15, 0, 0), wag=.3)), (.7, S(nk=(.2, 0, 0), hd=(.15, 0, 0), wag=.3)), (.35, S(EAT, nk=(.86, 0, 0), wag=.2))],
    mod=lambda s, t: dict(s, tongue=(.9 if .45 < t < .65 else 0), jaw=(.12 if .45 < t < .65 else 0)), events=[(.5, "lick")], tag="act")
# 장난감 물기·내려놓기: 고개를 바닥까지 숙여 입을 벌렸다 다물고 듦 / 숙여서 입을 벌려 놓음
seq("pick_up", [(0, STAND), (.3, S(pitch=.2, dy=-.006, dz=.012, nk=(1.12, 0, 0), hd=(.55, 0, 0), jaw=.38, wag=.6)), (.08, S(pitch=.2, dy=-.006, dz=.012, nk=(1.12, 0, 0), hd=(.55, 0, 0), jaw=.2, wag=.6)), (.37, S(jaw=.22, wag=.7))], tag="act")
seq("drop_toy", [(0, S(jaw=.22)), (.32, S(pitch=.12, nk=(.95, 0, 0), hd=(.5, 0, 0), jaw=.22)), (.1, S(pitch=.12, nk=(.95, 0, 0), hd=(.5, 0, 0), jaw=.45)), (.38, STAND)], tag="act")
hold("drink", S(EAT, nk=(.86, 0, 0), wag=.2), 1.2, mod=lambda s, t: dict(s, jaw=.14, tongue=.5 + .5 * np.sin(2 * np.pi * t / .3), hd=(s["hd"][0] + .03 * np.sin(2 * np.pi * t / .3), 0, 0)), events=[(.075 + i * .3, "lap") for i in range(4)], tag="act")
hold("pee_squat", S(dy=-.045, pitch=-.28, dz=.01, nk=(-.1, 0, 0), tail=(.35, 0), wag=0, HL=(.03, 0, .02, -.3), HR=(.03, 0, .02, -.3)), 2.0, tag="act")
hold("pee_leg", S(roll=-.12, yaw=.0, tail=(.2, 0), wag=0, HL=('a', -.5, 1.0, -.9, .3)), 2.0, tag="act")
hold("poop", S(dy=-.04, pitch=-.42, dz=.03, sp=(.45, 0, 0), ch=(.2, 0, 0), nk=(-.2, 0, 0), tail=(.5, .2), wag=0, HL=(.03, 0, .06, -.4), HR=(.03, 0, .06, -.4), ear=(.2, .2)), 2.0, mod=osc("dy", .003, 1.), tag="act")
clip("kick_back", [(0, STAND), (1.2, STAND)], mod=lambda s, t: dict(s, HL=(0, .02 * max(0, np.sin(2 * np.pi * t / .3)), -.05 * np.sin(2 * np.pi * t / .3) ** 2, .5 * max(0, np.sin(2 * np.pi * t / .3))),
     HR=(0, .02 * max(0, np.sin(2 * np.pi * t / .3 + np.pi)), -.05 * np.sin(2 * np.pi * t / .3 + np.pi) ** 2, .5 * max(0, np.sin(2 * np.pi * t / .3 + np.pi))), tail=(.2, 0)), events=[(i * .15 + .07, "scratch") for i in range(8)], tag="act")
seq("startle", [(0, STAND), (.1, S(dy=.02, dz=-.03, pitch=-.1, nk=(-.3, 0, 0), ear=(.5, -.2), tail=(-.8, -.4), wag=0)), (.15, S(CROUCH, dz=-.06, nk=(-.25, 0, 0), ear=(.3, .3), tail=(-1.2, -.6), wag=0)), (.6, S(CROUCH, dy=-.02, dz=-.06, tail=(-.9, -.4), wag=0)), (.4, STAND)], events=[(.25, "step")], tag="act")
hold("cower", S(dy=-.05, pitch=.05, nk=(.25, 0, 0), hd=(-.25, 0, 0), ear=(.1, .5), tail=(-2.3, -.6), wag=.05, lid=.2), 2.0, mod=osc("dy", .0015, 9), tag="act")
hold("alert", S(dy=.004, nk=(-.3, 0, 0), hd=(.2, 0, 0), ear=(.35, -.2), tail=(.3, .15), wag=.05), 2.0, tag="act")
seq("bark_body", [(0, STAND), (.08, S(dz=.012, pitch=-.05, FL=(0, .012, .01, 0), FR=(0, .012, .01, 0), tail=(.25, 0))), (.1, S(dz=.004)), (.2, STAND)], events=[(.1, "step")], tag="act")
seq("paw_at", [(0, STAND), (.2, S(roll=.06, FR=(.0, .06, .06, -.7))), (.14, S(roll=.06, FR=(.0, .02, .10, -.2))), (.14, S(roll=.06, FR=(0, .06, .06, -.7))), (.14, S(roll=.06, FR=(0, .02, .10, -.2))), (.2, STAND)], events=[(.34, "pat"), (.62, "pat")], tag="act")
seq("nose_push", [(0, STAND), (.25, S(pitch=.12, nk=(.8, 0, 0), hd=(.3, 0, 0))), (.12, S(pitch=.14, dz=.02, nk=(.7, 0, 0), hd=(.1, 0, 0))), (.3, STAND)], events=[(.37, "pat")], tag="act")
clip("shake_toy", [(0, S(nk=(.2, 0, 0), jaw=.25, ear=(.5, 0), wag=.8)), (1.2, S(nk=(.2, 0, 0), jaw=.25, ear=(.5, 0), wag=.8))], loop=True, mod=chain(osc("nk", .3, 2.5, idx=1), osc("hd", .3, 2.5, .2, idx=2), osc("ch", .08, 2.5, .4, idx=1)), events=[(.0, "shake")], tag="act")
clip("tug", [(0, S(CROUCH, dz=-.03, pitch=-.12, nk=(.15, 0, 0), jaw=.22, wag=.6, tail=(.1, 0))), (1.0, S(CROUCH, dz=-.03, pitch=-.12, nk=(.15, 0, 0), jaw=.22, wag=.6, tail=(.1, 0)))], loop=True, mod=chain(osc("dz", .012, 3), osc("nk", .22, 4, idx=1), osc("hd", .2, 4, .25, idx=2)), tag="act")
clip("wiggle", [(0, S(wag=1)), (1.2, S(wag=1))], loop=True, mod=chain(osc("sp", .2, 3.3, idx=1), osc("yaw", .07, 3.3, .5), osc("ch", .1, 3.3, .25, idx=1), osc("hd", .1, 3.3, idx=2)), tag="act")
seq("look_back", [(0, STAND), (.4, S(sp=(0, .25, 0), ch=(0, .3, 0), nk=(0, .8, 0), hd=(0, .7, 0))), (.9, S(sp=(0, .25, 0), ch=(0, .3, 0), nk=(0, .8, 0), hd=(0, .7, .1))), (.4, STAND)], tag="act")


def spin(name, sgn):
    # 제자리에서 한 바퀴 (꼬리 쫓기·볼일 전 맴돌기·'돌아' 재주): 몸 한가운데를 축으로 2.6초에 한 바퀴,
    # 네 발로 잔걸음으로 돌듯 (한 발이 한 바퀴에 10번 옮겨 디딤). 고개는 도는 쪽으로 조금 앞서 봄
    # 0.10.13 은 1.8초에 5걸음이라 디딘 발 위로 몸이 한 걸음에 75° 가까이 돌아, 다리가 엉덩이를 축으로 크게 비틀려 빙글 돌았음
    T = 2.6
    P = T / 10
    yaw_fn = lambda t: sgn * 2 * np.pi * ease(min(1, max(0, t / T))) ** 1 if t < T else sgn * 2 * np.pi
    lin_yaw = lambda t: sgn * 2 * np.pi * (min(1, max(0, t / T)) * .9 + .1 * ease(min(1, max(0, t / T))))
    m0 = plant_turn(lin_yaw, T, P, lift=.024)
    def m(s, t):
        s = m0(s, t)
        k = np.sin(np.pi * min(1, t / T)) ** .5
        s["sp"] = (0, sgn * .22 * k, 0); s["ch"] = (0, sgn * .14 * k, 0); s["nk"] = (.08, sgn * .35 * k, 0); s["hd"] = (.08, sgn * .2 * k, 0)
        return s
    D_ = T + P * 1.6
    clip(name, [(0, S(wag=.6)), (D_, S(wag=.6))], mod=m, events=[(P * (i + .45), "step") for i in range(int(D_ / P * 2))], tag="act", lin=True)


spin("spin_l", 1); spin("spin_r", -1)
# 강아지 (3~7주): 비틀거림·넘어짐
seq("wobble", [(0, S(dy=-.012, wag=.4)), (.5, S(dy=-.014, roll=.12, yaw=.08, FL=(.012, 0, 0, 0), HR=(.012, 0, 0, 0))), (.5, S(dy=-.012, roll=-.1, yaw=-.06, FR=(.014, 0, .01, 0))), (.5, S(dy=-.012, wag=.4))], loop=True, tag="pup")
seq("tumble", [(0, S(dy=-.012)), (.25, S(dy=-.03, pitch=.3, roll=.15, FL=(.02, 0, -.02, 0), FR=(0, .01, .03, -.4))), (.3, S(DOWN, roll=.9, pitch=.2, dy=-.10, dx=-.02)), (.35, S(SIDE, roll=1.5)), (.5, S(SIDE)), (.5, S(DOWN, roll=.3)), (.5, S(dy=-.012))], events=[(.5, "thump")], tag="pup")
seq("plop", [(0, S(dy=-.012)), (.35, S(SIT, dy=-.08, roll=.1)), (.2, S(SIT, dy=-.092, roll=.14, nk=(.3, 0, 0))), (.6, S(SIT, roll=.12))], events=[(.5, "thump")], tag="pup")
# 갓난 강아지 (0~2주): 눈 감고 꼬물거림
hold("nb_squirm", NEWBORN, 2.4, mod=chain(osc("yaw", .12, .42), osc("hd", .35, .83, idx=1), osc("nk", .15, 1.25, idx=0), osc("roll", .06, .6, .3),
     lambda s, t: dict(s, FL=('a', -.9 + .3 * np.sin(2 * np.pi * t / 1.2), .7, .9, .2), HR=('a', 1.0 + .25 * np.sin(2 * np.pi * t / 1.2 + 1), .6, -.6, .5))), tag="nb")
hold("nb_root", S(NEWBORN, nk=(-.1, 0, 0), hd=(-.1, 0, 0)), 1.6, mod=chain(osc("hd", .45, 1.25, idx=1), osc("nk", .22, 2.5, idx=0), osc("jaw", .06, 5)), tag="nb")
hold("nb_nurse", S(NEWBORN, nk=(-.35, 0, 0), hd=(-.3, 0, 0), jaw=.1), 1.2, mod=chain(osc("nk", .05, 3.33, idx=0), lambda s, t: dict(s, jaw=.08 + .05 * np.sin(2 * np.pi * t / .3),
     FL=('a', -.9 + .35 * np.sin(2 * np.pi * t / .6), .6, .9, .2), FR=('a', -.9 + .35 * np.sin(2 * np.pi * t / .6 + np.pi), .6, .9, .2))), events=[(i * .3, "suck") for i in range(4)], tag="nb")
# 갓난 강아지 잠: 옆으로 완전히 누워 몸 옆면이 바닥에 닿음 (0.4.0 까지: 엎드린 자세를 0.5만 굴려 몸 반쪽·뒷다리가 공중에 뜸)
NB_SLEEP = S(SIDE, dy=-.112, lid=1, wag=0, tail=(-.4, 0), nk=(.2, 0, -.12), hd=(.15, 0, -.05),
             FL=('a', -.6, .10, .45, .35), FR=('a', -.45, -.18, .6, .35), HL=('a', -.35, .10, .45, -.1), HR=('a', -.25, -.18, .55, -.1))
hold("nb_sleep", NB_SLEEP, 4.0, mod=lambda s, t: dict(s, HL=('a', -.35 + (.22 * np.sin(2 * np.pi * t / .25) if 1.2 < t < 1.7 else 0), .10, .45, -.1), jaw=(.06 if 2.6 < t < 2.9 else 0)), tag="nb")
# 노견
seq("senior_rise", [(0, DOWN), (.9, S(DOWN, dy=-.085, pitch=-.25, FL=(0, 0, .03, 0), FR=(0, 0, .03, 0))), (.7, S(DOWN, dy=-.08, pitch=-.3, FL=(0, 0, .02, 0), FR=(0, 0, .02, 0))), (1.0, S(dy=-.03, pitch=.1, HL=(0, 0, .03, 0), HR=(.01, 0, .02, 0))), (.6, S(dy=-.006, nk=(.2, 0, 0)))], tag="senior")
seq("senior_down", [(0, STAND), (.8, S(dy=-.03, pitch=.15, nk=(.2, 0, 0))), (.9, S(DOWN, dy=-.07, pitch=.22, HL=(0, 0, .03, 0), HR=(0, 0, .03, 0))), (.9, DOWN)], events=[(2.2, "thump")], tag="senior")
hold("doze_sit", S(SIT, lid=.85), 4.0, mod=lambda s, t: dict(s, nk=(.14 + .45 * ease(min(1, t / 2.6)) * (1 if t < 2.7 else max(0, 1 - (t - 2.7) / .25)), 0, 0), lid=.85 if t < 2.7 or t > 3.3 else .2), tag="senior")

# ---------------- 앉아서 ----------------
def scratch(name, sgn):
    leg = "HL" if sgn > 0 else "HR"
    # 0.10.14: 긁는 다리를 들어 올리는 동안(.4초)도 그 자세로 이어지게 'a' 자세를 base 에 넣음 — 전에는 .4초에 앉은 다리에서
    # 긁는 다리로 한 장 만에 휙 바뀌었음. 긁기는 초당 7번 → 4번 (털기와 같은 까닭: 화면에서 다리가 빙글 도는 것처럼 보였음)
    base = S(SIT, roll=-sgn * .14, sp=(.1, sgn * .2, 0), nk=(.3, sgn * .5, 0), hd=(.3, sgn * .3, sgn * .5), lid=.6, ear=(.3, 0), wag=0)
    base[leg] = ('a', -1.9, .55, -1.0, .2)
    def m(s, t):
        k = min(1, (t - .4) / .15, (2.1 - t) / .15)
        s[leg] = ('a', -1.9 + .24 * k * np.sin(2 * np.pi * (t - .4) / .25), .55, -1.0, .2 + .35 * k * np.sin(2 * np.pi * (t - .4) / .25))
        s["hd"] = (s["hd"][0], s["hd"][1], s["hd"][2] + .05 * k * np.sin(2 * np.pi * (t - .4) / .25))
        return s
    seq(name, [(0, SIT), (.4, base), (1.7, base), (.4, SIT)], mod=lambda s, t: m(s, t) if .4 < t < 2.1 else s, events=[(.46 + i * .25, "scratch") for i in range(7)], tag="act")


scratch("scratch_l", 1); scratch("scratch_r", -1)
clip("beg_paws", [(0, BEG), (1.0, BEG)], loop=True, mod=lambda s, t: dict(s, FL=('a', -.9 + .35 * np.sin(2 * np.pi * t / .5), .05, 1.5, 1.1), FR=('a', -.9 + .35 * np.sin(2 * np.pi * t / .5 + .6), .05, 1.5, 1.1), dy=s["dy"] + .004 * np.sin(2 * np.pi * t)), tag="act")
for nm, leg, sgn in (("paw_l", "FL", 1), ("paw_r", "FR", -1)):
    up = S(SIT, roll=-sgn * .07, wag=.6, **{leg: ('a', -1.25, .05, .55, .5)})
    seq(nm, [(0, SIT), (.35, up), (1.2, S(up, hd=(.1, 0, 0))), (.35, SIT)], tag="trick")
    hi = S(BEG, roll=-sgn * .05, wag=.8, **{leg: ('a', -1.75, .35, .5, -.3)})
    seq("five_" + nm[-1], [(0, SIT), (.35, BEG), (.2, hi), (.5, hi), (.2, BEG), (.3, SIT)], events=[(.6, "pat")], tag="trick")
hold("lean", S(SIT, roll=.2, dx=.015, nk=(.1, 0, .25), hd=(.1, 0, .2), lid=.5, wag=.5), 2.0, tag="pet")
# ---------------- 엎드려·누워서 ----------------
hold("chew", S(DOWN, nk=(.25, 0, 0), hd=(.4, 0, .25), FL=(-.012, .02, .085, -1.45), FR=(-.012, .02, .085, -1.45), wag=.3), 1.6, mod=chain(osc("jaw", .16, 2.5, .25), lambda s, t: dict(s, jaw=abs(s["jaw"])), osc("hd", .1, 1.25, idx=2), osc("hd", .04, 2.5, idx=0)),
     events=[(.0, "chew"), (.4, "chew"), (.8, "chew"), (1.2, "chew")], tag="act")
hold("lick_paw", S(DOWN, nk=(.4, -.25, 0), hd=(.45, -.1, 0), FR=(-.01, .03, .075, -1.3), jaw=.1, wag=0), 1.2, mod=lambda s, t: dict(s, tongue=.5 + .5 * np.sin(2 * np.pi * t / .4), hd=(.45 + .08 * np.sin(2 * np.pi * t / .4), -.1, 0)), events=[(.1, "lick"), (.5, "lick"), (.9, "lick")], tag="act")
seq("roll_over", [(0, DOWN), (.3, S(DOWN, roll=.9, dx=-.01)), (.25, S(SIDE)), (.3, S(BELLY, roll=3.14)), (.3, S(SIDE, roll=4.86, dx=.02)), (.25, S(DOWN, roll=5.5)), (.25, S(DOWN, roll=6.283))], events=[(.5, "thump")], tag="trick")
hold("belly_wriggle", BELLY, 1.6, mod=chain(osc("sp", .22, 1.25, idx=1), osc("roll", .16, 1.25, .25), osc("hd", .12, 1.25, .5, idx=2),
     lambda s, t: dict(s, HL=('a', -.6 + .35 * np.sin(2 * np.pi * t / .8), .9, -1.5, .9), HR=('a', -.45 + .35 * np.sin(2 * np.pi * t / .8 + 2), .7, -1.6, .8),
                       FL=('a', -1.15 + .2 * np.sin(2 * np.pi * t / .8 + 1), .25, 1.9, 1.3), jaw=.2, tongue=.4, wag=.8)), tag="act")
# 배를 쓰다듬으면: 눈을 가늘게 뜨고 뒷다리 하나를 톡톡 차며(긁어 주는 곳을 따라) 앞발을 오므림
hold("belly_rub", S(BELLY, lid=.7, jaw=.15, tongue=.45, wag=.6), 1.2, mod=lambda s, t: dict(s, HL=('a', -.6 + .45 * np.sin(2 * np.pi * t / .22), .9, -1.5 - .3 * np.sin(2 * np.pi * t / .22), .9),
     FL=('a', -1.15, .25, 1.9 + .12 * np.sin(2 * np.pi * t / .6), 1.3), hd=(-.25, .2, -.7 + .05 * np.sin(2 * np.pi * t / 1.2))), tag="pet")
hold("dream", S(SIDE, lid=1), 3.0, mod=lambda s, t: dict(s, FL=('a', -.75 + (.22 * np.sin(2 * np.pi * t / .22) if .6 < t < 1.5 else 0), .1, .5, .3 + (.3 * np.sin(2 * np.pi * t / .22 + 1) if .6 < t < 1.5 else 0)),
     HL=('a', -.55 + (.2 * np.sin(2 * np.pi * t / .22 + 2) if .8 < t < 1.7 else 0), .1, .5, -.2), jaw=(.07 if 1.0 < t < 1.2 or 1.4 < t < 1.55 else 0), ear=(.15 * (1 if 2.0 < t < 2.1 else 0), 0), lid=1 - (.12 if 1.1 < t < 1.6 else 0)), events=[(1.0, "whimper")], tag="sleep")
seq("side_stretch", [(0, SIDE), (.8, S(SIDE, sp=(-.2, 0, 0), nk=(-.3, 0, -.1), FL=('a', -1.2, .1, .1, -.3), FR=('a', -1.0, .05, .1, -.3), HL=('a', .25, .1, .1, .5), HR=('a', .4, .05, .1, .5), jaw=.3, lid=1)), (.9, S(SIDE, sp=(-.22, 0, 0), nk=(-.35, 0, -.1), FL=('a', -1.25, .1, .05, -.3), FR=('a', -1.05, .05, .05, -.3), HL=('a', .3, .1, .05, .5), HR=('a', .45, .05, .05, .5), jaw=.45, lid=1)), (.7, SIDE)], tag="act")
seq("wake", [(0, S(REST_, lid=1)), (.6, S(REST_, lid=.5)), (.6, S(DOWN, lid=.3, nk=(-.1, 0, 0))), (.5, S(DOWN, lid=0))], tag="sleep")
hold("sleep_rest", S(REST_, lid=1, hd=(.2, 0, .15)), 4.0, tag="pose")
hold("sleep_curl", CURL, 4.0, tag="pose")
# 안겼을 때 버둥
hold("held_wiggle", HELD, 1.2, mod=lambda s, t: dict(s, HL=('a', -.5 + .35 * np.sin(2 * np.pi * t / .4), .1, -.5, .2), HR=('a', -.4 + .35 * np.sin(2 * np.pi * t / .4 + np.pi), .1, -.6, .2), sp=(.15, .1 * np.sin(2 * np.pi * t / .6), 0), wag=.9), tag="held")
hold("held_calm", S(HELD, lid=.4, nk=(.2, 0, 0), wag=.4), 2.0, tag="held")
# 쓰다듬을 때
hold("pet_head", S(SIT, nk=(.0, 0, 0), hd=(-.12, 0, 0), lid=.75, ear=(.1, .3), wag=.8), 2.0, mod=osc("hd", .05, .8, idx=0), tag="pet")
hold("pet_back", S(dy=-.01, sp=(-.08, 0, 0), nk=(-.2, 0, 0), hd=(.1, 0, 0), lid=.5, tail=(.25, .1), wag=.9), 2.0, mod=chain(osc("sp", .05, 1., idx=1), osc("dy", .003, 1.)), tag="pet")
hold("pet_chin", S(SIT, nk=(-.35, 0, 0), hd=(-.3, 0, 0), lid=.8, wag=.7), 2.0, mod=osc("hd", .05, .7, idx=2), tag="pet")
hold("pet_down", S(DOWN, nk=(.1, 0, 0), hd=(.15, 0, .15), lid=.8, wag=.5), 2.0, tag="pet")
# 옆으로 툭 누워 쓰다듬기를 즐김 (0.10.1): 눈을 가늘게, 꼬리를 바닥에 살랑, 숨에 따라 배가 오르내림
hold("pet_side", S(SIDE, lid=.75, wag=.35, hd=(.1, 0, .05)), 2.4, mod=chain(osc("dy", .002, .45), osc("tail", .25, 1.1, idx=1)), tag="pet")
# 앉아서 손에 머리를 기댐 (고개를 손 쪽으로 밀며 눈을 감음)
hold("pet_sit_lean", S(SIT, nk=(.05, .18, .12), hd=(-.05, .25, .25), lid=.85, ear=(.05, .35), wag=.7), 2.2, mod=osc("hd", .06, .9, idx=1), tag="pet")

# ---------------- 머리 겹치기 동작 (서 있는 자세 기준 차이만 씀) ----------------
def head(name, steps, loop=False, mod=None, events=()):
    t = 0; ks = []
    for dt, kw in steps:
        t += dt; ks.append((t, S(**kw)))
    clip(name, ks, loop=loop, mod=mod, events=events, mask="head", tag="head")


head("look_l", [(0, {}), (.3, dict(nk=(0, .45, 0), hd=(0, .4, 0))), (1.0, dict(nk=(0, .45, 0), hd=(0, .4, 0))), (.35, {})])
head("look_r", [(0, {}), (.3, dict(nk=(0, -.45, 0), hd=(0, -.4, 0))), (1.0, dict(nk=(0, -.45, 0), hd=(0, -.4, 0))), (.35, {})])
head("look_up", [(0, {}), (.3, dict(nk=(-.35, 0, 0), hd=(-.4, 0, 0))), (1.2, dict(nk=(-.35, 0, 0), hd=(-.4, 0, 0))), (.35, {})])
head("look_down", [(0, {}), (.3, dict(nk=(.4, 0, 0), hd=(.35, 0, 0))), (.9, dict(nk=(.4, 0, 0), hd=(.35, 0, 0))), (.35, {})])
head("tilt_l", [(0, {}), (.22, dict(hd=(0, 0, .5), ear=(.3, -.1))), (1.1, dict(hd=(0, 0, .5), ear=(.3, -.1))), (.3, {})])
head("tilt_r", [(0, {}), (.22, dict(hd=(0, 0, -.5), ear=(.3, -.1))), (1.1, dict(hd=(0, 0, -.5), ear=(.3, -.1))), (.3, {})])
head("tilt_lr", [(0, {}), (.2, dict(hd=(0, 0, .45), ear=(.3, 0))), (.6, dict(hd=(0, 0, .45), ear=(.3, 0))), (.3, dict(hd=(0, 0, -.45), ear=(.3, 0))), (.7, dict(hd=(0, 0, -.45), ear=(.3, 0))), (.3, {})])
head("yawn", [(0, {}), (.5, dict(nk=(-.2, 0, 0), hd=(-.25, 0, 0), jaw=.55, lid=.9, tongue=.25, ear=(.1, .3))), (.7, dict(nk=(-.3, 0, 0), hd=(-.35, 0, .08), jaw=.85, lid=1, tongue=.5, ear=(.1, .4))), (.35, dict(nk=(-.1, 0, 0), jaw=.1, lid=.6)), (.3, {})], events=[(.4, "yawn")])
head("lick_lips", [(0, {}), (.12, dict(jaw=.12, tongue=.9)), (.14, dict(jaw=.1, tongue=1, hd=(0, 0, .06))), (.12, dict(jaw=.05, tongue=.2)), (.12, dict(jaw=.12, tongue=.9)), (.14, dict(jaw=.0, tongue=0))], events=[(.1, "lick")])
head("pant", [(0, dict(jaw=.32, tongue=.8, lid=.15)), (.4, dict(jaw=.32, tongue=.8, lid=.15))], loop=True, mod=chain(osc("jaw", .05, 5), osc("tongue", .1, 5, .2), osc("nk", .015, 5, idx=0)))
head("bark", [(0, {}), (.06, dict(nk=(-.18, 0, 0), hd=(-.2, 0, 0), jaw=.5, ear=(.3, .1))), (.1, dict(nk=(-.1, 0, 0), hd=(-.1, 0, 0), jaw=.35)), (.14, {})])
head("bark2", [(0, {}), (.06, dict(nk=(-.18, 0, 0), hd=(-.2, 0, 0), jaw=.5, ear=(.3, .1))), (.1, dict(nk=(-.08, 0, 0), jaw=.1)), (.07, dict(nk=(-.2, 0, 0), hd=(-.22, 0, 0), jaw=.55, ear=(.3, .1))), (.1, dict(jaw=.3)), (.14, {})])
head("howl", [(0, {}), (.4, dict(nk=(-.55, 0, 0), hd=(-.6, 0, 0), jaw=.3, lid=.7, ear=(0, .4))), (1.4, dict(nk=(-.6, 0, 0), hd=(-.65, 0, 0), jaw=.22, lid=.8, ear=(0, .4))), (.4, {})])
head("whine", [(0, {}), (.3, dict(nk=(.15, 0, 0), hd=(-.25, 0, .1), ear=(0, .4), jaw=.06)), (1.0, dict(nk=(.15, 0, 0), hd=(-.25, 0, -.1), ear=(0, .4), jaw=.08)), (.3, {})])
head("sniff_air", [(0, {}), (.3, dict(nk=(-.3, 0, 0), hd=(-.3, 0, 0))), (1.2, dict(nk=(-.3, 0, 0), hd=(-.3, 0, 0))), (.3, {})], mod=chain(osc("hd", .04, 6, idx=0), osc("hd", .1, .8, idx=1)), events=[(.4, "sniff"), (.9, "sniff")])
head("sneeze", [(0, {}), (.25, dict(nk=(-.2, 0, 0), hd=(-.2, 0, 0), lid=.6)), (.07, dict(nk=(.35, 0, 0), hd=(.4, 0, 0), lid=1, jaw=.2)), (.2, dict(nk=(.1, 0, 0), lid=.5)), (.25, {})], events=[(.25, "sneeze")])
head("nod", [(0, {}), (.18, dict(hd=(.3, 0, 0))), (.18, dict(hd=(-.1, 0, 0))), (.18, dict(hd=(.25, 0, 0))), (.2, {})])
head("shake_head", [(0, {}), (.9, {}), (.1, {})], mod=lambda s, t: dict(s, hd=(0, 0, .4 * np.sin(np.pi * min(1, t / .9)) * np.sin(2 * np.pi * 3.5 * t)), ear=(.9 * np.sin(np.pi * min(1, t / .9)), 0), lid=.8 * np.sin(np.pi * min(1, t / .9))), events=[(.05, "flap")])
head("ear_perk", [(0, {}), (.12, dict(ear=(.4, -.25), nk=(-.1, 0, 0))), (.9, dict(ear=(.4, -.25), nk=(-.1, 0, 0))), (.3, {})])
head("ear_back", [(0, {}), (.2, dict(ear=(.05, .5), lid=.3)), (.9, dict(ear=(.05, .5), lid=.3)), (.3, {})])
head("chew_head", [(0, dict(jaw=.05)), (.8, dict(jaw=.05))], loop=True, mod=chain(osc("jaw", .12, 2.5), lambda s, t: dict(s, jaw=abs(s["jaw"])), osc("hd", .04, 1.25, idx=2)), events=[(.1, "chomp"), (.5, "chomp")])
head("lick", [(0, dict(jaw=.12)), (.6, dict(jaw=.12))], loop=True, mod=lambda s, t: dict(s, tongue=.55 + .45 * np.sin(2 * np.pi * t / .3), hd=(-.06 * np.sin(2 * np.pi * t / .3), 0, 0)), events=[(.07, "lick"), (.37, "lick")])
head("growl", [(0, {}), (.2, dict(nk=(.15, 0, 0), hd=(.05, 0, 0), jaw=.07, ear=(0, .35), lid=.2)), (1.2, dict(nk=(.15, 0, 0), hd=(.05, 0, 0), jaw=.09, ear=(0, .35), lid=.2)), (.3, {})])
head("sleepy", [(0, {}), (.8, dict(lid=.75, nk=(.12, 0, 0))), (1.0, dict(lid=.9, nk=(.25, 0, 0))), (.2, dict(lid=.3, nk=(.0, 0, 0))), (.4, {})])
head("blink_slow", [(0, {}), (.35, dict(lid=1)), (.3, dict(lid=1)), (.4, {})])
head("sniff_hand", [(0, {}), (.25, dict(nk=(-.1, 0, 0), hd=(-.1, 0, 0))), (1.2, dict(nk=(-.1, 0, 0), hd=(-.1, 0, 0))), (.3, {})], mod=chain(osc("hd", .05, 5, idx=0), osc("hd", .08, 1.1, idx=1)), events=[(.3, "sniff"), (.8, "sniff"), (1.3, "sniff")])
head("nuzzle", [(0, {}), (.3, dict(nk=(.1, 0, .2), hd=(.15, 0, .3), lid=.8)), (.5, dict(nk=(.1, 0, -.2), hd=(.15, 0, -.3), lid=.8)), (.5, dict(nk=(.1, 0, .2), hd=(.15, 0, .3), lid=.8)), (.4, {})])
head("carry", [(0, dict(jaw=.24, nk=(-.05, 0, 0))), (1.0, dict(jaw=.24, nk=(-.05, 0, 0)))], loop=True)
head("squeak_bite", [(0, dict(jaw=.3)), (.12, dict(jaw=.12)), (.14, dict(jaw=.3)), (.12, dict(jaw=.12)), (.14, dict(jaw=.26))], events=[(.12, "squeak"), (.38, "squeak")])
head("nibble", [(0, dict(jaw=.1)), (.6, dict(jaw=.1))], loop=True, mod=chain(osc("jaw", .1, 6), lambda s, t: dict(s, jaw=abs(s["jaw"])), osc("hd", .06, 3, idx=2)))
head("suckle", [(0, dict(jaw=.08, nk=(-.2, 0, 0), hd=(-.2, 0, 0))), (.6, dict(jaw=.08, nk=(-.2, 0, 0), hd=(-.2, 0, 0)))], loop=True, mod=osc("jaw", .04, 3.33), events=[(0, "suck"), (.3, "suck")])
head("confused", [(0, {}), (.5, dict(nk=(0, .3, 0), hd=(.1, .2, .2))), (.8, dict(nk=(0, -.3, 0), hd=(.1, -.2, -.15))), (.7, dict(nk=(.1, 0, 0), hd=(.1, 0, .25))), (.5, {})])


def write():
    meta = []; blob = bytearray()
    for c in CLIPS:
        meta.append(dict(name=c["name"], n=c["n"], loop=c["loop"], speed=round(float(c["speed"]), 4), events=c["events"], mask=c["mask"], tag=c["tag"], off=len(blob)))
        for p, q, e in c["fr"]:
            a = np.concatenate([np.clip(p * 20000, -32767, 32767), np.clip(q.reshape(-1) * 32767, -32767, 32767), np.clip(e * 8000, -32767, 32767)])
            blob += np.round(a).astype('<i2').tobytes()
    js = json.dumps(dict(v=1, fps=FPS, nj=NJ, stride=3 + NJ * 4 + 4, clips=meta)).encode()
    js += b' ' * ((4 - len(js) % 4) % 4)
    with open(os.path.join(OUT, 'dog_anim.bin'), 'wb') as f:
        f.write(b'AFA1' + struct.pack('<I', len(js)) + js + bytes(blob))
    nf = sum(c["n"] for c in CLIPS)
    print(f"동작 {len(CLIPS)}개 (몸 {sum(1 for c in CLIPS if not c['mask'])}, 머리 {sum(1 for c in CLIPS if c['mask'])}) · {nf}장 · {os.path.getsize(os.path.join(OUT, 'dog_anim.bin')) // 1024} KB")
    json.dump([c["name"] for c in CLIPS], open(os.path.join(os.path.dirname(__file__), '_clips.json'), 'w'))


def frame(name, t=0.):
    c = next(c for c in CLIPS if c["name"] == name)
    return c["fr"][min(c["n"] - 1, int(t * FPS))]


if __name__ == '__main__':
    write()
    if '--sheet' in sys.argv:
        import preview
        def sheet(items, out, **kw):
            nm = []
            for i, (c, t) in enumerate(items):
                p, q, e = frame(c, t)
                preview.export(f's{i}', q, p, extra={"open": 1 - e[0]})
                nm.append(f's{i}')
            preview.shot(nm, out, **kw)
        k = dict(az=50, cols=6, w=1800, h=640, d=1.0, cy=.12)
        sheet([("stand", 0), ("sit", 0), ("down", 0), ("rest", 0), ("sploot", 0), ("side", 0), ("curl", 0), ("belly", 0), ("beg", 0), ("hind", 0), ("stand>bow", .34), ("newborn", 0)], '/home/claude/prev/poses.png', **k)
        sheet([("walk", i * .46 / 6) for i in range(6)] + [("trot", i * .33 / 6) for i in range(6)], '/home/claude/prev/gait1.png', **dict(k, az=90))
        sheet([("run", i * .29 / 6) for i in range(6)] + [("stand>sit", .35), ("sit>down", .4), ("stand>down", .5), ("down>side", .5), ("scratch_l", 1.0), ("paw_l", .8)], '/home/claude/prev/gait2.png', **dict(k, az=90))
        sheet([("eat", .2), ("pee_leg", 0), ("poop", 0), ("stretch_front", 1.2), ("stretch_back", 1.2), ("jump_up", .5), ("pounce", .45), ("cower", 0), ("chew", .3), ("five_l", .8), ("dream", 1.0), ("held", 0)], '/home/claude/prev/acts.png', **k)
