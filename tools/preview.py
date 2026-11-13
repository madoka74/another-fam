"""자세를 그려 보기 (도구 전용): 뼈 돌림 → 껍데기 겹 → three.js(헤드리스 크롬)로 그림. 앱 DogSkin 과 같은 식"""
import os, sys, json, numpy as np, subprocess, time, http.server, threading, functools
from dogrig import *
C = np.load(os.path.join(os.path.dirname(__file__), '_dog_cache.npz'))
PV = '/home/claude/prev'
NSH = 18

def coat(age):
    b = float(np.interp(age, [0, 14, 28, 56, 180, 365, 3650, 4745], [.10, .16, .27, .46, .80, 1.0, 1.0, .92]))
    l = float(np.interp(age, [0, 28, 56, 180, 365, 540], [.07, .14, .26, .60, .88, 1.0]))
    return b, l

def shells(rot, root_pos=(0, 0, 0), age=None, grav=(0, -1, 0), floor=None, nsh=NSH):
    R, T, S = fk(rot, root_pos, age)
    A, b = skin_mats(R, T, S)
    V, N, CB, BI, BW = C['V'], C['N'], C['CB'], C['BI'], C['BW']
    p = np.zeros_like(V); n = np.zeros_like(V); cb = np.zeros_like(V)
    for k in range(4):
        i = BI[:, k]; w = BW[:, k:k+1]
        p += w * (np.einsum('nij,nj->ni', A[i], V) + b[i])
        n += w * np.einsum('nij,nj->ni', R[i], N)
        cb += w * np.einsum('nij,nj->ni', R[i], CB)
    n /= np.linalg.norm(n, axis=1, keepdims=True)
    d = n + cb; d /= np.linalg.norm(d, axis=1, keepdims=True)
    g = growth(age)['g'] if age is not None else 1.0
    cbd, cl = coat(age if age is not None else 1000)
    L = C['FL'] * (cbd + (cl - cbd) * C['LG']) / g
    droop = (.20 + .12 * C['LG'])[:, None] * np.asarray(grav)
    out = []
    for k in range(nsh):
        t = k / (nsh - 1)
        q = p + L[:, None] * (d * t + droop * t * t)
        if floor is not None: q[:, 1] = np.maximum(q[:, 1], floor + .0015 * t)
        out.append(q)
    return np.array(out), n, (R, T, S), g

def export(name, rot, root_pos=(0, 0, 0), age=None, extra=None):
    sh, n, (R, T, S), g = shells(rot, root_pos, age, floor=0.0)
    hd = IDX['head']
    sc = S[hd]
    def hp(q): return (T[hd] + R[hd] @ ((np.array(q) - REST[hd]) * sc)).tolist()
    d = {"nsh": len(sh), "nv": sh.shape[1], "g": g, "eyeR": EYE_R * sc[0],
         "eyes": [hp(EYE), hp((-EYE[0], EYE[1], EYE[2]))], "nose": hp(NOSE), "noseS": float(sc[0]), "joints": T.tolist()}
    if extra: d.update(extra)
    os.makedirs(PV + '/data', exist_ok=True)
    sh.astype('<f4').tofile(f'{PV}/data/{name}.pos'); n.astype('<f4').tofile(f'{PV}/data/{name}.nrm')
    C['UV'].astype('<f4').tofile(f'{PV}/data/uv.bin'); C['T'].astype('<u4').tofile(f'{PV}/data/tri.bin')
    json.dump(d, open(f'{PV}/data/{name}.json', 'w'))

