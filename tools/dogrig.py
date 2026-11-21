"""말티즈 뼈대·자세 계산 (도구들이 같이 씀). 앱(Swift DogRig)과 같은 식 — 여기서 그려 보고 확인한 것이 그대로 앱에서 움직임.
좌표: +Z 앞(코), +Y 위, +X 개의 왼쪽. 단위 m, 다 자란 개(성견) 크기 기준. 관절 돌림은 쉬는 자세(서 있음)에서의 차이."""
import numpy as np

# 이름, 부모, 쉬는 자리 (성견)
JOINTS = [
    ("root",  None,    (0, .165, -.100)),
    ("spine", "root",  (0, .169, -.015)),
    ("chest", "spine", (0, .169,  .060)),
    ("neck",  "chest", (0, .190,  .100)),
    ("head",  "neck",  (0, .230,  .132)),
    ("jaw",   "head",  (0, .218,  .154)),
    ("earL",  "head",  ( .041, .258, .138)),
    ("earR",  "head",  (-.041, .258, .138)),
    ("tail1", "root",  (0, .189, -.148)),
    ("tail2", "tail1", (0, .229, -.170)),
    ("tail3", "tail2", (0, .267, -.160)),
    ("tail4", "tail3", (0, .285, -.126)),
    ("FL0", "chest", ( .040, .135, .068)),
    ("FL1", "FL0",   ( .040, .085, .058)),
    ("FL2", "FL1",   ( .040, .034, .066)),
    ("FR0", "chest", (-.040, .135, .068)),
    ("FR1", "FR0",   (-.040, .085, .058)),
    ("FR2", "FR1",   (-.040, .034, .066)),
    ("HL0", "root",  ( .042, .137, -.105)),
    ("HL1", "HL0",   ( .042, .090, -.084)),
    ("HL2", "HL1",   ( .042, .048, -.124)),
    ("HR0", "root",  (-.042, .137, -.105)),
    ("HR1", "HR0",   (-.042, .090, -.084)),
    ("HR2", "HR1",   (-.042, .048, -.124)),
]
NAMES = [j[0] for j in JOINTS]
IDX = {n: i for i, n in enumerate(NAMES)}
PARENT = [(-1 if j[1] is None else IDX[j[1]]) for j in JOINTS]
REST = np.array([j[2] for j in JOINTS], dtype=np.float64)
NJ = len(JOINTS)
# 뼈 끝 (자식이 없는 뼈의 끝 자리)
TIPS = {"head": (0, .224, .205), "jaw": (0, .210, .196), "earL": (.052, .208, .136), "earR": (-.052, .208, .136),
        "tail4": (0, .279, -.088), "FL2": (.040, .010, .080), "FR2": (-.040, .010, .080), "HL2": (.042, .010, -.110), "HR2": (-.042, .010, -.110)}
PAW_FRONT = np.array([0, -.034, .012])     # 손목 → 발바닥 닿는 점
PAW_HIND = np.array([0, -.048, .014])      # 뒤꿈치(비절) → 발바닥 닿는 점
EYE = (0.0205, .2385, .1805)                # 왼눈 가운데 (오른눈은 x 반대)
EYE_R = .0105
NOSE = (0, .2275, .2195)
# 성장 묶음: 뼈마다 어느 비율을 따르는지 (0 몸통, 1 머리, 2 주둥이·턱, 3 귀, 4 꼬리, 5 다리)
GROUP = [0, 0, 0, 0, 1, 2, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]


def qmul(a, b):
    w1, x1, y1, z1 = a; w2, x2, y2, z2 = b
    return np.array([w1*w2 - x1*x2 - y1*y2 - z1*z2, w1*x2 + x1*w2 + y1*z2 - z1*y2,
                     w1*y2 - x1*z2 + y1*w2 + z1*x2, w1*z2 + x1*y2 - y1*x2 + z1*w2])


def qaxis(ax, a):
    s = np.sin(a / 2)
    return np.array([np.cos(a / 2), ax[0]*s, ax[1]*s, ax[2]*s])


