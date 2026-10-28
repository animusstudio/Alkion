#!/usr/bin/env python3
"""Reproducible local conversion of pinned CC0 MakeHuman data. No network."""
import hashlib
import json
import math
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets'
REGIONS = ['unmapped', 'chest', 'back', 'shoulders', 'quads', 'hamstrings', 'calves', 'biceps', 'triceps', 'trunks']
MORPHS = [('african-male-young.target',1/3),('asian-male-young.target',1/3),('caucasian-male-young.target',1/3),
          ('universal-male-young-maxmuscle-averageweight.target',.30),
          ('universal-male-young-maxmuscle-maxweight.target',.70)]
SCULPT_VERSION = 'classical-athlete-1'

def sub(a, b): return [a[i] - b[i] for i in range(3)]
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def unit(a):
    n = math.sqrt(sum(x*x for x in a)) or 1
    return [x/n for x in a]
def smooth(a, b, t):
    t = min(1, max(0, (t-a)/(b-a)))
    return t*t*(3-2*t)

def bell(value, center, radius):
    """Compact C1 sculpt falloff; exactly zero beyond the named radius."""
    return (max(0., 1.-((value-center)/radius)**2))**2

def athletic_surface(point):
    """Authored sculpt on the existing surface, in upstream model units.

    These fields move shared vertices, never add independent muscle shells.
    Use bilateral source coordinates so front/profile/back share one form.
    Anatomy masks continue to use the unsculpted source surface.
    """
    sign = 1 if point[0] >= 0 else -1
    x, y, z = abs(point[0]), point[1], point[2]
    dx, dz = 0., 0.
    torso = 1-smooth(1.75,2.3,x)
    # Wider clavicular girdle, narrow waist; shoulders/arms follow the same
    # smooth horizontal frame change rather than being detached or pasted on.
    frame = .14*bell(y,5.25,1.55)-.075*bell(y,2.6,1.6)-.035*bell(y,.55,1.35)
    dx += x*frame
    # Rounded deltoid cap, including its anterior and posterior surfaces.
    cap = bell(x,2.10,.95)*bell(y,5.45,1.05)
    dx += (x-1.65)*.28*cap
    dz += (z-.05)*.22*cap
    front, rear = smooth(.15,.85,z), 1-smooth(-.55,.15,z)
    # Broad upper pectoral fullness leaves the sternum legible. Compress the
    # existing most anterior lower pole rather than amplifying a nipple cone.
    dz += .18*bell(x,1.05,1.20)*bell(y,5.15,1.30)*front*torso
    dz -= .12*smooth(1.25,1.75,z)*bell(y,4.55,.90)*torso
    # Broad upper back and tapered lats, without inflating the lower waist.
    dx += .22*bell(x,1.45,.85)*bell(y,4.15,1.35)*torso
    dz -= .20*bell(x,1.0,1.15)*bell(y,4.85,1.25)*rear*torso
    # Keep the abdominal profile composed below the deeper thorax.
    dz -= (z-.20)*.065*bell(y,2.8,1.3)*torso
    # Upper arm cross section around the existing oblique humerus. The
    # multiplier vanishes at shoulder/elbow so joints retain their structure.
    t = ((x-2.02)*1.64+(y-5.45)*-1.80)/(1.64**2+1.80**2)
    if 0 < t < 1:
        axis_x, axis_y = 2.02+1.64*t, 5.45-1.80*t
        arm = math.sin(math.pi*t)**2*smooth(1.8,2.4,x)
        dx += (x-axis_x)*.32*arm
        dy = (y-axis_y)*.32*arm
        dz += (z-.10)*.30*arm
    else: dy = 0.
    # Balanced upper legs: enlarge existing bellies, keep knees and groin.
    thigh = bell(y,-1.65,2.0)*smooth(.05,.45,x)*smooth(-3.45,-2.65,y)*(1-smooth(-.90,.30,y))
    center_x = 1.10-.10*y
    dx += (x-center_x)*.17*thigh
    dz += (z-.30)*.22*thigh
    # Ease the outer upper thigh into the pelvis; bulk is carried farther
    # down the femur instead of immediately below the trunks hem.
    dx -= x*.065*bell(y,-.45,1.25)*smooth(.90,1.60,x)
    # Calf fullness is posterior and lateral; ankle/shin remain slender.
    calf = bell(y,-4.55,1.85)*smooth(.65,1.1,x)
    dx += (x-1.64)*.12*calf-.08*calf*smooth(1.6,2.1,x)
    dz += (z-.10)*.18*calf-.06*calf*(1-smooth(-.10,.25,z))
    # A quieter stance and slightly shorter lower-body proportion counter the
    # elongated incumbent. Feet/toes translate together, keeping their shape.
    stance = 1-smooth(-6.7,-.2,y)
    dx -= .28*stance
    lower = 1-smooth(-.15,.65,y)
    return [(x+dx)*sign, y+dy-y*.055*lower, z+dz]

