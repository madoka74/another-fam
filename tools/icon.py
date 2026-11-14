"""어나더 팸 아이콘 — 블랭키씨 웍스 b 마크(기둥 + 원) 안에서 표현.
b 의 둥근 몸통이 말티즈 얼굴(흰 털 뭉치 + 까만 눈 둘·코 = '세 점')이 되고, 기둥 옆으로 귀가 늘어짐.
비전프로 겹 아이콘: 뒤(바탕) / 가운데(b 마크: 기둥 + 털 얼굴) / 앞(눈·코)
사용: python3 tools/icon.py → ios/AnotherFam/Assets.xcassets/AppIcon.solidimagestack (+ tools/icon_preview.png)"""
import os, math, json, random
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'ios', 'AnotherFam', 'Assets.xcassets', 'AppIcon.solidimagestack')
S = 1024; K = 2; W = S * K
BG = (30, 31, 33); MK = (242, 242, 242)


def bez(p0, p1, p2, p3, n=60):
    out = []
    for i in range(n + 1):
        t = i / n; u = 1 - t
        out.append((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0], u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]))
    return out


def geom():
    sc = .27
    w, h = 1600 * sc, 2000 * sc
    tx = (S - w) / 2 + 6; ty = (S - h) / 2 + 8
    P = lambda x, y: ((tx + x * sc) * K, (ty + y * sc) * K)
    stem = bez(P(0, 0), P(300, 0), P(533, 250), P(533, 530)) + [P(533, 2000)] + bez(P(533, 2000), P(220, 2000), P(0, 1780), P(0, 1480))
    cx, cy, r = (tx + 888 * sc) * K, (ty + 1290 * sc) * K, 712 * sc * K
    return stem, cx, cy, r


def layer():
    return Image.new('RGBA', (W, W), (0, 0, 0, 0))


def save(img, name):
    d = os.path.join(OUT, name.capitalize() + '.solidimagestacklayer', 'Content.imageset')
    os.makedirs(d, exist_ok=True)
    img.resize((S, S), Image.LANCZOS).save(os.path.join(d, name + '.png'))
    json.dump({"images": [{"filename": name + ".png", "idiom": "vision", "scale": "2x"}], "info": {"author": "xcode", "version": 1}}, open(os.path.join(d, 'Contents.json'), 'w'), indent=2)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(os.path.dirname(d), 'Contents.json'), 'w'), indent=2)