HTML = r'''<!doctype html><html><body style="margin:0;background:#777"><script type="importmap">{"imports":{"three":"./node_modules/three/build/three.module.js"}}</script>
<script type="module">
import * as THREE from 'three';
const q=new URLSearchParams(location.search); const names=q.get('n').split(','); const az=parseFloat(q.get('az')||'35'), el=parseFloat(q.get('el')||'12'), dist=parseFloat(q.get('d')||'0.75');
const cols=parseInt(q.get('cols')||names.length); const W=innerWidth,H=innerHeight;
const r=new THREE.WebGLRenderer({antialias:true}); r.setSize(W,H); document.body.appendChild(r.domElement); r.setScissorTest(true);
const fur=await new THREE.TextureLoader().loadAsync('fur.png'); fur.wrapS=fur.wrapT=THREE.RepeatWrapping; fur.colorSpace=THREE.SRGBColorSpace;
const ab=async u=>await (await fetch(u)).arrayBuffer();
const uv=new Float32Array(await ab('data/uv.bin')), tri=new Uint32Array(await ab('data/tri.bin'));
const scenes=[];
for(const nm of names){ const [name,azo]=nm.split('@'); const s=new THREE.Scene(); s.background=new THREE.Color(0x8a8f96);
 s.add(new THREE.HemisphereLight(0xffffff,0x555a60,1.6)); const dl=new THREE.DirectionalLight(0xfff4e0,1.6); dl.position.set(1,2,1.5); s.add(dl);
 const J=await (await fetch('data/'+name+'.json')).json(); const pos=new Float32Array(await ab('data/'+name+'.pos')), nrm=new Float32Array(await ab('data/'+name+'.nrm'));
 const grp=new THREE.Group(); grp.scale.setScalar(J.g); s.add(grp);
 for(let k=0;k<J.nsh;k++){ const g=new THREE.BufferGeometry(); g.setAttribute('position',new THREE.BufferAttribute(pos.subarray(k*J.nv*3,(k+1)*J.nv*3),3));
  g.setAttribute('normal',new THREE.BufferAttribute(nrm,3)); g.setAttribute('uv',new THREE.BufferAttribute(uv,2)); g.setIndex(new THREE.BufferAttribute(tri,1));
  const t=k/(J.nsh-1); const c=new THREE.Color().setRGB(0.80+0.20*t,0.75+0.24*t,0.70+0.27*t);
  const m=new THREE.MeshStandardMaterial({map:fur,color:c,roughness:0.9,alphaTest:k==0?0:Math.min(0.97,0.14+0.84*t),side:THREE.FrontSide});
  grp.add(new THREE.Mesh(g,m)); }
 const em=new THREE.MeshStandardMaterial({color:0x0b0705,roughness:0.08}); for(const e of J.eyes){const m=new THREE.Mesh(new THREE.SphereGeometry(J.eyeR,24,16),em); m.position.fromArray(e); m.scale.setScalar(J.open===undefined?1:J.open); grp.add(m);}
 const nm2=new THREE.Mesh(new THREE.SphereGeometry(1,24,16),new THREE.MeshStandardMaterial({color:0x080808,roughness:0.25})); nm2.position.fromArray(J.nose); nm2.scale.set(.0125*J.noseS,.0095*J.noseS,.0085*J.noseS); grp.add(nm2);
 const fl=new THREE.Mesh(new THREE.PlaneGeometry(3,3),new THREE.MeshStandardMaterial({color:0x9a8f80,roughness:1})); fl.rotation.x=-Math.PI/2; s.add(fl);
 if(q.get('sk')){ for(const p of J.joints){const m=new THREE.Mesh(new THREE.SphereGeometry(.004),new THREE.MeshBasicMaterial({color:0xff0000,depthTest:false})); m.position.fromArray(p); m.renderOrder=9; grp.add(m);} }
 const cam=new THREE.PerspectiveCamera(30,1,0.01,10); const a=(az+parseFloat(azo||0))*Math.PI/180,e=el*Math.PI/180; const cy=parseFloat(q.get('cy')||'0.15')*J.g, dd=dist*(q.get('fit')?J.g:1);
 cam.position.set(Math.sin(a)*Math.cos(e)*dd,cy+Math.sin(e)*dd,Math.cos(a)*Math.cos(e)*dd); cam.lookAt(0,cy,0); scenes.push([s,cam]); }
const rows=Math.ceil(names.length/cols), cw=W/cols, ch=H/rows;
scenes.forEach(([s,c],i)=>{const x=(i%cols)*cw,y=H-ch*(Math.floor(i/cols)+1); c.aspect=cw/ch; c.updateProjectionMatrix(); r.setViewport(x,y,cw,ch); r.setScissor(x,y,cw,ch); r.render(s,c);});
document.title='done';
</script></body></html>'''

_srv = None
def shot(names, out, az=35, el=12, d=0.75, cols=None, w=1400, h=700, cy=0.15, fit=False, sk=False):
    global _srv
    open(PV + '/view.html', 'w').write(HTML)
    if not os.path.exists(PV + '/fur.png'):
        os.symlink(os.path.join(os.path.dirname(__file__), '..', 'ios', 'AnotherFam', 'Model', 'fur.png'), PV + '/fur.png')
    if _srv is None:
        h_ = functools.partial(http.server.SimpleHTTPRequestHandler, directory=PV)
        class Q(http.server.ThreadingHTTPServer):
            pass
        _srv = Q(('127.0.0.1', 8765), h_); _srv.RequestHandlerClass.log_message = lambda *a: None
        threading.Thread(target=_srv.serve_forever, daemon=True).start()
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch(args=['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'])
        pg = b.new_page(viewport={'width': w, 'height': h})
        url = f"http://127.0.0.1:8765/view.html?n={','.join(names)}&az={az}&el={el}&d={d}&cols={cols or len(names)}&cy={cy}" + ('&fit=1' if fit else '') + ('&sk=1' if sk else '')
        pg.on('console', lambda m: print('JS:', m.text) if m.type == 'error' else None)
        pg.goto(url); pg.wait_for_function("document.title=='done'", timeout=120000); pg.wait_for_timeout(300)
        pg.screenshot(path=out); b.close()

if __name__ == '__main__':
    rot = np.tile(QI, (NJ, 1))
    export('rest', rot)
    shot(['rest@0', 'rest@40', 'rest@90', 'rest@200'], '/home/claude/prev/rest.png', az=0, cols=4, w=1600, h=520, d=0.95)
    shot(['rest@0', 'rest@35'], '/home/claude/prev/face.png', az=0, el=5, cols=2, w=1200, h=600, d=0.36, cy=0.225)
    ages = [0, 10, 21, 56, 120, 365]
    for a in ages: export(f'age{a}', rot, age=a, extra={"open": 0.01 if a < 12 else 1})
    shot([f'age{a}@40' for a in ages], '/home/claude/prev/ages.png', az=0, cols=6, w=1800, h=420, d=0.95)
    shot([f'age{a}@30' for a in ages[:4]], '/home/claude/prev/ages_fit.png', az=0, cols=4, w=1600, h=500, d=0.95, fit=True)
