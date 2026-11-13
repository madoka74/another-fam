#!/usr/bin/env python3
"""말티즈 몸 그물 만들기 → ios/AnotherFam/Model/dog.bin (+ fur.png 털 무늬)
거리장(SDF)으로 몸을 빚어 마칭큐브 → 줄이기 → 뼈 무게·털 길이·털 결·무늬 좌표를 붙임. 털은 앱에서 이 그물을 여러 겹(껍데기)으로 부풀려 그림.
몸(몸통·목·머리·주둥이·다리·꼬리) / 아래턱 / 두 귀는 따로 빚어 한 그물에 담음 (입이 벌어지고 귀가 따로 펄럭이게).
사용: python3 tools/dog_build.py"""
import os, json, struct
import numpy as np
from skimage import measure
import fast_simplification
from scipy.spatial import cKDTree
from PIL import Image
from dogrig import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'ios', 'AnotherFam', 'Model')
VOX = 0.0022


def sd_cone(p, a, b, ra, rb):
    """둥근 원뿔 (끝 반지름이 다른 캡슐)"""
    a = np.asarray(a, float); b = np.asarray(b, float)
    ba = b - a
    h = np.clip(((p - a) @ ba) / (ba @ ba), 0, 1)
    return np.linalg.norm(p - a - h[:, None] * ba, axis=1) - (ra + (rb - ra) * h)


def sd_ell(p, c, r):
    q = (p - np.asarray(c, float)) / np.asarray(r, float)
    k = np.linalg.norm(q, axis=1)
    return (k - 1) * min(r)


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b + (a - b) * h - k * h * (1 - h)


def sdf_body(p):
    d = sd_cone(p, (0, .165, -.108), (0, .167, .058), .050, .055)                 # 몸통
    d = smin(d, sd_ell(p, (0, .152, -.02), (.049, .04, .075)), .02)               # 배
    d = smin(d, sd_cone(p, (0, .176, .076), (0, .220, .124), .042, .036), .022)   # 목
    d = smin(d, sd_ell(p, (0, .234, .142), (.046, .043, .047)), .014)             # 머리뼈
    d = smin(d, sd_cone(p, (0, .2255, .172), (0, .2235, .204), .0235, .018), .012)  # 주둥이
    d = smin(d, sd_ell(p, (0, .218, .180), (.028, .014, .02)), .008)              # 윗입술 볼
    for s in (1, -1):
        d = smin(d, sd_cone(p, (s*.036, .146, .066), (s*.040, .085, .058), .027, .0175), .018)
        d = smin(d, sd_cone(p, (s*.040, .085, .058), (s*.040, .034, .066), .0175, .0135), .006)
        d = smin(d, sd_ell(p, (s*.040, .0145, .076), (.0170, .0145, .0225)), .008)
        d = smin(d, sd_cone(p, (s*.038, .146, -.104), (s*.042, .090, -.084), .035, .0205), .02)
        d = smin(d, sd_cone(p, (s*.042, .090, -.084), (s*.042, .048, -.124), .0195, .0125), .006)
        d = smin(d, sd_cone(p, (s*.042, .048, -.124), (s*.042, .022, -.116), .0125, .0125), .004)
        d = smin(d, sd_ell(p, (s*.042, .0145, -.108), (.0170, .0145, .0225)), .008)
    tp = [REST[IDX[n]] for n in ("tail1", "tail2", "tail3", "tail4")] + [np.array(TIPS["tail4"])]
    tr = [.0135, .011, .009, .0075, .006]
    d = smin(d, sd_cone(p, (0, .175, -.130), tp[0], .02, tr[0]), .012)
    for i in range(4):
        d = smin(d, sd_cone(p, tp[i], tp[i+1], tr[i], tr[i+1]), .004)
    return d


def sdf_jaw(p):
    q = p.copy(); q[:, 1] = (q[:, 1] - .212) * 1.5 + .212
    return sd_cone(q, (0, .212, .158), (0, .2105, .1955), .0170, .0120)


def sdf_ear(s):
    def f(p):
        d = sd_ell(p, (s*.050, .234, .136), (.0075, .034, .024))
        return smin(d, sd_ell(p, (s*.045, .260, .138), (.008, .012, .018)), .008)
    return f


