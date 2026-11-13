#!/usr/bin/env python3
"""소리 만들기 → ios/AnotherFam/Sounds/*.wav (44.1kHz, 한 채널)
녹음이 아니라 직접 만든 소리: 목소리는 성대 떨림(톱니 파) + 입·코 울림통(포먼트) + 숨소리, 그 밖은 부딪힘·마찰을 흉내.
성견 말티즈 기준 높이로 만들고, 앱이 나이에 맞춰 빠르기(높이)를 바꿈 (강아지는 높고 가늘게, 노견은 낮고 거칠게).
사용: python3 tools/dog_sounds.py"""
import os, wave
import numpy as np
from scipy.signal import lfilter, butter, sosfilt

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'ios', 'AnotherFam', 'Sounds')
rng = np.random.default_rng(11)


def env(n, a, d, hold=0., curve=2.):
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4))
    rel = np.clip((t - a - hold) / max(d, 1e-4), 0, 1)
    return e * (1 - rel) ** curve


def bp(x, f, q):
    w = 2 * np.pi * f / SR; al = np.sin(w) / (2 * q)
    b = [al, 0, -al]; a = [1 + al, -2 * np.cos(w), 1 - al]
    return lfilter(np.array(b) / a[0], np.array(a) / a[0], x)


def filt(x, lo=None, hi=None, order=2):
    if lo: x = sosfilt(butter(order, lo, 'hp', fs=SR, output='sos'), x)
    if hi: x = sosfilt(butter(order, hi, 'lp', fs=SR, output='sos'), x)
    return x


def voice(f0, amp, formants, breath=.15, rough=0., jitter=.01, tilt=1.0):
    """f0·amp: 표본마다. 톱니 성대 파 + 숨소리를 울림통(포먼트)에 통과"""
    n = len(f0)
    f = f0 * (1 + jitter * filt(rng.normal(0, 1, n), None, 60))
    ph = np.cumsum(f) / SR
    src = 2 * (ph % 1) - 1
    src = src - .5 * (2 * ((ph * 2) % 1) - 1) * tilt * .3
    if rough > 0: src *= 1 - rough * (.5 + .5 * np.sign(np.sin(np.pi * ph)))        # 반음 아래 떨림 (거친 짖음)
    src = src * amp + breath * amp * rng.normal(0, 1, n)
    out = np.zeros(n)
    for fr, q, g in formants: out += g * bp(src, fr, q)
    return out