def rotate_between(point, pivot, source, target, weight):
    a, b = unit(source), unit(target)
    axis = unit(cross(a, b))
    angle = math.acos(min(1, max(-1, sum(a[i]*b[i] for i in range(3))))) * weight
    q = sub(point, pivot)
    c, s = math.cos(angle), math.sin(angle)
    cp = cross(axis, q)
    dot = sum(axis[i]*q[i] for i in range(3))
    return [pivot[i]+q[i]*c+cp[i]*s+axis[i]*dot*(1-c) for i in range(3)]

def region(c, n):
    # Original morph-space surface partitions; no shape or screen-space masks.
    x, y, z = abs(c[0]), c[1], c[2]
    if -0.45 < y < 1.40 and x < 2.1: return 9
    if y < -6.9: return 0 # feet and ankle
    if y < -3.15: return 6 if z < 0.35 else 0 # posterior calf, shin neutral
    if y < -0.45: return 4 if z > 0.10 else 5
    if x > 1.55 and 4.45 < y < 6.15 and ((x-2.05)/1.1)**2+((y-5.30)/1.05)**2 < 1.25: return 3
    if x > 2.25 and 3.25 < y < 4.75: return 7 if n[2] > 0.12 else 8
    if x > 2.1: return 0 # forearms and hands are not in canonical mapping
    # Pectoral lower edge curves upward at the sternum and the lateral edge.
    # Core stays unsupported/neutral below the pectoral surface.
    pec_floor = 4.00 + 0.24 * ((x-0.85)/1.05)**2
    if pec_floor < y < 5.75 and z > 0.35 and n[2] > 0: return 1
    if 1.4 < y < 5.95 and z < 0.20 and n[2] < 0.25: return 2
    return 0 # head, neck, abdomen and other unsupported surface