def mesh_of(f, lo, hi, target):
    lo = np.asarray(lo); hi = np.asarray(hi)
    n = np.ceil((hi - lo) / VOX).astype(int) + 1
    ax = [lo[i] + np.arange(n[i]) * VOX for i in range(3)]
    g = np.stack(np.meshgrid(*ax, indexing='ij'), -1).reshape(-1, 3)
    vol = np.concatenate([f(g[i:i+400000]) for i in range(0, len(g), 400000)]).reshape(n)
    v, t, _, _ = measure.marching_cubes(vol, 0, spacing=(VOX,)*3)
    v = v + lo
    t = t[:, ::-1]
    v, t = fast_simplification.simplify(v.astype(np.float32), t.astype(np.int32), target_count=target, agg=3)
    v = v.astype(np.float64)
    e = 1e-4
    nr = np.stack([f(v + np.eye(3)[i]*e) - f(v - np.eye(3)[i]*e) for i in range(3)], 1)
    nr /= np.linalg.norm(nr, axis=1, keepdims=True) + 1e-12
    # 바깥을 보게 (법선 쪽으로 감긴 삼각형)
    fn = np.cross(v[t[:, 1]] - v[t[:, 0]], v[t[:, 2]] - v[t[:, 0]])
    if (np.einsum('ij,ij->i', fn, nr[t[:, 0]]) < 0).mean() > .5: t = t[:, ::-1]
    return v, nr, t


def seg_dist(p, a, b):
    a = np.asarray(a, float); b = np.asarray(b, float); ba = b - a
    h = np.clip(((p - a) @ ba) / max(ba @ ba, 1e-12), 0, 1)
    return np.linalg.norm(p - a - h[:, None]*ba, axis=1)


def bone_segs():
    """뼈마다 선분들 (자기 관절 → 자식 관절·끝)"""
    segs = {i: [] for i in range(NJ)}
    for i, n in enumerate(NAMES):
        for j in range(NJ):
            if PARENT[j] == i and not NAMES[j].startswith(("ear", "jaw", "FL0", "FR0", "HL0", "HR0", "tail1")):
                segs[i].append((REST[i], REST[j]))
        if n in TIPS: segs[i].append((REST[i], np.array(TIPS[n])))
    segs[IDX["head"]].append((np.array([0, .234, .142]), np.array([0, .224, .186])))
    segs[IDX["root"]].append((REST[IDX["root"]], np.array([0, .165, -.125])))
    segs[IDX["chest"]].append((REST[IDX["chest"]], np.array([0, .169, .085])))
    return segs


def weights(v, allowed):
    segs = bone_segs()
    D = np.full((len(v), NJ), 9.0)
    for i in allowed:
        if not segs[i]: continue
        d = np.min([seg_dist(v, a, b) for a, b in segs[i]], 0)
        n = NAMES[i]
        if n[0] in "FH" and n[1] in "LR":           # 다리는 같은 쪽만
            side = 1 if n[1] == "L" else -1
            d = np.where(v[:, 0]*side > -.004, d, 9.0)
        D[:, i] = d
    dm = D.min(1, keepdims=True)
    W = np.exp(-(D - dm) / .011)
    W[D > 8] = 0
    idx = np.argsort(-W, 1)[:, :4]
    w = np.take_along_axis(W, idx, 1)
    w[w < .03] = 0
    w /= w.sum(1, keepdims=True)
    return idx, w


def ss(x, a, b):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t*t*(3 - 2*t)