def norm(x, peak=.8):
    x = x - np.mean(x)
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def save(name, x, peak=.8):
    x = norm(np.asarray(x, float), peak)
    f = int(.004 * SR)
    x[:f] *= np.linspace(0, 1, f); x[-f:] *= np.linspace(1, 0, f)
    with wave.open(os.path.join(OUT, name + '.wav'), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((x * 32767).astype('<i2').tobytes())


FM = [(1150, 5, 1.0), (2500, 7, .7), (3900, 8, .35), (5600, 8, .12)]            # 작은 개 입 울림 (성도 약 8cm)


def bark(dur=.13, f_hi=820, f_lo=560, rough=.5, gain=1.0):
    n = int(dur * SR); t = np.linspace(0, 1, n)
    f0 = f_lo + (f_hi - f_lo) * np.exp(-((t - .18) / .32) ** 2)
    a = env(n, .012, dur * .75, dur * .12, 1.6)
    v = voice(f0, a, FM, breath=.35, rough=rough, jitter=.03)
    burst = filt(rng.normal(0, 1, n), 900, 6000) * env(n, .003, .03) * .5       # 터지는 숨
    return (v + burst) * gain


def whine(dur=.7, f1=950, f2=1350, f3=1000, vib=.02):
    n = int(dur * SR); t = np.linspace(0, 1, n)
    f0 = np.interp(t, [0, .35, 1], [f1, f2, f3]) * (1 + vib * np.sin(2 * np.pi * 7 * t * dur))
    a = env(n, .06, dur * .5, dur * .3, 1.5)
    return voice(f0, a, [(1300, 9, 1.0), (2700, 10, .5), (4100, 9, .2)], breath=.08, jitter=.006, tilt=.3)


def growl(dur=1.1, f=115):
    n = int(dur * SR); t = np.arange(n) / SR
    f0 = f * (1 + .08 * np.sin(2 * np.pi * 2.3 * t)) * (1 + .05 * filt(rng.normal(0, 1, n), None, 20) * 6)
    a = env(n, .12, dur * .4, dur * .4) * (.75 + .25 * np.sin(2 * np.pi * 23 * t))
    return voice(f0, a, [(520, 3, 1.0), (1300, 4, .6), (2400, 5, .25)], breath=.25, rough=.6, jitter=.05)


def noise_burst(dur, lo, hi, a=.01, curve=2.):
    n = int(dur * SR)
    return filt(rng.normal(0, 1, n), lo, hi) * env(n, a, dur - a, 0, curve)


def pad(*parts):
    return np.concatenate(parts)


def sil(d):
    return np.zeros(int(d * SR))


def pant():
    out = []
    for i in range(4):
        ex = noise_burst(.085, 500, 3200, .02, 1.3) * 1.0          # 내쉼
        inn = noise_burst(.075, 900, 5000, .02, 1.3) * .5         # 들이쉼
        out += [ex, sil(.012), inn, sil(.02)]
    x = pad(*out)
    return bp(x, 1400, 1.2) + .4 * x


def sniff(k=2):
    out = []
    for i in range(k):
        out += [noise_burst(.07 + .02 * rng.random(), 1800, 7500, .012, 1.2), sil(.05 + .03 * rng.random())]
    return pad(*out)


def click(f, dur=.02, q=12, g=1.):
    n = int(dur * SR)
    x = np.zeros(n); x[0] = 1
    return bp(x, f, q)[:n] * g * 30 * env(n, .0005, dur, 0, 2)


def lap():
    n = int(.11 * SR); t = np.arange(n) / SR
    drop = np.sin(2 * np.pi * (420 + 900 * t / .11) * t) * env(n, .004, .07)             # 물방울 '뽈'
    return drop * .8 + np.concatenate([noise_burst(.05, 1500, 6000, .004), np.zeros(n - int(.05 * SR))]) * .5


def crunch(k=5):
    n = int(.16 * SR); x = np.zeros(n)
    for _ in range(k + rng.integers(0, 4)):
        i = rng.integers(0, n - 600)
        c = click(rng.uniform(1800, 5200), .012, rng.uniform(3, 8), rng.uniform(.4, 1))
        x[i:i + len(c)] += c
    return x + noise_burst(.16, 800, 4000, .01) * .25


def step(hard=True):
    x = click(rng.uniform(3200, 4600), .012, 9, .6 if hard else .15)                      # 발톱
    th = noise_burst(.03, 60, 380, .002) * 1.2                                           # 발바닥
    n = max(len(x), len(th)); o = np.zeros(n); o[:len(x)] += x; o[:len(th)] += th
    return o


def thump():
    n = int(.14 * SR); t = np.arange(n) / SR
    return np.sin(2 * np.pi * (95 - 30 * t / .14) * t) * env(n, .003, .12) + noise_burst(.14, 80, 700, .003) * .5


def shake():
    n = int(1.1 * SR); t = np.arange(n) / SR
    k = np.sin(np.pi * t / 1.1) ** .7
    flap = (np.maximum(0, np.sin(2 * np.pi * 15 * t)) ** 6) * filt(rng.normal(0, 1, n), 300, 4500)
    return flap * k + filt(rng.normal(0, 1, n), 1500, 6000) * k * .12


def scratch():
    return noise_burst(.07, 900, 3800, .008, 1.3)


def squeak(f=2100):
    n = int(.16 * SR); t = np.linspace(0, 1, n)
    f0 = f * (1 + .22 * np.sin(np.pi * t) - .1 * t)
    x = np.sin(2 * np.pi * np.cumsum(f0) / SR) + .4 * np.sin(4 * np.pi * np.cumsum(f0) / SR) + .2 * np.sin(6 * np.pi * np.cumsum(f0) / SR)
    return x * env(n, .012, .12, .03, 1.2) + noise_burst(.16, 2500, 8000, .01) * .12


def bounce():
    n = int(.09 * SR); t = np.arange(n) / SR
    return np.sin(2 * np.pi * (240 - 900 * t) * t) * env(n, .001, .08, 0, 2.5) + noise_burst(.03, 300, 2500, .001)[:n].sum() * 0 + np.pad(noise_burst(.03, 300, 2500, .001), (0, n - int(.03 * SR))) * .5


def clink():
    n = int(.5 * SR); t = np.arange(n) / SR
    x = sum(g * np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, g, d in ((2350, 1, 9), (3720, .6, 12), (5410, .4, 16), (7150, .25, 22)))
    return x * env(n, .0005, .5, 0, 1)


def pour_kibble():
    n = int(1.2 * SR); x = np.zeros(n)
    for _ in range(140):
        i = int(rng.beta(1.6, 2.2) * (n - 800))
        c = click(rng.uniform(1500, 6000), .015, rng.uniform(3, 9), rng.uniform(.2, 1))
        x[i:i + len(c)] += c
    return x


def pour_water():
    n = int(1.6 * SR); t = np.arange(n) / SR
    x = filt(rng.normal(0, 1, n), 500, 6000) * (.5 + .5 * filt(rng.normal(0, 1, n), None, 25) * 4) * env(n, .1, .5, 1.0, 1.2) * .35
    for _ in range(60):
        i = rng.integers(0, n - 3000); m = int(.03 * SR); tt = np.arange(m) / SR
        f = rng.uniform(500, 1600)
        x[i:i + m] += np.sin(2 * np.pi * (f + f * 14 * tt) * tt) * env(m, .002, .028) * rng.uniform(.2, .6) * (1 - i / n * .6)
    return x


def chime():
    n = int(.7 * SR); t = np.arange(n) / SR
    return (np.sin(2 * np.pi * 1318 * t) + .6 * np.sin(2 * np.pi * 1976 * t) * (t > .09)) * np.exp(-t * 6)


def main():
    os.makedirs(OUT, exist_ok=True)
    S = {}
    for i, (d, hi, lo, r) in enumerate([(.13, 820, 560, .5), (.11, 900, 600, .4), (.15, 760, 520, .6), (.12, 860, 640, .3)], 1):
        S[f'bark{i}'] = bark(d, hi, lo, r)
    S['bark_double'] = pad(bark(.11, 860, 580, .5), sil(.07), bark(.14, 800, 540, .5))
    S['yip1'] = bark(.08, 1250, 900, .15); S['yip2'] = bark(.07, 1400, 1000, .1)
    S['woof'] = bark(.16, 520, 380, .7) * .7                                         # 낮게 '웁' (경계)
    for i, a in enumerate([(.7, 950, 1350, 1000), (.9, 1100, 1500, 900), (.5, 1250, 1050, 1150)], 1): S[f'whine{i}'] = whine(*a)
    S['whimper'] = pad(whine(.18, 1300, 1500, 1200) * .6, sil(.12), whine(.22, 1250, 1450, 1100) * .7, sil(.1), whine(.15, 1350, 1500, 1300) * .5)
    S['howl'] = whine(1.9, 520, 720, 600, .012)
    S['growl'] = growl(); S['growl_play'] = growl(.7, 150) * .8
    S['pant'] = pant()
    S['sniff1'] = sniff(2); S['sniff2'] = sniff(3)
    y = int(.9 * SR); t = np.linspace(0, 1, y)
    S['yawn'] = voice(np.interp(t, [0, .25, 1], [700, 1500, 620]), env(y, .2, .5, .1, 1.5) * .6, [(1200, 6, 1), (2600, 8, .5)], breath=.6, jitter=.01, tilt=.3) + noise_burst(.9, 600, 3500, .25, 1.) * .5
    S['sneeze'] = pad(noise_burst(.05, 1500, 7000, .03, 1.) * .3, noise_burst(.12, 700, 6500, .004, 2.2))
    S['sigh'] = noise_burst(.7, 300, 2200, .12, 1.4)
    for i in range(1, 4): S[f'lap{i}'] = lap()
    for i in range(1, 5): S[f'chomp{i}'] = crunch()
    S['chew1'] = crunch(3) * .7; S['chew2'] = crunch(2) * .7
    S['lick1'] = noise_burst(.09, 1200, 5000, .02, 1.3) * .5 + np.pad(lap()[:int(.05 * SR)], (0, int(.09 * SR) - int(.05 * SR))) * .3
    S['lick2'] = noise_burst(.08, 1400, 5500, .02, 1.3) * .5
    S['suck1'] = np.pad(lap()[:int(.06 * SR)], (0, 200)) * .6; S['suck2'] = np.pad(lap()[:int(.05 * SR)], (0, 200)) * .5
    for i in range(1, 5): S[f'step{i}'] = step(True)
    for i in range(1, 3): S[f'stepsoft{i}'] = step(False)
    S['thump'] = thump(); S['shake'] = shake(); S['flap'] = shake()[:int(.55 * SR)]
    S['scratch1'] = scratch(); S['scratch2'] = scratch()
    S['pat'] = noise_burst(.05, 150, 1800, .002, 2.)
    S['squeak1'] = squeak(2100); S['squeak2'] = squeak(2450)
    S['bounce'] = bounce(); S['clink'] = clink(); S['kibble'] = pour_kibble(); S['water'] = pour_water(); S['chime'] = chime()
    S['pee'] = pour_water()[:int(1.2 * SR)] * .5
    # 갓난 강아지: 가늘고 높은 낑낑
    S['mewl1'] = whine(.28, 1700, 2200, 1800, .0) * .7; S['mewl2'] = pad(whine(.2, 1900, 2300, 2000, 0), sil(.08), whine(.24, 1800, 2250, 1700, 0)) * .7
    S['mewl3'] = whine(.4, 1600, 2100, 1500, .03) * .7
    S['brush'] = noise_burst(.35, 1500, 7000, .08, 1.2) * .5
    S['rustle'] = noise_burst(.25, 800, 5000, .05, 1.3) * .5
    pk = {'step': .25, 'stepsoft': .12, 'pant': .35, 'sniff': .3, 'lick': .3, 'suck': .3, 'sigh': .3, 'chew': .4, 'chomp': .5, 'lap': .45, 'scratch': .35, 'pat': .3,
          'brush': .3, 'rustle': .3, 'growl': .5, 'whimper': .4, 'mewl': .5, 'yawn': .5, 'chime': .4, 'pee': .25, 'thump': .5, 'flap': .5, 'shake': .6}
    for k, x in S.items():
        base = k.rstrip('0123456789').split('_')[0]
        save(k, x, pk.get(base, .8))
    print(len(S), '개 소리', sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT)) // 1024, 'KB')


if __name__ == '__main__':
    main()