def qeuler(x, y, z):
    """Y(좌우) → X(끄덕) → Z(갸웃) 순서: q = qy * qx * qz"""
    return qmul(qmul(qaxis((0, 1, 0), y), qaxis((1, 0, 0), x)), qaxis((0, 0, 1), z))


def qmat(q):
    w, x, y, z = q
    return np.array([[1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w)],
                     [2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w)],
                     [2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y)]])


def qnorm(q):
    return q / np.linalg.norm(q)


def qslerp(a, b, t):
    d = float(np.dot(a, b))
    if d < 0: b = -b; d = -d
    if d > 0.9995: return qnorm(a + (b - a) * t)
    th = np.arccos(d)
    return (np.sin((1 - t) * th) * a + np.sin(t * th) * b) / np.sin(th)


QI = np.array([1.0, 0, 0, 0])


def growth(age_days):
    """나이(개 나이, 날) → 크기·비율. 반환 dict: g(전체), 묶음별 (가로, 세로, 앞뒤) 배율은 scale[묶음]
    말티즈: 태어날 때 약 110g·몸 10cm, 8주 0.7kg, 6달 2.4kg, 1살 3kg(다 자람). 강아지는 머리가 크고 주둥이·다리가 짧고 배가 통통"""
    a = max(0.0, age_days)
    def curve(pts):
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        return float(np.interp(a, xs, ys))
    g = curve([(0, .30), (14, .36), (28, .42), (56, .52), (90, .64), (180, .86), (300, .97), (365, 1.0)])
    head = curve([(0, 1.42), (28, 1.36), (56, 1.28), (120, 1.17), (240, 1.06), (365, 1.0)])
    muz = curve([(0, .52), (28, .62), (56, .74), (120, .88), (240, .97), (365, 1.0)])
    ear = curve([(0, .42), (14, .5), (56, .78), (180, .95), (365, 1.0)])
    tail = curve([(0, .55), (56, .8), (180, .95), (365, 1.0)])
    leg = curve([(0, .50), (21, .58), (56, .76), (120, .90), (240, .98), (365, 1.0)])
    girth = curve([(0, 1.12), (28, 1.16), (56, 1.12), (120, 1.04), (365, 1.0), (2900, 1.03), (3650, .97), (4745, .93)])
    legw = curve([(0, 1.25), (56, 1.15), (180, 1.03), (365, 1.0)])
    sc = {0: (girth, girth, 1.0), 1: (head, head, head), 2: (head * .96, head * .96, head * muz),
          3: (ear * head, ear * head, ear * head), 4: (tail, tail, tail), 5: (legw, leg, legw)}
    return {"g": g, "scale": sc}


def fk(rot, root_pos=(0, 0, 0), age=None, rest=None):
    """rot: 관절마다 사원수(NJ,4) → 세계 행렬 (NJ, 3x4: R|t), 성견 크기 또는 나이 비율.
    성장: 뼈마다 배율 S(가로·세로·앞뒤)를 쉬는 자세 축으로 곱함 — 자식 관절까지의 거리는 부모 뼈 배율을 따름"""
    R = np.zeros((NJ, 3, 3)); T = np.zeros((NJ, 3)); S = np.ones((NJ, 3))
    gr = growth(age) if age is not None else None
    rs = REST if rest is None else rest
    for i in range(NJ):
        if gr is not None: S[i] = gr["scale"][GROUP[i]]
        p = PARENT[i]
        m = qmat(rot[i])
        if p < 0:
            R[i] = m
            T[i] = rs[i] + np.asarray(root_pos)
            if gr is not None:                      # 뿌리 높이 = 엉덩이 관절까지(몸통 비율) + 다리 길이(다리 비율)
                hip = REST[IDX["HL0"]][1]
                ly = gr["scale"][5][1]
                T[i] = np.array([0, (rs[i][1] - hip) * S[i][1] + hip * ly, rs[i][2]]) + np.asarray(root_pos) * np.array([1, ly, 1])
        else:
            R[i] = R[p] @ m
            T[i] = T[p] + R[p] @ ((rs[i] - rs[p]) * S[p])
    return R, T, S


