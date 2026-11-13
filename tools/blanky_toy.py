#!/usr/bin/env python3
"""블랭키씨 인형(장난감) 그물 만들기 → ios/AnotherFam/Model/blanky_toy.bin
어나더 스페이스에서 만든 블랭키씨 모델(blanky.glb, 키 1.6m — 비전 드럼 저장소에 있는 것과 같은 파일)을 키 1 로 맞추고 점을 줄여 담음.
모델이 바뀌면: python3 tools/blanky_toy.py <blanky.glb 경로>"""
import sys, os, json, struct
import numpy as np
import fast_simplification

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'ios', 'AnotherFam', 'Model', 'blanky_toy.bin')


def main(src):
    d = open(src, 'rb').read()
    n = struct.unpack('<I', d[12:16])[0]; j = json.loads(d[20:20 + n]); bin_ = d[20 + n + 8:]
    def acc(i):
        a = j['accessors'][i]; bv = j['bufferViews'][a['bufferView']]
        dt = {5126: '<f4', 5125: '<u4', 5123: '<u2'}[a['componentType']]; k = {'SCALAR': 1, 'VEC3': 3}[a['type']]
        o = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
        return np.frombuffer(bin_, dt, a['count'] * k, o).reshape(-1, k) if k > 1 else np.frombuffer(bin_, dt, a['count'], o)
    M = {m['name']: m['primitives'][0] for m in j['meshes']}
    v = acc(M['body']['attributes']['POSITION']).astype(np.float64); t = acc(M['body']['indices']).reshape(-1, 3)
    H = v[:, 1].max()
    v2, t2 = fast_simplification.simplify(v.astype(np.float32), t.astype(np.int32), target_count=7000, agg=3)
    v2 = v2.astype(np.float64) / H
    fn = np.cross(v2[t2[:, 1]] - v2[t2[:, 0]], v2[t2[:, 2]] - v2[t2[:, 0]])
    nr = np.zeros_like(v2)
    for k in range(3): np.add.at(nr, t2[:, k], fn)
    nr /= np.linalg.norm(nr, axis=1, keepdims=True) + 1e-12
    def box(name):
        p = acc(M[name]['attributes']['POSITION']) / H
        return ((p.min(0) + p.max(0)) / 2).tolist() + ((p.max(0) - p.min(0)) / 2).tolist()
    parts = box('eye_L') + box('eye_R') + box('face_line') + box('orb')
    with open(OUT, 'wb') as f:
        f.write(b'AFB1' + struct.pack('<II', len(v2), len(t2)))
        f.write(np.concatenate([v2, nr], 1).astype('<f4').tobytes()); f.write(t2.astype('<u4').tobytes())
        f.write(np.array(parts, '<f4').tobytes())
    print('blanky_toy.bin', len(v2), '점', len(t2), '삼각형', os.path.getsize(OUT) // 1024, 'KB', '눈·입·구슬', np.round(parts, 4).tolist())


main(sys.argv[1] if len(sys.argv) > 1 else '/home/claude/ref/vision-drum/ios/VisionDrum/Model/blanky.glb')