def fur_fields(v, n, part):
    """털 길이(성견, m)·긴 털 정도(0 몸 ~ 1 귀·꼬리)·결(쉬는 자세 방향, 세기 포함)"""
    N = len(v)
    L = np.full(N, .030); lg = np.zeros(N)
    comb = np.tile(np.array([0, -.55, -.35]), (N, 1)) + n * np.array([.25, 0, 0])
    x, y, z = v[:, 0], v[:, 1], v[:, 2]
    if part == "body":
        leg = (y < .112) & (np.abs(x) > .012)
        L = np.where(leg, .027, L)
        L = np.where(y < .034, .019 + .008 * ss(y, .012, .034), L)
        comb[leg] = (0, -.6, -.05)
        head = z > .108
        hl = .029 + .007 * ss(y, .250, .272)
        L = np.where(head, hl, L)
        comb[head] = np.stack([np.sign(x[head]) * .25, np.full(head.sum(), -.6), np.full(head.sum(), .03)], 1)
        muz = (z > .168) & (y < .240)
        L = np.where(muz, .016 + .012 * np.clip(np.abs(x) / .02, 0, 1), L)        # 주둥이 옆은 길게 늘어짐
        tail = (z < -.135) & (y > .182)
        t = ss(y, .182, .235)
        L = np.where(tail, .034 + .018 * t, L); lg = np.where(tail, t, lg)
        comb[tail] = (0, -.7, 0)
        belly = (y < .135) & ~leg & (z < .1)
        comb[belly] = (0, -.7, -.1)
        for s in (1, -1):                                # 눈·코·입 둘레는 짧게 (얼굴이 보이게)
            de = np.linalg.norm(v - np.array([s*EYE[0], EYE[1], EYE[2]]), axis=1)
            L *= .08 + .92 * ss(de, .011, .034)
        dn = np.linalg.norm((v - np.array(NOSE)) * np.array([1, 1.3, 1]), axis=1)
        L *= .04 + .96 * ss(dn, .011, .038)
        front = (z > .186) & (y < .2235)                 # 윗입술 아래
        L = np.where(front, np.minimum(L, .010), L)
    elif part == "jaw":
        L[:] = .014; comb[:] = (0, -.7, .05)
        L *= .2 + .8 * ss(.2175 - y, .0, .012)           # 입 안쪽(윗면)은 짧게
    else:
        t = ss(.264 - y, 0, .05)
        L = .028 + .018 * t; lg = t
        comb[:] = (0, -.8, 0)
    return L, lg, comb


def box_uv(v, n, t, scale=.06):
    """세 축 투영 (삼각형마다 가장 마주 보는 축) — 축이 바뀌는 곳은 점을 나눔. 털 무늬는 무작위라 이음이 안 보임"""
    fn = np.cross(v[t[:, 1]] - v[t[:, 0]], v[t[:, 2]] - v[t[:, 0]])
    ax = np.argmax(np.abs(fn), 1)
    key = {}; src = []; uv = []; nt = np.zeros_like(t)
    for fi in range(len(t)):
        a = ax[fi]
        for k in range(3):
            vi = t[fi, k]
            kk = (vi, a)
            if kk not in key:
                key[kk] = len(src); src.append(vi)
                p = v[vi]
                uv.append([(p[1], p[2]), (p[0], p[2]), (p[0], p[1])][a])
            nt[fi, k] = key[kk]
    return np.array(src), np.array(uv) / scale, nt


def fur_texture(size=512, seed=7):
    """털 높이 무늬 (이어 붙여도 이음 없음): 뭉치마다 뾰족한 봉우리. 알파 = 높이 → 겹(껍데기)마다 문턱을 올리면 위로 갈수록 가늘어짐.
    멀리서 작게 보이면 높이가 평균돼 아래 겹만 남음 (지글거리지 않음)"""
    rng = np.random.default_rng(seed)
    n = 950
    pts = rng.random((n, 2))
    for _ in range(12):                       # 고르게 퍼뜨림
        tr = cKDTree(pts, boxsize=1.0)
        d, j = tr.query(pts, 2)
        dv = pts - pts[j[:, 1]]; dv -= np.round(dv)
        pts = (pts + dv / (np.linalg.norm(dv, axis=1, keepdims=True) + 1e-9) * (.022 - np.minimum(d[:, 1:2], .022)) * .5) % 1
    peak = .45 + .55 * rng.random(n) ** .7
    rad = .030 + .012 * rng.random(n)
    gx, gy = np.meshgrid((np.arange(size) + .5) / size, (np.arange(size) + .5) / size)
    P = np.stack([gx.ravel(), gy.ravel()], 1)
    tr = cKDTree(pts, boxsize=1.0)
    d, j = tr.query(P, 6)
    h = np.max(peak[j] * np.clip(1 - d / rad[j], 0, 1) ** 1.25, 1).reshape(size, size)
    h = .12 + .88 * h                                              # 바닥 겹은 다 채움
    lum = .84 + .16 * h + rng.normal(0, .012, h.shape)             # 뿌리 쪽은 살짝 어둡게 (틈 사이 그늘)
    col = np.zeros((size, size, 3), np.uint8)
    col[..., 0] = np.clip(lum * 255, 0, 255); col[..., 1] = np.clip(lum * 253, 0, 255); col[..., 2] = np.clip(lum * 247, 0, 255)
    hh = np.clip(h * 255, 0, 255).astype(np.uint8)
    # 색 그림과 높이 그림(흰색 = 높음, 가림용)을 따로 — 앱에서 높이 그림을 '불투명도'로 쓰고 겹마다 문턱을 올림
    return Image.fromarray(col, 'RGB'), Image.fromarray(np.stack([hh, hh, hh], -1), 'RGB')