def convert():
    vertices, faces, groups, group, joint_vertices = [], [], Counter(), '', {}
    for line in (ASSETS/'makehuman-base.obj').read_text().splitlines():
        p = line.split()
        if not p: continue
        if p[0] == 'v': vertices.append(list(map(float, p[1:4])))
        elif p[0] == 'g': group = p[1]
        elif p[0] == 'f':
            groups[group] += 1
            if group == 'body': faces.append([int(s.split('/')[0])-1 for s in p[1:]])
            elif group in ('joint-l-shoulder','joint-l-elbow','joint-l-hand'):
                joint_vertices.setdefault(group,set()).update(int(s.split('/')[0])-1 for s in p[1:])
    sources = ['makehuman-base.obj', 'MakeHuman-ASSETS.md', 'MakeHuman-LICENSE.md']
    # Blend adult male ancestry equally. Mass targets are a convex 30/70 blend
    # inside upstream bounds, never extrapolated beyond the authored extremes.
    for name, weight in MORPHS:
        sources.append(name)
        for line in (ASSETS/name).read_text().splitlines():
            p = line.split()
            if not p or p[0].startswith('#'): continue
            i = int(p[0])
            for k in range(3): vertices[i][k] += float(p[k+1])*weight
    # Retain source-space coordinates exclusively for semantic partitions.
    original = [v[:] for v in vertices]
    vertices = [athletic_surface(v) for v in vertices]
    # Derive pivots from sculpted joint helper vertices before dropping helpers.
    joints = {name:[sum(vertices[i][k] for i in ids)/len(ids) for k in range(3)] for name,ids in joint_vertices.items()}
    shoulder, elbow, wrist = (joints['joint-l-'+name] for name in ['shoulder','elbow','hand'])
    # Straighten the existing bent elbows, then rotate each arm down by 29°.
    # Blend only at joint seams. Head, fingers, toes and entire body are actual
    # upstream mesh vertices; no primitive body parts are created.
    for i, p in enumerate(vertices):
        sign = 1 if p[0] >= 0 else -1
        q = [abs(p[0]), p[1], p[2]]
        arm = smooth(shoulder[0]-.35, shoulder[0]+.60, q[0]) * smooth(0.0, .8, q[1])
        if not arm: continue
        q = rotate_between(q, elbow, sub(wrist,elbow), sub(elbow,shoulder), arm*(1-smooth(elbow[1]-.15,elbow[1]+.4,q[1])))
        a = -math.radians(29)*arm
        x, y = q[0]-shoulder[0], q[1]-shoulder[1]
        q[0], q[1] = shoulder[0]+math.cos(a)*x-math.sin(a)*y, shoulder[1]+math.sin(a)*x+math.cos(a)*y
        vertices[i] = [q[0]*sign,q[1],q[2]]
    used = sorted({i for face in faces for i in face})
    lookup = {old:new for new,old in enumerate(used)}
    positions = [vertices[i] for i in used]
    normals = [[0.,0.,0.] for _ in positions]
    indices, parts = [], []
    for f in faces:
        c = [sum(original[i][k] for i in f)/len(f) for k in range(3)]
        n = unit(cross(sub(original[f[1]],original[f[0]]),sub(original[f[2]],original[f[0]])))
        part = region(c,n)
        for j in range(1,len(f)-1):
            tri = [lookup[f[0]],lookup[f[j]],lookup[f[j+1]]]
            indices.extend(tri);parts.append(part)
            a,b,c2 = (positions[i] for i in tri)
            n2 = cross(sub(b,a),sub(c2,a))
            for i in tri:
                for k in range(3): normals[i][k] += n2[k]
    lo,hi = min(p[1] for p in positions),max(p[1] for p in positions)
    scale = 2/(hi-lo); mid=(lo+hi)/2
    positions = [[round(p[0]*scale,6),round((p[1]-mid)*scale,6),round((p[2]-.15)*scale,6)] for p in positions]
    mesh={'version':1,'regions':REGIONS,'positions':[v for p in positions for v in p],'normals':[round(v,6) for n in normals for v in unit(n)],'indices':indices,'triangleRegions':parts}
    (ASSETS/'body.mesh.json').write_text(json.dumps(mesh,separators=(',',':'))+'\n')
    provenance={'upstreamRevision':'a8bc2d54ff0ac92e78ff71431b1023eda42bf482','sourceSha256':{n:hashlib.sha256((ASSETS/n).read_bytes()).hexdigest() for n in sources},'meshSha256':hashlib.sha256((ASSETS/'body.mesh.json').read_bytes()).hexdigest(),'sourceVertexCount':len(vertices),'sourceGroups':dict(groups),'morphedPoseJoints':joints,'armDownRotationDegrees':29,'retainedGroup':'body','vertices':len(positions),'triangles':len(parts),'regionTriangles':dict(Counter(REGIONS[i] for i in parts))}
    provenance['morphWeights'] = dict(MORPHS)
    provenance['authoredRefinement'] = {'version':SCULPT_VERSION,'implementation':'tools/convert_mesh.py:athletic_surface',
        'method':'bilateral compact smooth surface displacement before arm posing; unchanged source body topology',
        'lowerBodyLengthFactor':.945,'ankleStanceInwardSourceUnits':.28,
        'description':'broader clavicles and deltoids; fuller pectorals, upper back/lats and upper arms; tapered waist; balanced thigh/calf volume'}
    (ASSETS/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print(json.dumps({k:provenance[k] for k in ['vertices','triangles','regionTriangles','meshSha256']},indent=2))

if __name__ == '__main__': convert()