def main():
    random.seed(4)
    stem, cx, cy, r = geom()
    back = Image.new('RGBA', (W, W), BG + (255,))
    mid = layer(); md = ImageDraw.Draw(mid)
    md.polygon(stem, fill=MK + (255,))
    # 털 얼굴: 원 둘레에 털 뭉치를 돌려 복슬복슬하게
    for i in range(46):
        a = i / 46 * 2 * math.pi + random.uniform(-.04, .04)
        rr = r * random.uniform(.17, .23); d = r * random.uniform(.84, .9)
        x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
        md.ellipse([x - rr, y - rr, x + rr, y + rr], fill=MK + (255,))
    md.ellipse([cx - r * .9, cy - r * .9, cx + r * .9, cy + r * .9], fill=MK + (255,))
    # 늘어진 귀 (오른쪽) — 살짝 어두운 흰색
    ear = layer(); ed = ImageDraw.Draw(ear)
    ex, ey = cx + r * .78, cy - r * .1
    for i in range(18):
        t = i / 17
        rr = r * (.2 + .1 * math.sin(math.pi * t))
        ed.ellipse([ex + r * .1 * t - rr, ey + r * .75 * t - rr, ex + r * .1 * t + rr, ey + r * .75 * t + rr], fill=(226, 226, 224, 255))
    mid.alpha_composite(ear)
    md = ImageDraw.Draw(mid)
    # 얼굴 안쪽 그늘 (입체감)
    sh = layer(); sd = ImageDraw.Draw(sh)
    sd.ellipse([cx - r * .62, cy - r * .2, cx + r * .62, cy + r * .82], fill=(255, 255, 255, 255))
    front = layer(); fd = ImageDraw.Draw(front)
    er = r * .135
    for sx in (-1, 1):
        x, y = cx + sx * r * .36, cy - r * .08
        fd.ellipse([x - er, y - er, x + er, y + er], fill=(18, 16, 15, 255))
        fd.ellipse([x - er * .45, y - er * .55, x - er * .05, y - er * .15], fill=(255, 255, 255, 230))
    nx, ny = cx, cy + r * .3
    fd.ellipse([nx - r * .17, ny - r * .125, nx + r * .17, ny + r * .125], fill=(18, 16, 15, 255))
    fd.ellipse([nx - r * .09, ny - r * .09, nx + r * .0, ny - r * .04], fill=(255, 255, 255, 120))
    fd.line([(nx, ny + r * .12), (nx, ny + r * .26)], fill=(60, 56, 54, 255), width=int(5 * K))
    fd.arc([nx - r * .2, ny + r * .1, nx, ny + r * .34], 20, 160, fill=(60, 56, 54, 255), width=int(5 * K))
    fd.arc([nx, ny + r * .1, nx + r * .2, ny + r * .34], 20, 160, fill=(60, 56, 54, 255), width=int(5 * K))
    save(back, 'back'); save(mid, 'middle'); save(front, 'front')
    json.dump({"info": {"author": "xcode", "version": 1}, "layers": [{"filename": "Front.solidimagestacklayer"}, {"filename": "Middle.solidimagestacklayer"}, {"filename": "Back.solidimagestacklayer"}]}, open(os.path.join(OUT, 'Contents.json'), 'w'), indent=2)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(os.path.dirname(OUT), 'Contents.json'), 'w'), indent=2)
    prev = back.copy(); prev.alpha_composite(mid); prev.alpha_composite(front)
    m = Image.new('L', (W, W), 0); ImageDraw.Draw(m).ellipse([0, 0, W, W], fill=255)
    out = Image.new('RGBA', (W, W), (255, 255, 255, 0)); out.paste(prev, (0, 0), m)
    out.resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, 'tools', 'icon_preview.png'))
    # 아이폰 짝 앱 아이콘: 같은 강아지 얼굴(패밀리룩) + 오른쪽 위 작은 금빛 종 (알림 앱). 네모 그대로·투명 없음
    ph = prev.copy()
    bd = ImageDraw.Draw(ph)
    bx, by, br = W * .80, W * .20, W * .085
    gold, dark = (240, 196, 92, 255), (176, 128, 44, 255)
    bd.ellipse([bx - br * .22, by - br * 1.08, bx + br * .22, by - br * .64], fill=gold)
    bd.pieslice([bx - br * .82, by - br * .9, bx + br * .82, by + br * .9], 180, 360, fill=gold)
    bd.rectangle([bx - br * .82, by - br * .02, bx + br * .82, by + br * .62], fill=gold)
    bd.polygon([(bx - br * .82, by + br * .5), (bx - br * 1.08, by + br * .82), (bx + br * 1.08, by + br * .82), (bx + br * .82, by + br * .5)], fill=gold)
    bd.ellipse([bx - br * .26, by + br * .78, bx + br * .26, by + br * 1.18], fill=dark)
    pd = os.path.join(ROOT, 'ios', 'FamPhone', 'Assets.xcassets', 'AppIcon.appiconset')
    os.makedirs(pd, exist_ok=True)
    ph.convert('RGB').resize((S, S), Image.LANCZOS).save(os.path.join(pd, 'icon.png'))
    json.dump({"images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, open(os.path.join(pd, 'Contents.json'), 'w'), indent=2)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(os.path.dirname(pd), 'Contents.json'), 'w'), indent=2)
    ph.convert('RGB').resize((512, 512), Image.LANCZOS).save(os.path.join(ROOT, 'tools', 'icon_phone_preview.png'))


main()