def main():
    os.makedirs(OUT, exist_ok=True)
    parts = [("body", sdf_body, (-.085, -.005, -.20), (.085, .31, .235), 5600, None),
             ("jaw", sdf_jaw, (-.03, .190, .13), (.03, .235, .215), 260, ["jaw"]),
             ("earL", sdf_ear(1), (.025, .19, .10), (.07, .28, .17), 330, ["earL", "head"]),
             ("earR", sdf_ear(-1), (-.07, .19, .10), (-.025, .28, .17), 330, ["earR", "head"])]
    V = []; Nn = []; UV = []; T = []; BI = []; BW = []; FL = []; LG = []; CB = []; PT = []
    off = 0
    for pi, (name, f, lo, hi, target, bones) in enumerate(parts):
        v, n, t = mesh_of(f, lo, hi, target)
        src, uv, t2 = box_uv(v, n, t)
        if bones is None:
            allowed = [i for i, nm in enumerate(NAMES) if nm not in ("jaw", "earL", "earR")]
            bi, bw = weights(v, allowed)
        elif name == "jaw":
            bi = np.zeros((len(v), 4), int); bw = np.zeros((len(v), 4)); bi[:, 0] = IDX["jaw"]; bi[:, 1] = IDX["head"]
            k = ss(v[:, 2], .152, .166); bw[:, 0] = k; bw[:, 1] = 1 - k
        else:
            e = IDX[bones[0]]
            bi = np.zeros((len(v), 4), int); bw = np.zeros((len(v), 4)); bi[:, 0] = e; bi[:, 1] = IDX["head"]
            k = ss(.270 - v[:, 1], 0, .02); bw[:, 0] = k; bw[:, 1] = 1 - k
        L, lg, cb = fur_fields(v, n, "body" if bones is None else ("jaw" if name == "jaw" else "ear"))
        V.append(v[src]); Nn.append(n[src]); UV.append(uv + pi * .37); T.append(t2 + off)
        BI.append(bi[src]); BW.append(bw[src]); FL.append(L[src]); LG.append(lg[src]); CB.append(cb[src]); PT.append(np.full(len(src), pi))
        off += len(src)
        print(name, len(v), '→', len(src), '점', len(t), '삼각형')
    V = np.concatenate(V); Nn = np.concatenate(Nn); UV = np.concatenate(UV); T = np.concatenate(T)
    BI = np.concatenate(BI); BW = np.concatenate(BW); FL = np.concatenate(FL); LG = np.concatenate(LG); CB = np.concatenate(CB); PT = np.concatenate(PT)
    nv, nt = len(V), len(T)
    meta = {"v": 1, "nv": nv, "nt": nt, "joints": [{"n": n, "p": p, "r": list(map(float, REST[i])), "g": GROUP[i]} for i, (n, p) in enumerate(zip(NAMES, PARENT))],
            "tips": {k: list(v) for k, v in TIPS.items()}, "eye": list(EYE), "eyeR": EYE_R, "nose": list(NOSE),
            "pawFront": list(map(float, PAW_FRONT)), "pawHind": list(map(float, PAW_HIND)), "uvTile": .06,
            "noseS": [.0098, .0078, .0072], "hipY": float(REST[IDX["HL0"]][1])}
    js = json.dumps(meta).encode()
    js += b' ' * ((4 - len(js) % 4) % 4)
    with open(os.path.join(OUT, 'dog.bin'), 'wb') as f:
        f.write(b'AFD1' + struct.pack('<I', len(js)) + js)
        # 점마다: 자리3 법선3 무늬2 결3 털길이 긴털 뼈4(float) 무게4  = 21 float
        rec = np.concatenate([V, Nn, UV, CB, FL[:, None], LG[:, None], BI.astype(float), BW], 1).astype('<f4')
        f.write(rec.tobytes())
        f.write(T.astype('<u4').tobytes())
    np.savez(os.path.join(os.path.dirname(__file__), '_dog_cache.npz'), V=V, N=Nn, UV=UV, T=T, BI=BI, BW=BW, FL=FL, LG=LG, CB=CB, PT=PT)
    c, h = fur_texture()
    c.save(os.path.join(OUT, 'fur_c.png')); h.save(os.path.join(OUT, 'fur_h.png'))
    print('dog.bin', nv, '점', nt, '삼각형', os.path.getsize(os.path.join(OUT, 'dog.bin')) // 1024, 'KB')


if __name__ == '__main__':
    main()