def skin_mats(R, T, S):
    """꼭짓점 = M·(쉬는 자리) : M = [R·diag(S) | T − R·diag(S)·rest]"""
    A = R * S[:, None, :]
    b = T - np.einsum('nij,nj->ni', A, REST)
    return A, b


# ---------- 다리 풀기 (발 닿는 점 → 관절 돌림) ----------
def _ang(v):
    return np.arctan2(v[2], -v[1])


def rx(a): return qaxis((1, 0, 0), a)
def ry(a): return qaxis((0, 1, 0), a)
def rz(a): return qaxis((0, 0, 1), a)


def leg_ik(leg, Rp, Pp_joint, target, foot_pitch):
    """leg: 'FL' 등. Rp: 부모(가슴·골반) 세계 돌림, Pp_joint: 어깨·엉덩 관절 세계 자리, target: 손목·비절 세계 자리,
    foot_pitch: 발(손목 아래·비절 아래)의 세계 기울기. 반환: 관절 셋의 사원수"""
    i0 = IDX[leg + "0"]
    u = REST[i0 + 1] - REST[i0]; l = REST[i0 + 2] - REST[i0 + 1]
    a = np.linalg.norm(u); b = np.linalg.norm(l)
    t = Rp.T @ (np.asarray(target) - Pp_joint)
    d = float(np.clip(np.linalg.norm(t), abs(a - b) + .004, a + b - .0005))
    t = t / (np.linalg.norm(t) + 1e-9) * d
    phi0 = _ang(l) - _ang(u)
    phi = np.arccos(np.clip((d*d - a*a - b*b) / (2*a*b), -1, 1)) * (1 if phi0 > 0 else -1)
    delta = -(phi - phi0)
    q1 = rx(delta)
    w1 = u + qmat(q1) @ l
    # 0.10.14: 엉덩·어깨 돌림을 '앞뒤 rx · 옆 rz' 로 나눠 풀던 것(sin β = −t.x / w1.y)은 다리를 많이 접어 w1.y 가 0 에 가까워지면
    # 옆으로 벌리는 각이 ±72° 사이를 한 장 만에 뒤집혀, 제자리 돌기·몸 돌리기·뛰기에서 다리가 가운데를 축으로 휙휙 돌았음.
    # → 다리(w1)를 발 닿을 곳(t) 쪽으로 돌리되, 무릎 경첩 축(x)은 t 에 수직이면서 몸의 좌우축에 가장 가깝게 — 다리를 거의
    #   옆으로 뻗지 않는 한 늘 이어지는 하나의 답
    X = np.array([1., 0., 0.])
    a1 = w1 / np.linalg.norm(w1); a3 = np.cross(X, a1)
    tn = t / np.linalg.norm(t)
    h = X - np.dot(X, tn) * tn; h /= np.linalg.norm(h)
    b3 = np.cross(h, tn)
    A_ = np.stack([X, a1, a3], 1); B_ = np.stack([h, tn, b3], 1)
    q0 = mat_q(B_ @ A_.T)
    Rl = Rp @ qmat(q0) @ qmat(q1)
    # 발: 세계 기울기 foot_pitch (개가 보는 쪽 기준) → 아랫다리 기준으로
    want = qmat(rx(foot_pitch))
    m = Rl.T @ want
    q2 = mat_q(m)
    return q0, q1, q2


def mat_q(m):
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = np.sqrt(tr + 1) * 2
        q = np.array([s / 4, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s])
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = np.array([(m[2, 1] - m[1, 2]) / s, s / 4, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s])
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = np.array([(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, s / 4, (m[1, 2] + m[2, 1]) / s])
    else:
        s = np.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = np.array([(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, s / 4])
    return qnorm(q)


STANCE = {"FL": np.array([.040, 0, .078]), "FR": np.array([-.040, 0, .078]), "HL": np.array([.042, 0, -.110]), "HR": np.array([-.042, 0, -.110])}
