#!/usr/bin/env python3
"""Generates scene.rml for the CNCPT R1 showroom (glass vehicle UI in a photoreal 3D dusk landscape).

Shared infrastructure first, then the glass UI (panels, HUD, dock, hotspot pins, intro).

Generated: scene.rml (from this file). Hand-written: world.as, carpack.as, tex.as, *.wgsl.

Artboards
  * "Garage"   main, responsive: the 3D world (ScriptedLayout world.as) under the visor HUD.
  * "Panel 0-4" 600x780 glass panels shown on the visor lens: Status, Vehicle, Navigate, Media, Climate.
  * "Visor"    top bar and dock, wrapped onto a cylinder around the camera.
"""
import hashlib, math, os
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

_next = [10]


def nid():
    _next[0] += 1
    return f"0:{_next[0]}"


class E:
    def __init__(self, _tag, *children, **attrs):
        self.tag = _tag
        self.attrs = {}
        for k, v in attrs.items():
            if v is None:
                continue
            k = k.rstrip("_")
            if isinstance(v, bool):
                v = "true" if v else "false"
            elif isinstance(v, float):
                v = f"{v:.4f}".rstrip("0").rstrip(".") if abs(v) < 1e6 else str(v)
            self.attrs[k] = str(v)
        self.children = [c for c in children if c is not None]

    def add(self, *cs):
        self.children += [c for c in cs if c is not None]
        return self

    @property
    def id(self):
        return self.attrs.get("id")

    def assign_ids(self, path="", used=None):
        used = used if used is not None else set()
        if self.tag != "Rive" and "id" not in self.attrs:
            h = int(hashlib.sha1(path.encode()).hexdigest(), 16) % 900_000_000 + 100_000_000
            while f"1:{h}" in used:
                h += 1
            self.attrs["id"] = f"1:{h}"
        if "id" in self.attrs:
            used.add(self.attrs["id"])
        counts = {}
        for c in self.children:
            label = c.tag + ":" + c.attrs.get("name", "")
            counts[label] = counts.get(label, 0) + 1
            c.assign_ids(f"{path}/{label}#{counts[label]}", used)
        return used

    def render(self, ind=0):
        pad = "    " * ind
        a = " ".join(f"{k}={quoteattr(v)}" for k, v in self.attrs.items())
        head = f"{pad}<{self.tag}{(' ' + a) if a else ''}"
        if not self.children:
            return head + "/>\n"
        return head + ">\n" + "".join(c.render(ind + 1) for c in self.children) + f"{pad}</{self.tag}>\n"


def argb(hexrgb, a=255):
    return f"{a:02X}{hexrgb.lstrip('#').upper()}"


# ---------------------------------------------------------------- pop-art palette
INK = "#141414"
PAPER = "#FFF6E0"
YEL = "#FFE11A"
RED = "#E8262B"
BLUE = "#1C5FD6"
CYAN = "#1FB6F0"
PINK = "#FF6FA8"
WHITE = "#FFFFFF"
ORANGE = "#FF8A1C"

F_BANG, F_COMIC, F_LUCK = nid(), nid(), nid()  # legacy ids (unused by the glass UI)
F_INT = nid()          # Inter variable (wght 100-900, opsz)
WGHT = 2003265652      # 'wght' axis tag
SCRIPTS = {"world": nid(), "half": nid()}

# ---------------------------------------------------------------- view model
VM_ID, VMI_ID = nid(), nid()
VM_PROPS = {}


def vm_prop(name, typ, default):
    VM_PROPS[name] = (nid(), typ, default)


SECTIONS = ["STATUS", "VEHICLE", "NAVIGATE", "TUNES", "CLIMATE"]
for n, t_, d in [
    ("section", "number", -1), ("req", "number", 0), ("hud", "number", 0), ("compact", "number", 0),
    ("clock", "string", "14:30"), ("ampm", "string", ""), ("tempOut", "string", "12°"),
    ("charge", "string", "80"), ("chargeFrac", "number", 0.8), ("range", "string", "412"),
    ("day", "string", "Saturday, 24 October"), ("city", "string", "Munich"), ("date", "string", "24 Oct"),
    ("song", "string", "Main Theme"), ("artist", "string", "Rocket Squadron"), ("elapsed", "string", "1:42"),
    ("songLen", "string", "3:12"), ("songFrac", "number", 0.4), ("songPx", "number", 218), ("playing", "number", 1), ("tunesScroll", "number", 0),
    ("navScroll", "number", 0),
    ("tempL", "string", "21.5"), ("tempR", "string", "21.0"), ("fan", "number", 3),
    ("ac", "number", 1), ("auto", "number", 1), ("recirc", "number", 0), ("defrost", "number", 0), ("seat", "number", 1),
    ("sync", "number", 0),
    ("navDist", "string", "300 m"), ("navTurn", "string", "Turn left onto Leopoldstraße"), ("eta", "string", "14:48"),
    ("driveMode", "number", 0), ("airflow", "number", 0),
    ("lights", "number", 1), ("boost", "number", 0), ("beacon", "number", 0), ("glow", "number", 0),
    # graphics settings (Vehicle panel): quality 0 high / 1 balanced / 2 fast, plus per-effect switches
("vehScroll", "number", 0), ("dbgOff", "number", 0), ("gfxQ", "number", 0), ("gfxBlur", "number", 1), ("gfxRefl", "number", 1), ("gfxBloom", "number", 1),
    ("readout", "string", "Status  ·  Lights on"), ("keys", "number", 0),
] + [(f"pin{k}{c}", "number", 0) for k in range(4) for c in "xya"] + [
    # the animated Rive wordmark (logo.rml, shared with Rive City): one LogoVM instance per appearance
    ("logoA", "vm", "90:9003"), ("logoB", "vm", "90:9001"),
]:
    vm_prop(n, t_, d)


def path(name):
    return f"{VM_ID}-{VM_PROPS[name][0]}"


def bind(name, key, **kw):
    return E("DataBindContext", sourcePathIds=path(name), propertyKey=key, **kw)


def build_vm():
    props, vals = [], []
    for name, (pid, typ, default) in VM_PROPS.items():
        if typ == "string":
            props.append(E("ViewModelPropertyString", name=name, id=pid))
            vals.append(E("ViewModelInstanceString", propertyValue=default, viewModelPropertyId=pid))
        elif typ == "vm":
            props.append(E("ViewModelPropertyViewModel", name=name, id=pid, viewModelReferenceId=LOGO_VM))
            vals.append(E("ViewModelInstanceViewModel", propertyValue=default, viewModelPropertyId=pid))
        else:
            props.append(E("ViewModelPropertyNumber", name=name, id=pid))
            vals.append(E("ViewModelInstanceNumber", propertyValue=float(default), viewModelPropertyId=pid))
    return E("ViewModel", *props, E("ViewModelInstance", *vals, exports=True, name="Default", id=VMI_ID),
             name="Garage", id=VM_ID, defaultInstanceId=VMI_ID)


# ---------------------------------------------------------------- layout helpers
def style(**kw):
    sid = nid()
    attrs = {}
    for k, v in kw.items():
        if v is None:
            continue
        attrs[k] = v
        for unit_key in ("padding", "margin", "gap", "position"):
            if k.startswith(unit_key) and not k.endswith("UnitsValue") and k != "positionTypeValue":
                attrs[k + "UnitsValue"] = "points"
    return E("LayoutComponentStyle", id=sid, name="Style", **attrs), sid


def box(name, *children, w=None, h=None, ws="hug", hs="hug", dir="column", align="topLeft",
        pad=None, gap=None, fill=None, radius=None, stroke=None, clip=None, grow=None, bid=None,
        opacity=None, extra=None, binds=(), stack=False):
    st = dict(layoutWidthScaleType=ws, layoutHeightScaleType=hs, flexDirectionValue=dir, layoutAlignmentType=align)
    if stack:
        st["layoutTypeValue"] = "stack"
    if pad is not None:
        t, r, b, l = pad if isinstance(pad, (tuple, list)) else (pad,) * 4
        st.update(paddingTop=t, paddingRight=r, paddingBottom=b, paddingLeft=l)
    if gap is not None:
        st.update(gapHorizontal=gap, gapVertical=gap)
    if radius is not None:
        st.update(cornerRadiusTL=radius, linkCornerRadius=True)
    if grow is not None:
        st["flexGrow"] = grow
    if extra:
        st.update(extra)
    s, sid = style(**st)
    lc = E("LayoutComponent", s, name=name, id=bid or nid(), styleId=sid,
           width=w if w is not None else 0, height=h if h is not None else 0, clip=clip, opacity=opacity)
    for b in binds:
        lc.add(b)
    if fill is not None:
        lc.add(E("Fill", E("SolidColor", colorValue=fill, name="C"), name="Fill"))
    if stroke is not None:
        col, th = stroke
        lc.add(E("Stroke", E("SolidColor", colorValue=col, name="C"), thickness=th, name="Stroke"))
    lc.add(*children)
    return lc


def text(name, s, size, color=INK, font=None, bindname=None, ls=None, align="center", tid=None, lp=False,
         x=None, y=None, ox=0.5, oy=0.5, outline=None, rid=None, cid=None, width=None, wrap=False):
    sid = nid()
    font = font or F_BANG
    kids_paint = []
    if outline:
        ocol, oth = outline
        kids_paint.append(E("Stroke", E("SolidColor", colorValue=argb(ocol), name="C"), thickness=oth, join="round",
                            cap="round", name="Outline"))
    kids_paint.append(E("Fill", E("SolidColor", colorValue=argb(color), name="C", id=cid), name="Fill"))
    paint = E("TextStylePaint", *kids_paint, fontSize=size, fontAssetId=font, letterSpacing=ls, id=sid, name="Style")
    run = E("TextValueRun", styleId=sid, text=s, name="Run", id=rid)
    if bindname:
        run.add(bind(bindname, 268))
    kids = []
    if lp:
        kids.append(E("LayoutParticipant", layoutWidthScaleType="hug", layoutHeightScaleType="hug", name="Layout"))
    attrs = dict(name=name, id=tid or nid(), alignValue=align, x=x, y=y, originX=ox, originY=oy)
    if width:
        attrs.update(sizingValue="autoHeight", wrapValue="wrap", width=width)
    else:
        attrs.update(sizingValue="autoWidth", wrapValue="noWrap")
    return E("Text", *kids, paint, run, **attrs)


def node(name, *children, x=0, y=0, rot=None, opacity=None, scale=None, sx=None, sy=None, nid_=None, binds=()):
    # rot is in degrees here; RML rotation is radians
    return E("Node", *binds, *children, name=name, x=x, y=y, id=nid_ or nid(),
             rotation=math.radians(rot) if rot is not None else None, opacity=opacity,
             scaleX=sx if sx is not None else scale, scaleY=sy if sy is not None else scale)


def shape(name, *children, x=0, y=0, sid=None, opacity=None):
    return E("Shape", *children, name=name, x=x, y=y, id=sid or nid(), opacity=opacity)


def solid(col, cid=None):
    return E("Fill", E("SolidColor", colorValue=col, name="C", id=cid), name="Fill")


def stroke(col, th, cap="round", trim=None, join="round"):
    s = E("Stroke", E("SolidColor", colorValue=col, name="C"), thickness=th, cap=cap, join=join, name="Stroke")
    if trim is not None:
        s.add(trim)
    return s


def poly(pts, closed=True, name="Path"):
    return E("PointsPath", *[E("StraightVertex", x=round(px, 2), y=round(py, 2)) for px, py in pts],
             isClosed=closed, name=name)


def rect(w, h, r=0, x=0, y=0, ox=0.5, oy=0.5):
    return E("Rectangle", width=w, height=h, cornerRadiusTL=r, linkCornerRadius=True, x=x, y=y, originX=ox,
             originY=oy, name="Rect")


def ellipse(w, h, x=0, y=0):
    return E("Ellipse", width=w, height=h, x=x, y=y, name="Ellipse")


def burst_pts(ro, ri, n, jitter=0.18, seed=1, rot=0.0):
    import random
    rnd = random.Random(seed)
    pts = []
    for k in range(n * 2):
        a = rot + math.pi * k / n
        r = ro if k % 2 == 0 else ri
        r *= 1 + (rnd.random() - 0.5) * jitter
        pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def bubble_pts(w, h, tail_ang, tail_len, tail_w=0.28, n=72):
    """Ellipse with a pointed tail, as one closed polygon (no seams)."""
    pts = []
    for k in range(n):
        a = 2 * math.pi * k / n
        d = math.atan2(math.sin(a - tail_ang), math.cos(a - tail_ang))
        if abs(d) < tail_w / 2:
            if abs(d) < 2 * math.pi / n * 0.5:
                tx = (w / 2 + tail_len) * math.cos(tail_ang)
                ty = (h / 2 + tail_len) * math.sin(tail_ang)
                pts.append((tx, ty))
            continue
        pts.append((w / 2 * math.cos(a), h / 2 * math.sin(a)))
    return pts


def kf(value, frame, interp="cubic", kind="KeyFrameDouble", ease=(0.25, 0.1, 0.25, 1.0)):
    k = E(kind, value=value, frame=frame, interpolationType=interp)
    if interp == "cubic":
        k.add(E("CubicEaseInterpolator", x1=ease[0], y1=ease[1], x2=ease[2], y2=ease[3]))
    return k


def keyed(obj_id, *props):
    return E("KeyedObject", *props, objectId=obj_id)


def kprop(key, *frames):
    return E("KeyedProperty", *frames, propertyKey=key)


def cond_num(name, op, val):
    return E("TransitionViewModelCondition",
             E("TransitionPropertyViewModelComparator", E("BindablePropertyNumber", bind(name, 636))),
             E("TransitionValueNumberComparator", value=val), opValue=op)


def loop_layer(anim):
    st = nid()
    return E("StateMachineLayer", E("AnyState", x=0, y=-120), E("ExitState", x=300, y=-120),
             E("EntryState", E("StateTransition", stateToId=st), x=0, y=0),
             E("AnimationState", animationId=anim.id, id=st, x=200, y=0), name=anim.attrs["name"], id=nid())


def set_listener(target, prop, value, kind="click", name="Set"):
    return E("StateMachineListenerSingle",
             E("ListenerViewModelChange", E("BindablePropertyNumber", bind(prop, 636, direction=True), propertyValue=value)),
             targetId=target, listenerTypeValue=kind, name=name)


EASE_OUT = (0.16, 1.0, 0.3, 1.0)
EASE_IN = (0.7, 0.0, 0.84, 0.0)
EASE_IO = (0.65, 0.0, 0.35, 1.0)
BACK = (0.34, 1.56, 0.64, 1.0)
SOFT_BACK = (0.3, 1.3, 0.55, 1.0)   # gentle overshoot for rows settling into place
HARD_BACK = (0.3, 1.9, 0.5, 1.0)


# ---------------------------------------------------------------- motion kit
class Motion:
    """Collects keyed objects for one animation."""

    def __init__(self, name, dur, loop="oneShot"):
        self.name = name
        self.dur = dur
        self.loop = loop
        self.keys = {}  # obj id -> {prop: [frames]}

    def k(self, oid, prop, *frames):
        self.keys.setdefault(oid, {}).setdefault(prop, []).extend(frames)
        return self

    def build(self):
        objs = []
        for oid, props in self.keys.items():
            kp = []
            for prop, frames in props.items():
                frames = sorted(frames, key=lambda f: float(f.attrs["frame"]))
                kp.append(kprop(prop, *frames))
            objs.append(keyed(oid, *kp))
        return E("LinearAnimation", *objs, name=self.name, id=nid(), duration=self.dur, fps=60, loopValue=self.loop)


def pop(m, oid, t0, dur=18, s0=0.0, s1=1.0, over=HARD_BACK, fade=True):
    m.k(oid, 16, kf(s0, 0, "hold"), kf(s0, t0, "cubic", ease=over), kf(s1, t0 + dur, "hold"))
    m.k(oid, 17, kf(s0, 0, "hold"), kf(s0, t0, "cubic", ease=over), kf(s1, t0 + dur, "hold"))
    if fade:
        m.k(oid, 18, kf(0, 0, "hold"), kf(0, t0, "linear"), kf(1, t0 + 4, "hold"))


def unpop(m, oid, t0, dur=10, s0=1.0, s1=0.0, fade=True):
    m.k(oid, 16, kf(s0, 0, "hold"), kf(s0, t0, "cubic", ease=(0.5, -0.6, 0.8, 0.4)), kf(s1, t0 + dur, "hold"))
    m.k(oid, 17, kf(s0, 0, "hold"), kf(s0, t0, "cubic", ease=(0.5, -0.6, 0.8, 0.4)), kf(s1, t0 + dur, "hold"))
    if fade:
        m.k(oid, 18, kf(1, 0, "hold"), kf(1, t0 + dur - 4, "linear"), kf(0, t0 + dur, "hold"))


def slide(m, oid, prop, t0, dur, v0, v1, ease=EASE_OUT):
    m.k(oid, prop, kf(v0, 0, "hold"), kf(v0, t0, "cubic", ease=ease), kf(v1, t0 + dur, "hold"))


def hold(m, oid, prop, v):
    m.k(oid, prop, kf(v, 0, "hold"))


# ---------------------------------------------------------------- v2 UI: layout-built toon vehicle UI
MUTED = "#6E655B"
GREEN = "#2BB673"

ICON_SFX = ["KA-POW!", "VROOOM!", "ZOOM!", "WHOOSH!", "BRRR!"]
SFX_COL = [YEL, ORANGE, CYAN, PINK, CYAN]


def _circ(cx, cy, r, n=28, a0=0.0, a1=2 * math.pi):
    return [(cx + r * math.cos(a0 + (a1 - a0) * k / n), cy + r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]


def _gear():
    pts = []
    for k in range(48):
        a = 2 * math.pi * k / 48
        r = 0.82 if (k // 3) % 2 == 0 else 0.62
        pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def _star(ro=0.9, ri=0.4):
    return [((ro if k % 2 == 0 else ri) * math.cos(-math.pi / 2 + k * math.pi / 5),
             (ro if k % 2 == 0 else ri) * math.sin(-math.pi / 2 + k * math.pi / 5)) for k in range(10)]


# each icon: list of (points in -1..1 space with y down, closed, filled)
ICON = {
    "home": [([(-0.85, 0.0), (0, -0.8), (0.85, 0.0)], False, False), ([(-0.55, -0.2), (-0.55, 0.78), (0.55, 0.78), (0.55, -0.2)], False, False)],
    "car": [([(-0.9, 0.38), (-0.9, 0.02), (-0.62, -0.1), (-0.4, -0.52), (0.4, -0.52), (0.62, -0.1), (0.9, 0.02), (0.9, 0.38)], True, False),
            (_circ(-0.52, 0.42, 0.17), True, True), (_circ(0.52, 0.42, 0.17), True, True)],
    "nav": [([(-0.8, -0.05), (0.8, -0.75), (0.12, 0.8), (-0.02, 0.06)], True, False)],
    "gear": [(_gear(), True, False), (_circ(0, 0, 0.26), True, False)],
    "apps": [([(-0.8, -0.8), (-0.15, -0.8), (-0.15, -0.15), (-0.8, -0.15)], True, False), ([(-0.8, 0.15), (-0.15, 0.15), (-0.15, 0.8), (-0.8, 0.8)], True, False),
             ([(0.15, 0.15), (0.8, 0.15), (0.8, 0.8), (0.15, 0.8)], True, False), ([(0.48, -0.85), (0.48, -0.1)], False, False), ([(0.1, -0.48), (0.86, -0.48)], False, False)],
    "note": [([(-0.05, 0.55), (-0.05, -0.75), (0.65, -0.5), (0.65, -0.25), (-0.05, -0.45)], False, False), (_circ(-0.32, 0.55, 0.3), True, True)],
    "fan": [(_circ(0, 0, 0.15), True, True)] + [([(0, 0)] + [((0.12 + 0.75 * math.sin(j / 8 * math.pi)) * math.cos(a + j * 0.17), (0.12 + 0.75 * math.sin(j / 8 * math.pi)) * math.sin(a + j * 0.17)) for j in range(9)], True, False)
                                                 for a in (0.0, 2.094, 4.189)],
    "snow": [([(0, -0.9), (0, 0.9)], False, False), ([(-0.78, -0.45), (0.78, 0.45)], False, False), ([(-0.78, 0.45), (0.78, -0.45)], False, False)],
    "seat": [([(-0.35, -0.85), (-0.5, 0.35), (0.45, 0.35), (0.55, 0.75)], False, False), ([(0.05, -0.6), (0.25, -0.4), (0.05, -0.2), (0.25, 0.0)], False, False)],
    "power": [(_circ(0, 0.08, 0.72, 24, -math.pi * 0.32, math.pi * 1.32), False, False), ([(0, -0.88), (0, -0.05)], False, False)],
    "defrost": [([(-0.8, -0.2), (-0.8, 0.75), (0.8, 0.75), (0.8, -0.2)], False, False)] + [([(x, 0.45), (x + 0.12, 0.15), (x, -0.15), (x + 0.12, -0.45), (x, -0.75)], False, False) for x in (-0.4, -0.05, 0.3)],
    "user": [(_circ(0, -0.4, 0.38), True, False), (_circ(0, 0.95, 0.75, 24, math.pi, 2 * math.pi), False, False)],
    "mute": [([(-0.85, -0.3), (-0.45, -0.3), (0.05, -0.75), (0.05, 0.75), (-0.45, 0.3), (-0.85, 0.3)], True, False), ([(0.35, -0.35), (0.85, 0.35)], False, False), ([(0.85, -0.35), (0.35, 0.35)], False, False)],
    "play": [([(-0.45, -0.75), (0.75, 0), (-0.45, 0.75)], True, True)],
    "pause": [([(-0.45, -0.7), (-0.45, 0.7)], False, False), ([(0.45, -0.7), (0.45, 0.7)], False, False)],
    "prev": [([(-0.7, -0.7), (-0.7, 0.7)], False, False), ([(0.7, -0.7), (-0.35, 0), (0.7, 0.7)], True, True)],
    "next": [([(0.7, -0.7), (0.7, 0.7)], False, False), ([(-0.7, -0.7), (0.35, 0), (-0.7, 0.7)], True, True)],
    "shuffle": [([(-0.85, -0.5), (-0.3, -0.5), (0.3, 0.5), (0.85, 0.5)], False, False), ([(-0.85, 0.5), (-0.3, 0.5), (0.3, -0.5), (0.85, -0.5)], False, False),
                ([(0.6, -0.75), (0.85, -0.5), (0.6, -0.25)], False, False), ([(0.6, 0.25), (0.85, 0.5), (0.6, 0.75)], False, False)],
    "repeat": [([(-0.8, 0.2), (-0.8, -0.45), (0.75, -0.45)], False, False), ([(0.8, -0.2), (0.8, 0.45), (-0.75, 0.45)], False, False),
               ([(0.5, -0.7), (0.78, -0.45), (0.5, -0.2)], False, False), ([(-0.5, 0.2), (-0.78, 0.45), (-0.5, 0.7)], False, False)],
    "signal": [([(x, 0.8), (x, 0.8 - h)], False, False) for x, h in ((-0.7, 0.4), (-0.25, 0.75), (0.2, 1.1), (0.65, 1.5))],
    "bt": [([(-0.55, -0.4), (0.5, 0.42), (0, 0.85), (0, -0.85), (0.5, -0.42), (-0.55, 0.4)], False, False)],
    "cam": [([(-0.85, -0.5), (0.3, -0.5), (0.3, 0.5), (-0.85, 0.5)], True, False), ([(0.3, -0.1), (0.85, -0.45), (0.85, 0.45), (0.3, 0.1)], True, False)],
    "search": [(_circ(-0.15, -0.15, 0.55), True, False), ([(0.25, 0.25), (0.8, 0.8)], False, False)],
    "pin": [([(0, 0.88)] + _circ(0, -0.25, 0.58, 22, math.pi * 0.78, math.pi * 2.22) + [(0, 0.88)], True, False), (_circ(0, -0.25, 0.2), True, True)],
    "star": [(_star(), True, False)],
    "flag": [([(-0.6, 0.9), (-0.6, -0.85)], False, False), ([(-0.6, -0.8), (0.8, -0.8), (0.5, -0.4), (0.8, 0.0), (-0.6, 0.0)], True, False)],
    "brief": [([(-0.85, -0.35), (0.85, -0.35), (0.85, 0.75), (-0.85, 0.75)], True, False), ([(-0.3, -0.35), (-0.3, -0.7), (0.3, -0.7), (0.3, -0.35)], False, False)],
    "bolt": [([(0.15, -0.9), (-0.55, 0.12), (-0.05, 0.12), (-0.2, 0.9), (0.55, -0.15), (0.05, -0.15)], True, True)],
    "minus": [([(-0.6, 0), (0.6, 0)], False, False)],
    "plus": [([(-0.6, 0), (0.6, 0)], False, False), ([(0, -0.6), (0, 0.6)], False, False)],
    "turnleft": [([(0.45, 0.9), (0.45, -0.1), (-0.5, -0.1)], False, False), ([(-0.15, -0.5), (-0.55, -0.1), (-0.15, 0.3)], False, False)],
    "light": [(_circ(-0.3, 0, 0.5, 18, math.pi * 0.5, math.pi * 1.5) + [(-0.3, 0.5)], True, False)] + [([(0.05, y), (0.85, y)], False, False) for y in (-0.42, 0.0, 0.42)],
    "beacon": [([(-0.55, 0.55), (-0.45, -0.1), (0, -0.4), (0.45, -0.1), (0.55, 0.55)], True, False), ([(-0.8, 0.75), (0.8, 0.75)], False, False),
               ([(0, -0.62), (0, -0.92)], False, False), ([(-0.62, -0.42), (-0.82, -0.62)], False, False), ([(0.62, -0.42), (0.82, -0.62)], False, False)],
    "glow": [([(-0.85, 0.05), (-0.6, -0.4), (0.6, -0.4), (0.85, 0.05)], True, False)] + [([(x - 0.15, 0.45), (x, 0.3), (x + 0.15, 0.45), (x + 0.3, 0.3)], False, False) for x in (-0.65, -0.05, 0.5)],
    "sun": [(_circ(0, 0, 0.38), True, False)] + [([(0.58 * math.cos(k * math.pi / 4), 0.58 * math.sin(k * math.pi / 4)), (0.9 * math.cos(k * math.pi / 4), 0.9 * math.sin(k * math.pi / 4))], False, False) for k in range(8)],
    "chev": [([(-0.25, -0.6), (0.35, 0), (-0.25, 0.6)], False, False)],
    "recirc": [(_circ(0, 0, 0.62, 22, math.pi * 0.2, math.pi * 1.8), False, False), ([(0.25, 0.25), (0.52, 0.38), (0.62, 0.08)], False, False)],
    "sync": [(_circ(-0.3, 0, 0.42), True, False), (_circ(0.3, 0, 0.42), True, False)],
    "auto": [([(-0.65, 0.75), (0, -0.75), (0.65, 0.75)], False, False), ([(-0.38, 0.15), (0.38, 0.15)], False, False)],
}


def icon(name, kind, size=32, col=INK, th=3.5, outline=None, art_id=None):
    """A toon icon in a fixed box (so it can sit in a flex row). outline=(colour, extra) adds an ink keyline."""
    s = size / 2 * 0.86
    shapes = []
    for i, (pts, closed, filled) in enumerate(ICON[kind]):
        P = [(round(x * s, 2), round(y * s, 2)) for x, y in pts]
        kids = [poly(P, closed=closed)]
        if outline:
            kids.append(stroke(argb(outline[0]), th + outline[1]))
        if filled:
            kids.append(stroke(argb(col if not outline else outline[0]), th if not outline else th + outline[1]))
            kids.append(solid(argb(col)))
        else:
            kids.append(stroke(argb(col), th))
        shapes.append(shape(f"{name} {i}", *kids))
    return box(name, node(name + " Art", *shapes, x=size / 2, y=size / 2, nid_=art_id), w=size, h=size, ws="fixed", hs="fixed")


def lbl(name, s, size=19, col=MUTED, **kw):
    return text(name, s, size, col, font=F_BANG, lp=True, ls=1.5, **kw)


def body(name, s, size=17, col=MUTED, **kw):
    return text(name, s, size, col, font=F_COMIC, lp=True, **kw)


def spacer(name):
    return box(name, ws="fill", grow=1, h=1, hs="fixed")


def card(name, *kids, fill=WHITE, th=3.5, radius=18, pad=16, gap=12, dir="column", align="topLeft", ws="fill", hs="hug",
         w=None, h=None, bid=None, grow=None, fill_id=None, clip=None):
    c = box(name, *kids, fill=None, stroke=(argb(INK), th), radius=radius, pad=pad, gap=gap, dir=dir, align=align, ws=ws,
            hs=hs, w=w, h=h, bid=bid, grow=grow, clip=clip)
    # fill as its own paint so it can be keyed (selection states)
    c.children.insert(1, E("Fill", E("SolidColor", colorValue=argb(fill), name="C", id=fill_id or nid()), name="Fill"))
    return c


def fill_id_of(c):
    return c.children[1].children[0].id


def round_btn(name, kind, size=56, fill=WHITE, isize=None, th=3.5, bid=None):
    return card(name, icon(name + " Icon", kind, isize or int(size * 0.5), INK, th), fill=fill, radius=size / 2, pad=0, gap=0,
                align="center", ws="fixed", hs="fixed", w=size, h=size, bid=bid or nid())


def two_state(name, prop, on_op, on_val, keys, dur=12):
    """Two-state layer: keys = (object id, property key, off value, on value, 'c' colour | 'd' double)."""
    def anim(lbl_, to_on):
        objs = {}
        for oid, key, off, on, kind in keys:
            a, b = (off, on) if to_on else (on, off)
            if kind == "c":
                fr = [E("KeyFrameColor", value=a, frame=0, interpolationType="linear"), E("KeyFrameColor", value=b, frame=max(1, dur // 2), interpolationType="hold")]
            elif kind == "u":   # enum / uint (e.g. a style's displayValue): switches at once
                fr = [E("KeyFrameUint", value=b, frame=0, interpolationType="hold")]
            else:
                fr = [kf(a, 0, "cubic", ease=BACK), kf(b, dur, "hold")]
            objs.setdefault(oid, []).append(kprop(key, *fr))
        return E("LinearAnimation", *[keyed(o, *ps) for o, ps in objs.items()], name=f"{name} {lbl_}", id=nid(), duration=dur, fps=60)
    a_on, a_off = anim("On", True), anim("Off", False)
    off_op = {"greaterThan": "lessThan", "equal": "notEqual"}[on_op]
    off_val = on_val
    s_on, s_off = nid(), nid()
    layer = E("StateMachineLayer", E("AnyState", x=0, y=-120), E("ExitState", x=500, y=-120),
              E("EntryState", E("StateTransition", stateToId=s_off), x=0, y=0),
              E("AnimationState", E("StateTransition", cond_num(prop, on_op, on_val), stateToId=s_on), animationId=a_off.id, id=s_off, x=200, y=0),
              E("AnimationState", E("StateTransition", cond_num(prop, off_op, off_val), stateToId=s_off), animationId=a_on.id, id=s_on, x=200, y=140),
              name=name, id=nid())
    return [a_on, a_off], layer


class Ctx:
    """Collects animations, state layers and listeners for one artboard."""

    def __init__(self):
        self.anims, self.layers, self.listeners = [], [], []
        self.arrive = []   # callables (m_in, m_out, m_closed) adding hero keys to a panel's In / Out / Closed

    def loop(self, motion):
        """An idle loop in its own state-machine layer."""
        a = motion.build()
        self.anims.append(a)
        self.layers.append(loop_layer(a))

    def toggle(self, name, prop, keys, on_op="greaterThan", on_val=0.5, dur=12):
        a, l = two_state(name, prop, on_op, on_val, keys, dur)
        self.anims += a
        self.layers.append(l)

    def click(self, target, prop, value, name="Click"):
        self.listeners.append(set_listener(target, prop, value, name=name))


# ==================================================================== glass UI
# Smoked-glass cards, thin Inter, big light numerals, one lime accent (the light wall).

TXT = "#F4F6F7"
MUT = "#A3ACB4"
FAINT = "#6B747C"
# accent: a Rive prism colour (RS_ACCENT=amber|blue|red|cyan|green to compare); text on it picks dark or white
_ACCENTS = {"amber": "#FFA41C", "blue": "#3084FF", "red": "#F30058", "cyan": "#19F2FF", "green": "#71FF19", "lime": "#D8FF2E"}
ACC = _ACCENTS[os.environ.get("RS_ACCENT", "amber")]


def _lum(h):
    r, g, b = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


INKD = "#0B0D0F" if _lum(ACC) > 0.45 else "#FFFFFF"   # text / icons on an accent fill
WHITE = "#FFFFFF"
GLASS = argb("#0B0E11", 0x8C)
GLASS_HI = argb("#FFFFFF", 0x10)
GLASS_HI2 = argb("#FFFFFF", 0x1C)
BORDER = argb("#FFFFFF", 0x26)
HAIR = argb("#FFFFFF", 0x1F)

W_THIN, W_LIGHT, W_REG, W_MED, W_SEMI = 200, 300, 400, 500, 600


def t(name, s, size, col=TXT, weight=W_REG, ls=None, bindname=None, cid=None, rid=None, wrap_w=None, align="left"):
    """Inter text that participates in layout (hug)."""
    sid = nid()
    paint = E("TextStylePaint", E("Fill", E("SolidColor", colorValue=argb(col), name="C", id=cid), name="Fill"),
              E("TextStyleAxis", tag=WGHT, axisValue=weight, name="W"),
              fontSize=size, fontAssetId=F_INT, letterSpacing=ls, id=sid, name="Style")
    run = E("TextValueRun", styleId=sid, text=s, name="Run", id=rid)
    if bindname:
        run.add(bind(bindname, 268))
    lp = E("LayoutParticipant", layoutWidthScaleType="fill" if wrap_w else "hug", layoutHeightScaleType="hug", name="Layout")
    attrs = dict(name=name, id=nid(), alignValue=align)
    if wrap_w:
        attrs.update(sizingValue="autoHeight", wrapValue="wrap")
    else:
        attrs.update(sizingValue="autoWidth", wrapValue="noWrap")
    txt = E("Text", lp, paint, run, **attrs)
    if wrap_w:
        return box(name + " Wrap", txt, w=wrap_w, ws="fixed")
    return txt


def cap(name, s, col=MUT, size=12.5):
    """Small letter-spaced caption."""
    return t(name, s.upper(), size, col, W_MED, ls=1.6)


def gicon(name, kind, size=24, col=TXT, th=1.7, art_id=None):
    return icon(name, kind, size, col, th, art_id=art_id)


def gcard(name, *kids, fill=GLASS_HI, radius=6, pad=16, gap=10, dir="column", align="topLeft", ws="fill", hs="hug", w=None,
          h=None, bid=None, grow=None, fill_id=None, border=False, clip=None):
    c = box(name, *kids, radius=radius, pad=pad, gap=gap, dir=dir, align=align, ws=ws, hs=hs, w=w, h=h, bid=bid, grow=grow, clip=clip,
            stroke=(BORDER, 1.0) if border else None)
    c.children.insert(1, E("Fill", E("SolidColor", colorValue=fill, name="C", id=fill_id or nid()), name="Fill"))
    return c


def style_id(lc):
    """Id of a LayoutComponent's own LayoutComponentStyle (to key displayValue etc.)."""
    for c in lc.children:
        if c.tag == "LayoutComponentStyle":
            return c.attrs["id"]
    raise KeyError(lc.attrs.get("name"))


def gfill_id(c):
    return c.children[1].children[0].id


def circle_btn(name, kind, size=48, fill=GLASS_HI2, col=TXT, isize=None, th=1.7, bid=None, border=True):
    return gcard(name, gicon(name + " I", kind, isize or int(size * 0.46), col, th), fill=fill, radius=size / 2, pad=0, gap=0,
                 align="center", ws="fixed", hs="fixed", w=size, h=size, bid=bid or nid(), border=border)


def gswitch(cx, name, prop, req):
    knob_id, fid = nid(), nid()
    sw_id = nid()
    track = shape(name + " Track", rect(52, 30, 15), E("Fill", E("SolidColor", colorValue=argb("#FFFFFF", 0x2E), name="C", id=fid), name="Fill"))
    knob = node(name + " Knob", shape(name + " Knob Shape", ellipse(24, 24), solid(argb(WHITE))), x=-11, nid_=knob_id)
    sw = box(name, node(name + " Art", knob, track, x=26, y=15), w=52, h=30, ws="fixed", hs="fixed", bid=sw_id)
    cx.toggle(name, prop, [(fid, 37, argb("#FFFFFF", 0x2E), argb(ACC), "c"), (knob_id, 13, -11, 11, "d")])
    cx.click(sw_id, "req", req, name=name)
    return sw


def gseg(cx, name, labels, prop):
    segs = []
    for i, s in enumerate(labels):
        sid, tcid = nid(), nid()
        c = gcard(f"{name} {s}", t(f"{name} {s} T", s, 15, TXT, W_MED, cid=tcid), fill=argb(ACC, 0), radius=4, pad=(0, 8, 0, 8),
                  align="center", ws="fill", hs="fixed", h=40, grow=1, bid=sid)
        cx.toggle(f"{name} {s}", prop, [(gfill_id(c), 37, argb(ACC, 0), argb(ACC), "c"), (tcid, 37, argb(TXT), argb(INKD), "c")],
                  on_op="equal", on_val=i)
        cx.click(sid, prop, i, name=f"{name} {s}")
        segs.append(c)
    return gcard(name, *segs, fill=GLASS_HI, radius=6, pad=3, gap=3, dir="row")


def hair(name):
    return box(name, ws="fill", h=1, hs="fixed", fill=HAIR)


def bignum(name, s, size, bindname=None, unit=None, usize=None, weight=W_THIN, col=TXT):
    kids = [t(name, s, size, col, weight, bindname=bindname, ls=-size * 0.02)]
    if unit:
        kids.append(t(name + " U", unit, usize or size * 0.32, MUT, W_LIGHT))
    return box(name + " Row", *kids, dir="row", align="topLeft" if unit in ("°", "%") else "bottomLeft", gap=3 if unit in ("°", "%") else 6)


def kv(name, label, value, unit=None, align="topLeft", vsize=30, bindname=None):
    return box(name, cap(name + " L", label), bignum(name + " V", value, vsize, unit=unit, usize=vsize * 0.45, weight=W_LIGHT, bindname=bindname),
               gap=4, align=align)


def bar(name, frac, w=None, h=4, col=ACC, bid=None, binds=()):
    fill_w = int(frac * (w or 532))
    return box(name, box(name + " Fill", w=fill_w, ws="fixed", hs="fill", fill=argb(col), radius=h / 2, bid=bid, binds=binds),
               ws="fill" if w is None else "fixed", w=w, h=h, hs="fixed", fill=argb("#FFFFFF", 0x22), radius=h / 2, clip=True, dir="row")


def list_row(name, kind, title, sub, right=None, right_sub=None, accent=False):
    return gcard(name, circle_btn(name + " B", kind, 40, fill=argb(ACC) if accent else GLASS_HI2, col=INKD if accent else TXT, border=not accent),
                 box(name + " Txt", t(name + " T", title, 17, TXT, W_MED), t(name + " S", sub, 13.5, MUT, W_REG), gap=2),
                 spacer(name + " Sp"),
                 *([box(name + " R", t(name + " RV", right, 17, TXT, W_LIGHT), *([t(name + " RS", right_sub, 13, MUT)] if right_sub else []),
                        gap=2, align="topRight")] if right else []),
                 dir="row", align="centerLeft", pad=(12, 16, 12, 12), gap=14, radius=6)


# ---------------------------------------------------------------- extra icons (same -1..1 convention)
ICON["keys"] = [([(-0.9, -0.55), (0.9, -0.55), (0.9, 0.55), (-0.9, 0.55)], True, False),
                ([(-0.55, -0.18), (-0.5, -0.18)], False, False), ([(-0.18, -0.18), (-0.13, -0.18)], False, False),
                ([(0.18, -0.18), (0.23, -0.18)], False, False), ([(0.52, -0.18), (0.57, -0.18)], False, False),
                ([(-0.45, 0.22), (0.45, 0.22)], False, False)]
ICON["chevl"] = [([(0.25, -0.6), (-0.35, 0), (0.25, 0.6)], False, False)]
ICON["drop"] = [([(0, -0.9), (0.55, 0.05)] + _circ(0, 0.25, 0.55, 18, -0.1, math.pi + 0.1) + [(-0.55, 0.05), (0, -0.9)], True, False)]
ICON["plug"] = [([(-0.3, -0.85), (-0.3, -0.35)], False, False), ([(0.3, -0.85), (0.3, -0.35)], False, False),
                ([(-0.6, -0.35), (0.6, -0.35), (0.6, 0.05), (0, 0.55), (-0.6, 0.05)], True, False), ([(0, 0.55), (0, 0.9)], False, False)]
ICON["tyre"] = [(_circ(0, 0, 0.82), True, False), (_circ(0, 0, 0.42), True, False)] + \
               [([(0.42 * math.cos(a), 0.42 * math.sin(a)), (0.82 * math.cos(a), 0.82 * math.sin(a))], False, False) for a in (0.0, 2.094, 4.189)]
ICON["lock"] = [([(-0.6, -0.05), (0.6, -0.05), (0.6, 0.85), (-0.6, 0.85)], True, False), (_circ(0, -0.05, 0.38, 14, math.pi, 2 * math.pi), False, False)]
ICON["leaf"] = [([(-0.7, 0.7)] + [(-0.7 + 1.5 * k / 10, 0.7 - 1.5 * k / 10 - 0.45 * math.sin(k / 10 * math.pi)) for k in range(11)] +
                 [(0.8 - 1.5 * k / 10 + 0.0, -0.8 + 1.5 * k / 10 + 0.45 * math.sin(k / 10 * math.pi)) for k in range(11)], True, False),
                ([(-0.7, 0.7), (0.3, -0.3)], False, False)]
ICON["wrench"] = [([(-0.75, 0.75), (0.15, -0.15)], False, False), (_circ(0.38, -0.38, 0.38, 16, math.pi * 0.95, math.pi * 2.55), False, False)]
ICON["cloud"] = [(_circ(-0.3, 0.1, 0.38, 12, math.pi * 0.5, math.pi * 1.5) + _circ(0.05, -0.15, 0.45, 12, math.pi * 1.05, math.pi * 1.95) +
                  _circ(0.45, 0.15, 0.33, 10, math.pi * 1.5, math.pi * 2.5) + [(-0.3, 0.48)], True, False)]


# ---------------------------------------------------------------- panel artboards (600 x 780, glass)
PW, PH = 600, 780
HEAD_H = 92
PAD_X = 30


def panel_glass(k, title, sub, kind, rows, cx, x_off):
    s, sid = style(layoutWidthScaleType="fixed", layoutHeightScaleType="fixed", layoutTypeValue="stack")
    ab = E("Artboard", s, name=f"Panel {k}", id=nid(), width=PW, height=PH, styleId=sid, viewModelId=VM_ID,
           viewModelInstanceId=VMI_ID, x=x_off, y=1200, clip=True)
    badge_art, title_id, accent_id, sheen_id = nid(), nid(), nid(), nid()
    head = box("Header",
               gcard("Badge", gicon("Badge Icon", kind, 24, TXT, 1.8, art_id=badge_art), fill=GLASS_HI2, radius=24, pad=0, gap=0, align="center",
                     ws="fixed", hs="fixed", w=48, h=48, border=True),
               box("Title Col", t("Title", title, 30, TXT, W_LIGHT, ls=-0.3), t("Sub", sub.upper(), 11.5, MUT, W_MED, ls=1.8), gap=2,
                   bid=title_id),
               spacer("Head Spacer"),
               box("Head Dot", w=8, h=8, ws="fixed", hs="fixed", fill=argb(ACC), radius=4),
               ws="fill", h=HEAD_H, hs="fixed", dir="row", align="centerLeft", pad=(0, PAD_X, 0, PAD_X - 4), gap=14)
    rule = box("Head Rule", box("Accent", w=0, h=2, ws="fixed", hs="fixed", fill=argb(ACC), radius=1, bid=accent_id),
               ws="fill", h=2, hs="fixed", dir="row", align="centerLeft", pad=(0, PAD_X, 0, PAD_X), fill=None)
    phys = E("ElasticScrollPhysics", friction=2.6, speedMultiplier=1.2, elasticFactor=0.6, name="Scroll Physics", id=nid())
    scroll_id = nid()
    # Vehicle panel: the scroll offset is mirrored into the VM (two-way) so world.as keeps the callout lines on
    # their rows while the panel scrolls
    sbind = [bind("vehScroll", 760, twoWay="true")] if k == 1 else []
    content = box("Body Content", E("ScrollConstraint", *sbind, directionValue="vertical", physicsId=phys.id, name="Scroll", id=scroll_id),
                  *rows, ws="fill", hs="hug", pad=(22, PAD_X, 44, PAD_X), gap=16)
    thumb = box("Thumb", E("ScrollBarConstraint", scrollConstraintId=scroll_id, directionValue="vertical", name="Bar"),
                w=3, h=80, ws="fixed", hs="fixed", fill=argb("#FFFFFF", 0x55), radius=1.5)
    body_h = PH - HEAD_H - 2
    track = box("Track", thumb, w=3, h=body_h - 60, ws="fixed", hs="fixed", fill=argb("#FFFFFF", 0x12), radius=1.5,
                extra=dict(positionTypeValue="absolute", positionRight=10, positionTop=24))
    bodyc = box("Body", content, track, ws="fill", h=body_h, hs="fixed", clip=True)
    # glass sheen: a soft diagonal light band that sweeps across the card as it arrives
    band = shape("Sheen Band", rect(160, 1400, 0),
                 E("Fill", E("LinearGradient", E("GradientStop", colorValue=argb("#FFFFFF", 0), position=0),
                             E("GradientStop", colorValue=argb("#FFFFFF", 0x1A), position=0.5),
                             E("GradientStop", colorValue=argb("#FFFFFF", 0), position=1),
                             startX=-80, startY=0, endX=80, endY=0, name="G"), name="Fill"))
    sheen = box("Sheen", box("Sheen Anchor", node("Sheen Art", band, x=-300, y=PH / 2, rot=18, nid_=sheen_id), w=0, h=0, ws="fixed", hs="fixed"),
                w=PW, h=PH, ws="fixed", hs="fixed", clip=True, extra=dict(positionTypeValue="absolute", positionLeft=0, positionTop=0))
    # top-edge highlight: glass catches light along its upper rim
    rim = box("Rim", w=PW - 60, h=1, ws="fixed", hs="fixed", fill=argb("#FFFFFF", 0x30),
              extra=dict(positionTypeValue="absolute", positionLeft=30, positionTop=0))
    face = box("Face", head, rule, bodyc, ws="fill", hs="fill", fill=GLASS, stroke=(BORDER, 1.2), radius=6, clip=True)
    root = box("Panel", sheen, rim, face, ws="fill", hs="fill", stack=True)
    ab.add(root, phys)

    m_in, m_out, m_closed = Motion("In", 110), Motion("Out", 26), Motion("Closed", 1)
    m_in.k(accent_id, 7, kf(0, 0, "hold"), kf(0, 8, "cubic", ease=EASE_OUT), kf(132, 34, "hold"))
    m_out.k(accent_id, 7, kf(132, 0, "cubic", ease=EASE_IN), kf(0, 12, "hold"))
    hold(m_closed, accent_id, 7, 0)
    m_in.k(badge_art, 16, kf(0.4, 0, "hold"), kf(0.4, 4, "cubic", ease=BACK), kf(1, 26, "hold"))
    m_in.k(badge_art, 17, kf(0.4, 0, "hold"), kf(0.4, 4, "cubic", ease=BACK), kf(1, 26, "hold"))
    m_in.k(badge_art, 15, kf(-0.8, 0, "hold"), kf(-0.8, 4, "cubic", ease=EASE_OUT), kf(0, 30, "hold"))
    m_in.k(title_id, 18, kf(0, 0, "hold"), kf(0, 6, "linear"), kf(1, 20, "hold"))
    m_out.k(title_id, 18, kf(1, 0, "linear"), kf(0, 10, "hold"))
    hold(m_closed, title_id, 18, 0)
    m_in.k(sheen_id, 13, kf(-320, 0, "hold"), kf(-320, 6, "cubic", ease=(0.45, 0.0, 0.25, 1.0)), kf(PW + 320, 52, "hold"))
    hold(m_closed, sheen_id, 13, -320)
    hold(m_out, sheen_id, 13, -320)
    # Choreographed arrival: rows rise into place one after another with a soft overshoot, and inside each
    # row the items cascade a beat later (the row's own children, battery cells as a wave, week bars growing
    # from the baseline). Exit is a quick staggered drop while the card itself slides away in 3D (world.as).
    def lcs(e):
        return [c for c in e.children if c.tag == "LayoutComponent" and c.id]

    def find(e, pred, out):
        if pred(e):
            out.append(e)
        for c in e.children:
            find(c, pred, out)
        return out

    m_in.k(title_id, 13, kf(28, 0, "hold"), kf(28, 6, "cubic", ease=EASE_OUT), kf(0, 34, "hold"))
    hold(m_closed, title_id, 13, 28)
    n = len(rows)
    for i, r in enumerate(rows):
        t0 = 10 + int(i * 3.5)
        m_in.k(r.id, 18, kf(0, 0, "hold"), kf(0, t0, "linear"), kf(1, t0 + 12, "hold"))
        slide(m_in, r.id, 14, t0, 28, 46, 0, ease=SOFT_BACK)
        m_out.k(r.id, 18, kf(1, 0, "hold"), kf(1, i, "linear"), kf(0, i + 8, "hold"))
        m_out.k(r.id, 14, kf(0, 0, "hold"), kf(0, i, "cubic", ease=EASE_IN), kf(26, i + 10, "hold"))
        hold(m_closed, r.id, 18, 0)
        hold(m_closed, r.id, 14, 46)
        kids = lcs(r)
        name = r.attrs.get("name", "")
        if name == "Cells":
            for j, c in enumerate(kids):
                tc = t0 + 4 + j
                m_in.k(c.id, 18, kf(0, 0, "hold"), kf(0, tc, "linear"), kf(1, tc + 6, "hold"))
                slide(m_in, c.id, 14, tc, 16, -10, 0, ease=SOFT_BACK)
                hold(m_closed, c.id, 18, 0)
            continue
        bars = find(r, lambda e: e.tag == "LayoutComponent" and e.attrs.get("name", "").endswith(" Bar")
                    and e.attrs.get("name", "").startswith("Wk "), [])
        for j, bb in enumerate(bars):
            hgt = float(bb.attrs.get("height", "0"))
            tb = t0 + 6 + int(j * 2.5)
            m_in.k(bb.id, 8, kf(0, 0, "hold"), kf(0, tb, "cubic", ease=SOFT_BACK), kf(hgt, tb + 26, "hold"))
            hold(m_closed, bb.id, 8, 0)
        if len(kids) > 1:
            for j, c in enumerate(kids):
                tc = t0 + 3 + j * 3
                slide(m_in, c.id, 14, tc, 24, 22, 0, ease=EASE_OUT)
                hold(m_closed, c.id, 14, 22)
    for f in cx.arrive:
        f(m_in, m_out, m_closed)
    a_in, a_out, a_closed = m_in.build(), m_out.build(), m_closed.build()
    ab.add(a_closed, a_in, a_out, *cx.anims)
    st_c, st_i, st_o = nid(), nid(), nid()
    open_layer = E("StateMachineLayer", E("AnyState", x=0, y=-160), E("ExitState", x=600, y=-160),
                   E("EntryState", E("StateTransition", stateToId=st_c), x=0, y=0),
                   E("AnimationState", E("StateTransition", cond_num("section", "equal", k), stateToId=st_i), animationId=a_closed.id, id=st_c, x=200, y=0),
                   E("AnimationState", E("StateTransition", cond_num("section", "notEqual", k), stateToId=st_o), animationId=a_in.id, id=st_i, x=400, y=0),
                   E("AnimationState", E("StateTransition", cond_num("section", "equal", k), stateToId=st_i), animationId=a_out.id, id=st_o, x=400, y=160),
                   name="Open", id=nid())
    sm = E("StateMachine", open_layer, *cx.layers, *cx.listeners, name="Panel", id=nid())
    ab.attrs["defaultStateMachineId"] = sm.id
    ab.add(sm)
    return ab


# ---------------------------------------------------------------- hero visuals (one per panel)
# Each panel opens with one big vector visual under the header. Arrival keys go into the panel's In motion
# through cx.arrive (callables m_in, m_out, m_closed); idle loops get their own state-machine layer
# (cx.loop). Hero art lives in Nodes inside fixed layout boxes, so its keys never collide with the row
# choreography (which keys y / opacity of the rows and their direct layout children).
ICON["cup"] = [([(-0.6, -0.35), (0.4, -0.35), (0.3, 0.7), (-0.5, 0.7)], True, False),
               (_circ(0.45, 0.08, 0.24, 12, -math.pi * 0.5, math.pi * 0.5), False, False),
               ([(-0.25, -0.85), (-0.15, -0.6)], False, False), ([(0.08, -0.85), (0.18, -0.6)], False, False)]
ICON["park"] = [([(-0.75, -0.75), (0.75, -0.75), (0.75, 0.75), (-0.75, 0.75)], True, False),
                ([(-0.22, 0.48), (-0.22, -0.45), (0.1, -0.45)] + _circ(0.1, -0.2, 0.25, 10, -math.pi * 0.5, math.pi * 0.5) + [(-0.22, 0.05)], False, False)]
ICON["clock"] = [(_circ(0, 0, 0.82), True, False), ([(0, -0.5), (0, 0), (0.38, 0.2)], False, False)]
ICON["north"] = [([(0, -0.85), (0.42, 0.6), (0, 0.32), (-0.42, 0.6)], True, True)]
ICON["fork"] = [([(-0.35, -0.85), (-0.35, 0.85)], False, False), ([(-0.6, -0.85), (-0.6, -0.3), (-0.1, -0.3), (-0.1, -0.85)], False, False),
                ([(0.4, 0.85), (0.4, -0.85), (0.65, -0.5), (0.65, 0.0), (0.4, 0.0)], False, False)]


def icon_art(name, kind, size, col=TXT, th=1.7, x=0, y=0, nid_=None):
    """An ICON drawn straight into a Node (for absolute-positioned hero art, no layout box)."""
    s = size / 2 * 0.86
    shapes = []
    for i, (pts, closed, filled) in enumerate(ICON[kind]):
        P = [(round(px * s, 2), round(py * s, 2)) for px, py in pts]
        kids = [poly(P, closed=closed)]
        if filled:
            kids.append(solid(argb(col)))
        kids.append(stroke(argb(col), th))
        shapes.append(shape(f"{name} {i}", *kids))
    return node(name, *shapes, x=x, y=y, nid_=nid_)


def trim(tid, end=1.0, start=0.0, mode=None):
    return E("TrimPath", start=start, end=end, offset=0.0, modeValue=mode, id=tid, name="Trim")


def line_shape(name, paths, col, th, trim_id=None, fill=None, sid=None, opacity=None, mode=None, cap_="round"):
    """Outline art: one Shape holding one or more point lists (each (pts, closed)); optional fill under the
    stroke and an optional TrimPath (synchronized mode draws every contour at the same fraction)."""
    kids = [poly(p, closed=c) for p, c in paths]
    if fill is not None:
        kids.append(solid(fill))
    kids.append(stroke(col, th, cap=cap_, trim=trim(trim_id, mode=mode) if trim_id else None))
    return shape(name, *kids, sid=sid, opacity=opacity)


def rrect_pts(cx_, cy_, w, h, r, n=6):
    """Rounded rectangle as points (clockwise from the top-left corner's end)."""
    pts = []
    for (ccx, ccy, a0) in ((cx_ + w / 2 - r, cy_ - h / 2 + r, -math.pi / 2), (cx_ + w / 2 - r, cy_ + h / 2 - r, 0.0),
                           (cx_ - w / 2 + r, cy_ + h / 2 - r, math.pi / 2), (cx_ - w / 2 + r, cy_ - h / 2 + r, math.pi)):
        for k in range(n + 1):
            a = a0 + math.pi / 2 * k / n
            pts.append((ccx + r * math.cos(a), ccy + r * math.sin(a)))
    return pts


def bez(p0, p1, p2, p3, n=28):
    out = []
    for k in range(n + 1):
        u = k / n
        a, b, c, d = (1 - u) ** 3, 3 * u * (1 - u) ** 2, 3 * u * u * (1 - u), u ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def pulse_keys(P, phase=0.0, L=0.3, travel=0.72, step=3):
    """Trim start/end keyframes for a bright segment that runs once along a path per loop of P frames:
    it grows out of the path start, travels, and drains into the end; it is invisible for the rest of
    the loop (start == end), so the wrap is seamless."""
    st, en = [], []
    frames = list(range(0, P, step)) + [P]
    for f in frames:
        u = ((f / P) + phase) % 1.0
        if u < travel:
            v = u / travel * (1 + L)
            head, tail = min(1.0, v), max(0.0, min(1.0, v - L))
        else:
            head = tail = 1.0
        st.append(kf(round(tail, 4), f, "linear"))
        en.append(kf(round(head, 4), f, "linear"))
    return st, en


def car_half(a, b, p, side, n=48):
    """One side of the plan-view body (nose -> tail): superellipse, nose a little narrower than the tail."""
    pts = []
    for k in range(n + 1):
        th_ = math.pi * k / n * side
        c, s = math.cos(th_), math.sin(th_)
        x = a * math.copysign(abs(c) ** (2 / p), c)
        y = b * math.copysign(abs(s) ** (2 / p), s)
        f = x / a
        y *= 1 - (0.11 * f ** 4 if f > 0 else 0.05 * f ** 4)
        pts.append((x, y))
    return pts


def hero_gauge(cx):
    """Status: 270-degree charge ring. The progress arc, the lit ticks and the head dot sweep in from 0 to 80%
    on arrival; an energy pulse then flows along the charged arc into the head on a 2.5 s loop."""
    R, A0, SPAN, FR = 108, 135.0, 270.0, 0.8
    a_end = A0 + SPAN * FR
    arc = lambda a0, a1, n=72: _circ(0, 0, R, n, math.radians(a0), math.radians(a1))
    tr_prog, tr_flow, tr_glow, tr_tick = nid(), nid(), nid(), nid()
    head_id, flow_id, ctr_id, bolt_id = nid(), nid(), nid(), nid()
    ticks, majors = [], []
    NT = 54
    for i in range(NT + 1):
        a = math.radians(A0 + SPAN * i / NT)
        major = i % 9 == 0
        r0, r1 = (R + 13, R + 23) if major else (R + 15, R + 20)
        seg = ([(r0 * math.cos(a), r0 * math.sin(a)), (r1 * math.cos(a), r1 * math.sin(a))], False)
        (majors if major else ticks).append(seg)
    # lit ticks: only those inside the charged span, ordered by angle so a sequential trim lights them in turn
    lit = []
    for i in range(NT + 1):
        if i / NT <= FR + 1e-6:
            a = math.radians(A0 + SPAN * i / NT)
            major = i % 9 == 0
            r0, r1 = (R + 13, R + 23) if major else (R + 15, R + 20)
            lit.append(([(r0 * math.cos(a), r0 * math.sin(a)), (r1 * math.cos(a), r1 * math.sin(a))], False))
    head = node("Gauge Head",
                node("Gauge Head Dot", shape("Gauge Head Core", ellipse(9, 9), solid(argb(WHITE))),
                     shape("Gauge Head Halo", ellipse(22, 22), solid(argb(ACC, 0x40))), x=R),
                rot=a_end, nid_=head_id)
    flow = node("Gauge Flow",
                shape("Gauge Flow Core", poly(arc(A0, a_end), closed=False),
                      stroke(argb("#FFE7C2"), 3.2, trim=trim(tr_flow))),
                shape("Gauge Flow Glow", poly(arc(A0, a_end), closed=False),
                      stroke(argb(ACC, 0x55), 12, trim=trim(tr_glow))), nid_=flow_id)
    art = node("Gauge Art", head, flow,
               line_shape("Gauge Ticks Lit", lit, argb(ACC, 0xD0), 1.6, trim_id=tr_tick, cap_="butt"),
               line_shape("Gauge Progress", [(arc(A0, a_end), False)], argb(ACC), 7, trim_id=tr_prog),
               line_shape("Gauge Track", [(arc(A0, A0 + SPAN, 90), False)], argb("#FFFFFF", 0x1C), 7),
               line_shape("Gauge Majors", majors, argb("#FFFFFF", 0x60), 1.6, cap_="butt"),
               line_shape("Gauge Ticks", ticks, argb("#FFFFFF", 0x2C), 1.2, cap_="butt"),
               icon_art("Gauge Bolt", "bolt", 18, ACC, 1.2, y=R * 0.74, nid_=bolt_id),
               x=140, y=134)
    centre = box("Gauge Centre", cap("Gauge L", "Charge", size=11.5),
                 bignum("Gauge Num", "80", 88, bindname="charge", unit="%", usize=30),
                 t("Gauge Sub", "Ready to drive", 13.5, MUT), align="topCenter", gap=0, bid=ctr_id,
                 extra=dict(marginTop=4))
    ring = box("Gauge Ring", box("Gauge Centre Wrap", centre, w=280, h=262, ws="fixed", hs="fixed", align="center"),
               box("Gauge Art Box", art, w=280, h=262, ws="fixed", hs="fixed"), w=280, h=262, ws="fixed", hs="fixed", stack=True)
    side_l = box("Gauge Range", cap("Gauge Range L", "Range"), bignum("Gauge Range V", "412", 34, bindname="range", unit="km", usize=14,
                                                                     weight=W_LIGHT),
                 t("Gauge Range S", "Personal mode", 12.5, MUT), gap=4, w=118, ws="fixed")
    side_r = box("Gauge Full", cap("Gauge Full L", "Full by"), bignum("Gauge Full V", "06:40", 34, weight=W_LIGHT),
                 t("Gauge Full S", "11 kW · off-peak", 12.5, MUT), gap=4, w=118, ws="fixed", align="topRight")
    row = box("Gauge", side_l, spacer("Gauge Sp1"), ring, spacer("Gauge Sp2"), side_r, ws="fill", dir="row", align="center")

    SW0, SW1 = 16, 78
    sweep = (0.42, 0.0, 0.18, 1.0)

    def arrive(m_in, m_out, m_closed):
        for tid in (tr_prog, tr_tick):
            m_in.k(tid, 115, kf(0, 0, "hold"), kf(0, SW0, "cubic", ease=sweep), kf(1, SW1, "hold"))
            hold(m_closed, tid, 115, 0)
        m_in.k(head_id, 15, kf(math.radians(A0), 0, "hold"), kf(math.radians(A0), SW0, "cubic", ease=sweep), kf(math.radians(a_end), SW1, "hold"))
        m_in.k(head_id, 18, kf(0, 0, "hold"), kf(0, SW0, "linear"), kf(1, SW0 + 6, "hold"))
        hold(m_closed, head_id, 18, 0)
        m_in.k(flow_id, 18, kf(0, 0, "hold"), kf(0, SW1 - 4, "linear"), kf(1, SW1 + 14, "hold"))
        hold(m_closed, flow_id, 18, 0)
        m_in.k(ctr_id, 18, kf(0, 0, "hold"), kf(0, 26, "linear"), kf(1, 44, "hold"))
        hold(m_closed, ctr_id, 18, 0)
        pop(m_in, bolt_id, 64, 18, s0=0.3, over=BACK)
    cx.arrive.append(arrive)
    m = Motion("Gauge Flow Loop", 150, loop="loop")
    for tid in (tr_flow, tr_glow):   # fresh keyframe elements per object (E nodes must not be shared)
        st, en = pulse_keys(150, 0.0, L=0.28, travel=0.7)
        m.k(tid, 114, *st)
        m.k(tid, 115, *en)
    cx.loop(m)
    return row


def chip_art(name, w, h, kids, x=0, y=0, fill=None, border=BORDER, nid_=None, r=5):
    bg = shape(name + " Bg", rect(w, h, r), solid(fill or argb("#0B0E11", 0xC8)), stroke(border, 1.0))
    return node(name, *kids, bg, x=x, y=y, nid_=nid_)


def hero_car(cx):
    """Vehicle: plan-view line drawing (nose to the right, so the car's left side is up) with live state on it:
    tyre pressures at each wheel, lock on the cabin, charge port on the left rear quarter. The body outline
    draws on from the nose, glass follows, wheels and readouts pop in; the charge port breathes on a loop."""
    W_, H_ = 540, 270
    CX, CY = W_ / 2, H_ / 2
    a, b = 166, 64
    tr_body, tr_glass, tr_hood = nid(), nid(), nid()
    body = line_shape("Car Body", [(car_half(a, b, 4.0, -1), False), (car_half(a, b, 4.0, 1), False)], argb(TXT, 0xE6), 1.6,
                      trim_id=tr_body, mode=2)
    # greenhouse, windscreen, rear glass, roof line
    gh = rrect_pts(-14, 0, 196, 104, 24)
    ws_pts = [(72 + 9 * (1 - (yy / 50) ** 2), yy) for yy in [-50 + 100 * k / 16 for k in range(17)]] + \
             [(28 + 5 * (1 - (yy / 44) ** 2), yy) for yy in [44 - 88 * k / 16 for k in range(17)]]
    rg_pts = [(-80 - 4 * (1 - (yy / 44) ** 2), yy) for yy in [-44 + 88 * k / 16 for k in range(17)]] + \
             [(-108 - 3 * (1 - (yy / 38) ** 2), yy) for yy in [38 - 76 * k / 16 for k in range(17)]]
    glass = line_shape("Car Glass", [(ws_pts, True), (rg_pts, True)], argb(MUT, 0xD0), 1.4, trim_id=tr_glass, mode=2,
                       fill=argb("#FFFFFF", 0x12))
    cabin = line_shape("Car Cabin", [(gh, True)], argb(MUT, 0x90), 1.3, trim_id=tr_hood, mode=2)
    hood = line_shape("Car Lines", [([(86, -30), (150, -21)], False), ([(86, 30), (150, 21)], False),
                                    ([(-118, -34), (-152, -28)], False), ([(-118, 34), (-152, 28)], False)],
                      argb(MUT, 0x70), 1.2)
    mirrors = line_shape("Car Mirrors", [([(52, -62), (46, -75), (36, -77), (33, -63)], True),
                                         ([(52, 62), (46, 75), (36, 77), (33, 63)], True)], argb(TXT, 0xC0), 1.3,
                         fill=argb("#1A1E22"))
    wheels, chips, leaders = [], [], []
    wheel_ids, chip_ids = [], []
    tyres = (("FL", 104, -1, "2.6"), ("FR", 104, 1, "2.6"), ("RL", -106, -1, "2.5"), ("RR", -106, 1, "2.6"))
    for nm, wx, side, val in tyres:
        wid, cid_ = nid(), nid()
        wheels.append(node(f"Wheel {nm}", shape(f"Wheel {nm} S", rect(50, 16, 5), solid(argb("#1A1E22")),
                                                stroke(argb(TXT, 0xB0), 1.4)), x=wx, y=side * 59, nid_=wid))
        low = val == "2.5"
        kids = [ttext(f"Tyre {nm} V", val, 19, ACC if low else TXT, W_LIGHT, x=-9, y=0),
                ttext(f"Tyre {nm} U", "bar", 11, MUT, W_MED, x=19, y=1.5)]
        chips.append(chip_art(f"Tyre {nm}", 74, 34, kids, x=-wx, y=-side * 106, nid_=cid_,
                              border=argb(ACC, 0x90) if low else BORDER))
        leaders.append(([(wx, side * 89), (wx, side * 70)], False))
        wheel_ids.append(wid)
        chip_ids.append(cid_)
    lead = line_shape("Car Leaders", leaders, argb("#FFFFFF", 0x40), 1.0, cap_="butt")
    lock_id, port_id, ring_id, pchip_id, plead_id = nid(), nid(), nid(), nid(), nid()
    lock = node("Car Lock", icon_art("Car Lock I", "lock", 16, TXT, 1.6, y=-1),
                shape("Car Lock Bg", ellipse(36, 36), solid(argb("#0B0E11", 0xD8)), stroke(BORDER, 1.0)),
                ttext("Car Lock T", "LOCKED", 9.5, MUT, W_MED, ls=1.4, y=30), x=16, y=0, nid_=lock_id)
    PX = -152.0   # charge flap on the left rear quarter (world.as pin: car's left, behind the rear axle)
    PY = -b * (1 - (abs(PX) / a) ** 4) ** 0.25 * (1 - 0.05 * (PX / a) ** 4) + 1
    port = node("Car Port", node("Car Port Ring", shape("Car Port Ring S", ellipse(22, 22), stroke(argb(ACC, 0xC0), 1.4)), nid_=ring_id),
                shape("Car Port Flap", rect(13, 7, 2), solid(argb(ACC))), x=PX, y=PY, nid_=port_id)
    pchip = node("Car Port Chip", icon_art("Car Port Chip I", "plug", 16, INKD, 1.7),
                 shape("Car Port Chip Bg", ellipse(34, 34), solid(argb(ACC))), x=222, y=106, nid_=pchip_id)
    plead = line_shape("Car Port Lead", [([(-206, -98), (PX - 8, PY - 6)], False)], argb(ACC, 0x90), 1.0, sid=plead_id)
    # The drawing is turned 180 deg (nose LEFT, the car's left side at the BOTTOM) so it reads like the 3D car
    # seen from its left side in the Vehicle shot, and the callout lines fan out without crossing. Text chips sit
    # outside the turned group (upright) at the mirrored positions.
    drawing = node("Car Drawing", port, plead, lead, mirrors, glass, cabin, hood, body, *wheels, rot=180)
    art = node("Car Art", *chips, pchip, lock, drawing, x=CX, y=CY)
    status = box("Car Status", gicon("Car St I", "tyre", 15, MUT, 1.5), t("Car St T", "All tyres OK", 13, MUT),
                 box("Car St Dot", w=3, h=3, ws="fixed", hs="fixed", fill=argb(MUT, 0x90), radius=1.5),
                 gicon("Car St I2", "lock", 14, MUT, 1.5), t("Car St T2", "Locked", 13, MUT),
                 box("Car St Dot2", w=3, h=3, ws="fixed", hs="fixed", fill=argb(MUT, 0x90), radius=1.5),
                 gicon("Car St I3", "plug", 15, MUT, 1.5), t("Car St T3", "Port closed", 13, MUT),
                 dir="row", align="center", gap=7)
    row = box("Car", box("Car Art Box", art, w=W_, h=H_, ws="fixed", hs="fixed"), status, ws="fill", align="topCenter", gap=4)

    def arrive(m_in, m_out, m_closed):
        m_in.k(tr_body, 115, kf(0, 0, "hold"), kf(0, 12, "cubic", ease=(0.5, 0.0, 0.2, 1.0)), kf(1, 66, "hold"))
        m_in.k(tr_hood, 115, kf(0, 0, "hold"), kf(0, 30, "cubic", ease=EASE_OUT), kf(1, 72, "hold"))
        m_in.k(tr_glass, 115, kf(0, 0, "hold"), kf(0, 36, "cubic", ease=EASE_OUT), kf(1, 78, "hold"))
        for tid in (tr_body, tr_hood, tr_glass):
            hold(m_closed, tid, 115, 0)
        for j, wid in enumerate(wheel_ids):
            pop(m_in, wid, 40 + j * 4, 18, s0=0.2, over=BACK)
        for j, cid_ in enumerate(chip_ids):
            t0 = 56 + j * 4
            m_in.k(cid_, 18, kf(0, 0, "hold"), kf(0, t0, "linear"), kf(1, t0 + 8, "hold"))
            base_y = (106, -106, 106, -106)[j]
            slide(m_in, cid_, 14, t0, 22, base_y + (-12 if base_y < 0 else 12), base_y, ease=SOFT_BACK)
            hold(m_closed, cid_, 18, 0)
        m_in.k(lead.id, 18, kf(0, 0, "hold"), kf(0, 60, "linear"), kf(1, 76, "hold"))
        hold(m_closed, lead.id, 18, 0)
        pop(m_in, lock_id, 66, 20, s0=0.3, over=BACK)
        pop(m_in, port_id, 72, 18, s0=0.0, over=BACK)
        pop(m_in, pchip_id, 78, 18, s0=0.3, over=BACK)
        m_in.k(plead_id, 18, kf(0, 0, "hold"), kf(0, 76, "linear"), kf(1, 88, "hold"))
        hold(m_closed, plead_id, 18, 0)
    cx.arrive.append(arrive)
    m = Motion("Port Pulse", 120, loop="loop")
    for key in (16, 17):
        m.k(ring_id, key, kf(0.7, 0, "cubic", ease=EASE_OUT), kf(1.7, 80, "hold"), kf(0.7, 120, "hold"))
    m.k(ring_id, 18, kf(1.0, 0, "cubic", ease=(0.4, 0.0, 0.6, 1.0)), kf(0.0, 80, "hold"), kf(1.0, 120, "hold"))
    cx.loop(m)
    return row


MAP_W, MAP_H = 540, 240


def hero_map(cx):
    """Navigate: idle city map (no route, no car) in a clipped card, with a location chip, compass and zoom."""
    sc = MAP_W / 1024
    img_h = 576 * sc
    in_id, drift_id, ov_id = nid(), nid(), nid()
    img = E("Image", assetId=MAP_ID, name="Map Img", id=nid(), scaleX=sc, scaleY=sc)
    art = node("Map Center", node("Map Drift", img, nid_=drift_id), x=MAP_W / 2, y=MAP_H - img_h / 2 + 14, nid_=in_id)
    dim = box("Map Dim", ws="fill", hs="fill", fill=argb("#0B0E11", 0x40))
    # top edge shade so the glass chip and buttons sit on a calmer field
    shade = box("Map Shade", node("Map Shade N", shape("Map Shade S", rect(MAP_W, 90, 0, ox=0, oy=0),
                                                       E("Fill", E("LinearGradient", E("GradientStop", colorValue=argb("#0B0E11", 0x70), position=0),
                                                                   E("GradientStop", colorValue=argb("#0B0E11", 0), position=1),
                                                                   startX=0, startY=0, endX=0, endY=90, name="G"), name="Fill"))),
                w=MAP_W, h=MAP_H, ws="fixed", hs="fixed")
    loc = gcard("Map Loc", gicon("Map Loc I", "pin", 15, ACC, 1.6), t("Map Loc T", "Munich · Maxvorstadt", 13.5, TXT, W_MED),
                fill=argb("#0B0E11", 0xB8), radius=5, pad=(7, 12, 7, 9), gap=6, dir="row", align="center", ws="hug", border=True)
    scale_bar = box("Map Scale", box("Map Scale Bar", w=44, h=2, ws="fixed", hs="fixed", fill=argb("#2A2F35")),
                    t("Map Scale T", "200 m", 11.5, "#2A2F35", W_SEMI), dir="row", align="center", gap=6)
    btn = lambda n, k: gcard(n, gicon(n + " I", k, 16, TXT, 1.7), fill=argb("#0B0E11", 0xB8), radius=5, pad=0, align="center",
                             ws="fixed", hs="fixed", w=38, h=38, border=True)
    zoom = gcard("Map Zoom", gcard("Map Zoom In", gicon("Map Zoom In I", "plus", 15, TXT, 1.7), fill=argb("#000000", 0), radius=0, pad=0,
                                   align="center", ws="fixed", hs="fixed", w=38, h=38),
                 box("Map Zoom Rule", w=22, h=1, ws="fixed", hs="fixed", fill=HAIR),
                 gcard("Map Zoom Out", gicon("Map Zoom Out I", "minus", 15, TXT, 1.7), fill=argb("#000000", 0), radius=0, pad=0,
                       align="center", ws="fixed", hs="fixed", w=38, h=38),
                 fill=argb("#0B0E11", 0xB8), radius=5, pad=0, gap=0, align="topCenter", ws="hug", border=True)
    left = box("Map Left", loc, box("Map Left Fill", ws="hug", hs="fill", grow=1), scale_bar,
               hs="fill", align="topLeft")
    right = box("Map Right", btn("Map North", "north"), zoom, hs="fill", align="topRight", gap=8)
    overlay = box("Map Overlay", left, spacer("Map Ov Sp"), right, ws="fill", hs="fill", dir="row", pad=12, bid=ov_id)
    border = box("Map Border", ws="fill", hs="fill", radius=6, stroke=(BORDER, 1.0))
    card = box("Map Card", border, overlay, shade, dim, box("Map Img Box", art, w=MAP_W, h=MAP_H, ws="fixed", hs="fixed"),
               w=MAP_W, h=MAP_H, ws="fixed", hs="fixed", radius=6, clip=True, stack=True, fill=argb("#D6D8DA"))
    row = box("Map", card, ws="fill")

    def arrive(m_in, m_out, m_closed):
        for key in (16, 17):
            m_in.k(in_id, key, kf(1.12, 0, "hold"), kf(1.12, 8, "cubic", ease=EASE_OUT), kf(1.0, 86, "hold"))
        m_in.k(in_id, 18, kf(0, 0, "hold"), kf(0, 8, "linear"), kf(1, 30, "hold"))
        hold(m_closed, in_id, 18, 0)
        m_in.k(ov_id, 18, kf(0, 0, "hold"), kf(0, 34, "linear"), kf(1, 52, "hold"))
        hold(m_closed, ov_id, 18, 0)
    cx.arrive.append(arrive)
    m = Motion("Map Drift", 1440, loop="loop")   # 24 s: a barely-there breathing zoom so the map feels live
    for key in (16, 17):
        m.k(drift_id, key, kf(1.0, 0, "cubic", ease=EASE_IO), kf(1.045, 720, "cubic", ease=EASE_IO), kf(1.0, 1440, "hold"))
    cx.loop(m)
    return row


def hero_cover(cx):
    """Media: large cover flanked by a hairline spectrum (echoes the LED wall's visualizer). The bars rise
    from the centre outward on arrival and dance only while playing; paused, they settle low."""
    CS, H_ = 216, 216
    NB, PITCH, BW = 22, 6.6, 2.2
    P, BEAT = 240, 30
    wraps, inner = [], []
    m = Motion("Viz Bars", P, loop="loop")
    rest = Motion("Viz Rest", 20)
    TAU = 2 * math.pi
    for side in (-1, 1):
        for i in range(NB):
            x = side * (CS / 2 + 18 + i * PITCH)
            wid, bid = nid(), nid()
            d = i / (NB - 1)
            amp = 0.95 - 0.55 * d
            alpha = int(0xC8 - 0x70 * d)
            inner_n = node(f"VB {side} {i}", shape(f"VB {side} {i} S", rect(BW, H_ * 0.62, BW / 2), solid(argb(TXT, alpha))),
                           sy=0.12, nid_=bid)
            wraps.append(node(f"VB {side} {i} W", inner_n, x=x, nid_=wid))
            inner.append((wid, bid, i))
            fr = []
            for f in range(0, P + 1, 6):
                ph = i * 0.21 + (0 if side < 0 else 0.9)
                pump = math.exp(-(f % BEAT) / BEAT * 3.2)
                jit = 0.5 + 0.5 * math.sin(i * 2.39 + side * 1.3 + f * TAU * 5 / P)   # per-bar detail on the smooth envelope
                v = 0.08 + amp * (0.5 + 0.5 * math.sin(ph + f * TAU * 3 / P)) * (0.55 + 0.45 * math.sin(i * 0.07 - f * TAU * 2 / P)) \
                    * (0.45 + 0.55 * jit) + 0.22 * (1 - d) * pump
                fr.append(kf(round(max(0.06, min(v, 1.0)), 3), f, "cubic", ease=EASE_IO))
            fr[-1] = kf(float(fr[0].attrs["value"]), P, "cubic", ease=EASE_IO)
            m.k(bid, 17, *fr)
            rest.k(bid, 17, kf(0.08, 0, "hold"))
    cover = cover_art("Cover", CS)
    cover_wrap = box("Cover Wrap", cover, ws="fill", hs="fill", align="center")
    bars = box("Viz Box", node("Viz Art", *wraps, x=270, y=H_ / 2), w=540, h=H_, ws="fixed", hs="fixed")
    row = box("Cover Hero", cover_wrap, bars, w=540, h=H_, ws="fixed", hs="fixed", stack=True)

    def arrive(m_in, m_out, m_closed):
        for wid, bid, i in inner:
            t0 = 22 + i * 2
            m_in.k(wid, 17, kf(0, 0, "hold"), kf(0, t0, "cubic", ease=SOFT_BACK), kf(1, t0 + 22, "hold"))
            hold(m_closed, wid, 17, 0)
    cx.arrive.append(arrive)
    a_loop, a_rest = m.build(), rest.build()
    cx.anims += [a_loop, a_rest]
    s_r, s_p = nid(), nid()
    cx.layers.append(E("StateMachineLayer", E("AnyState", x=0, y=-120), E("ExitState", x=500, y=-120),
                       E("EntryState", E("StateTransition", stateToId=s_r), x=0, y=0),
                       E("AnimationState", E("StateTransition", cond_num("playing", "greaterThan", 0.5), stateToId=s_p, duration=400),
                         animationId=a_rest.id, id=s_r, x=200, y=0),
                       E("AnimationState", E("StateTransition", cond_num("playing", "lessThan", 0.5), stateToId=s_r, duration=500),
                         animationId=a_loop.id, id=s_p, x=200, y=140),
                       name="Viz Bars", id=nid()))
    return row


def hero_cabin(cx):
    """Climate: plan view of the front cabin (dash, vents, wheel, seats, console) with air streaming from the
    vents to both seats (pulses travelling along curves) and heat lines on the heated driver seat."""
    S = 250
    tr_out, tr_seat = nid(), nid()
    dash = _circ(0, 330, 430, 40, math.radians(256), math.radians(284))   # gentle arc across the top
    cab = [([(-112, -84), (-116, 20), (-114, 118)], False), ([(112, -84), (116, 20), (114, 118)], False), (dash, False)]
    outline = line_shape("Cab Outline", cab, argb(MUT, 0xA0), 1.4, trim_id=tr_out, mode=2)
    seats = []
    for sx in (-52, 52):
        seats += [(rrect_pts(sx, 14, 60, 58, 13), True), (rrect_pts(sx, 56, 64, 20, 8), True), (rrect_pts(sx, 76, 34, 11, 5), True)]
    seats += [(rrect_pts(0, 30, 20, 96, 7), True)]
    seat_shape = line_shape("Cab Seats", seats, argb(TXT, 0xD8), 1.5, trim_id=tr_seat, mode=2, fill=argb("#16191C"))
    wheel = line_shape("Cab Wheel", [(rrect_pts(-52, -50, 62, 10, 5), True)], argb(TXT, 0xB0), 1.4)
    vents_x = (-80, -27, 27, 80)
    vy = lambda x: 330 - math.sqrt(430 ** 2 - x ** 2) + 9
    vents = line_shape("Cab Vents", [([(x - 11, vy(x)), (x + 11, vy(x))], False) for x in vents_x], argb(TXT, 0xC0), 3.0)
    # air: each vent fans three soft streams that converge on its seat and tuck under the cushion
    tracks, pulses, pulse_ids = [], [], []
    for j, vx in enumerate(vents_x):
        tx = -52 if vx < 0 else 52
        for k, off in enumerate((-8, 0, 8)):
            p0 = (vx + off * 0.5, vy(vx) + 5)
            outward = 1 if vx > 0 else -1
            p3 = (tx + (14 if abs(vx) > 50 else -14) * outward + off * 0.9, 0)   # outer vent -> outer half of the seat
            pts = bez(p0, (vx + off * 0.9, p0[1] + 38), (p3[0] + (vx - tx) * 0.25, p3[1] - 36), p3)
            tracks.append((pts, False))
            tid = nid()
            pulses.append(shape(f"Air {j}{k}", poly(pts, closed=False), stroke(argb(TXT, 0xB0), 1.6, trim=trim(tid, end=0.0))))
            pulse_ids.append((tid, j * 3 + k))
    track = line_shape("Air Tracks", tracks, argb("#FFFFFF", 0x1E), 1.1)
    heat_id = nid()
    heat = node("Cab Heat", *[line_shape(f"Heat {i}", [([(-66 + i * 14 + 2.5 * math.sin(k / 6 * math.pi * 2), 2 + k * 4.2) for k in range(7)], False)],
                                         argb(ACC), 1.5) for i in range(3)], x=0, y=-2, nid_=heat_id)
    air_id = nid()
    air = node("Air", *pulses, track, nid_=air_id)
    art = node("Cab Art", heat, seat_shape, wheel, air, vents, outline, x=S / 2, y=S / 2 - 6)
    box_ = box("Cab Box", art, w=S, h=S, ws="fixed", hs="fixed")

    def arrive(m_in, m_out, m_closed):
        m_in.k(tr_out, 115, kf(0, 0, "hold"), kf(0, 12, "cubic", ease=EASE_OUT), kf(1, 56, "hold"))
        m_in.k(tr_seat, 115, kf(0, 0, "hold"), kf(0, 22, "cubic", ease=EASE_OUT), kf(1, 70, "hold"))
        for tid in (tr_out, tr_seat):
            hold(m_closed, tid, 115, 0)
        m_in.k(air_id, 18, kf(0, 0, "hold"), kf(0, 50, "linear"), kf(1, 80, "hold"))
        hold(m_closed, air_id, 18, 0)
        m_in.k(heat_id, 18, kf(0, 0, "hold"), kf(0, 62, "linear"), kf(1, 80, "hold"))
        hold(m_closed, heat_id, 18, 0)
        m_in.k(vents.id, 18, kf(0, 0, "hold"), kf(0, 36, "linear"), kf(1, 50, "hold"))
        m_in.k(wheel.id, 18, kf(0, 0, "hold"), kf(0, 40, "linear"), kf(1, 56, "hold"))
        hold(m_closed, vents.id, 18, 0)
        hold(m_closed, wheel.id, 18, 0)
    cx.arrive.append(arrive)
    m = Motion("Airflow", 180, loop="loop")
    for tid, j in pulse_ids:
        st, en = pulse_keys(180, phase=(j * 0.29 + (j % 3) * 0.13) % 1.0, L=0.4, travel=0.8)
        m.k(tid, 114, *st)
        m.k(tid, 115, *en)
    cx.loop(m)
    mh = Motion("Seat Heat", 150, loop="loop")
    for i, c in enumerate(heat.children):
        mh.k(c.id, 18, kf(0.35, 0, "cubic", ease=EASE_IO), kf(1.0, 50 + i * 12, "cubic", ease=EASE_IO), kf(0.35, 150, "hold"))
    cx.loop(mh)
    return box_


def status_panel(x):
    cx = Ctx()
    rows = [
        hero_gauge(cx),
        hair("Rule 1"),
        box("Weather",
            box("Weather Col", bignum("Temp", "12°", 64, bindname="tempOut", weight=W_THIN), t("Sky", "Partly cloudy", 15, TXT, W_REG),
                t("Day", "Saturday, 24 October", 13.5, MUT, bindname="day"), gap=2),
            spacer("Weather Sp"),
            box("Weather Right", gicon("Wx Icon", "cloud", 56, TXT, 1.5), t("City", "Munich", 13.5, MUT, bindname="city"), align="topRight", gap=6),
            ws="fill", dir="row", align="topLeft"),
        gcard("Trip", *[box(f"Trip {l}", kv(f"Trip {l} KV", l, v, unit=u, vsize=26), ws="fill", grow=1)
                        for l, v, u in (("Today", "42", "km"), ("Avg speed", "38", "km/h"), ("Efficiency", "19.6", "kWh"))],
              dir="row", pad=(16, 18, 16, 18), gap=8),
        cap("Week L", "This week · km"),
        gcard("Week", box("Week Bars", *[box(f"Wk {d}", box(f"Wk {d} Bar", ws="fill", h=int(16 + v * 1.1), hs="fixed",
                                                            fill=argb(ACC) if d == "Sat" else argb("#FFFFFF", 0x33), radius=4),
                                             t(f"Wk {d} T", d, 12, MUT, W_MED), ws="fill", grow=1, align="bottomCenter", gap=6)
                                         for d, v in (("Sun", 34), ("Mon", 62), ("Tue", 48), ("Wed", 80), ("Thu", 55), ("Fri", 96), ("Sat", 42))],
                          ws="fill", h=140, hs="fixed", dir="row", align="bottomLeft", gap=12),
              pad=(16, 18, 14, 18)),
        cap("Alert L", "Notifications"),
        list_row("Alert 1", "wrench", "Service due", "In 1,900 km or 6 weeks", right="Book"),
        list_row("Alert 2", "leaf", "Cabin pre-conditioning", "Ready for 07:30 departure", right="On"),
        box("Chips", *[gcard(f"Chip {t_}", gicon(f"Chip {t_} I", ic, 16, INKD if hl else TXT, 1.7), t(f"Chip {t_} T", t_, 13.5, INKD if hl else TXT, W_MED),
                             fill=argb(ACC) if hl else GLASS_HI2, radius=5, pad=(7, 14, 7, 11), gap=6, dir="row", align="center", ws="hug")
                       for t_, ic, hl in (("Locked", "lock", False), ("2.6 bar", "tyre", False), ("Ready", "bolt", True))],
            dir="row", gap=8),
    ]
    return panel_glass(0, "Status", "CNCPT R1 · Ready", "home", rows, cx, x)


def vehicle_panel(x):
    cx = Ctx()
    items = [("Headlights", "Adaptive LED · auto high beam", "light", "lights", 20),
             ("Welcome light", "Light carpet on the ground", "glow", "glow", 23),
             ("Boost", "Maximum output for 10 s", "bolt", "boost", 21)]
    lst = []
    for i, (t_, d, ic, prop, req) in enumerate(items):
        if i:
            lst.append(hair(f"Sw Rule {i}"))
        lst.append(box(f"Row {t_}", circle_btn(f"Row {t_} B", ic, 40),
                       box(f"Row {t_} Txt", t(f"Row {t_} T", t_, 17, TXT, W_MED), t(f"Row {t_} D", d, 13.5, MUT), gap=2),
                       spacer(f"Row {t_} Sp"), gswitch(cx, f"Sw {t_}", prop, req),
                       ws="fill", dir="row", align="centerLeft", gap=14, pad=(12, 0, 12, 0)))
    rows = [
        hero_car(cx),
        cap("Mode L", "Drive mode"),
        gseg(cx, "Mode", ["Efficient", "Personal", "Sport"], "driveMode"),
        gcard("Gadgets", *lst, pad=(4, 16, 4, 16), gap=0),
        cap("Gfx L", "Graphics"),
        gseg(cx, "Gfx", ["High", "Balanced", "Fast"], "gfxQ"),
        gcard("Gfx Fx", *sum([([hair(f"Gfx Rule {i}")] if i else []) + [
            box(f"Gfx {t_}", box(f"Gfx {t_} Txt", t(f"Gfx {t_} T", t_, 16, TXT, W_MED), t(f"Gfx {t_} D", d, 13, MUT), gap=2),
                spacer(f"Gfx {t_} Sp"), gswitch(cx, f"Sw Gfx {t_}", prop, req), ws="fill", dir="row", align="centerLeft", gap=14,
                pad=(11, 0, 11, 0))]
            for i, (t_, d, prop, req) in enumerate((("Glass blur", "Frosted glass behind the panels", "gfxBlur", 60),
                                                    ("Reflections", "Car mirrored in the floor", "gfxRefl", 61),
                                                    ("Bloom", "Glow around bright lights", "gfxBloom", 62)))], []),
              pad=(4, 16, 4, 16), gap=0),
        cap("Seat L", "Seats"),
        gcard("Seats", *[box(f"Seat {s_}", circle_btn(f"Seat {s_} B", "seat", 40, fill=argb(ACC) if i == 0 else GLASS_HI2,
                                                       col=INKD if i == 0 else TXT, border=i != 0),
                             t(f"Seat {s_} T", s_, 16, TXT, W_MED), spacer(f"Seat {s_} Sp"),
                             box(f"Seat {s_} Pips", *[box(f"Seat {s_} P{j}", w=22, h=6, ws="fixed", hs="fixed", radius=3,
                                                         fill=argb(ACC) if j < (2 if i == 0 else 0) else argb("#FFFFFF", 0x2A)) for j in range(3)],
                                 dir="row", gap=5),
                             ws="fill", dir="row", align="centerLeft", gap=12)
                         for i, s_ in enumerate(("Driver heating", "Passenger heating"))], pad=(14, 16, 14, 16), gap=12),
        cap("Amb L", "Ambient light"),
        box("Amb", *[gcard(f"Amb {i}", fill=argb(c), radius=4, pad=0, ws="fixed", hs="fixed", w=48, h=34, border=i == 0)
                     for i, c in enumerate((ACC, "#7FD6FF", "#FFB547", "#FF5C8A", "#B48CFF", "#FFFFFF"))], dir="row", gap=10),
        box("Odo", kv("Odo KV", "Odometer", "6,642", unit="km", vsize=28), spacer("Odo Sp"),
            box("Svc Col", cap("Svc L", "Next service"), t("Svc V", "1,900 km", 17, TXT, W_LIGHT), gap=4, align="topRight"),
            ws="fill", dir="row", align="bottomLeft"),
    ]
    return panel_glass(1, "Vehicle", "Drive · Lights · Comfort", "car", rows, cx, x)


def nav_panel(x):
    cx = Ctx()
    dests = [("Home", "Prinzregentenstraße 42", "home", "9 min", "4.2 km"), ("Studio", "Werksviertel 8", "brief", "14 min", "7.9 km"),
             ("Rocket Squadron HQ", "Hangar 66 · Oberschleißheim", "star", "21 min", "18 km"), ("Olympiapark", "Spiridon-Louis-Ring", "pin", "12 min", "6.1 km"),
             ("Lakeside Café", "Starnberger See", "pin", "32 min", "29 km"), ("Charging Hub", "Fast charge · 8 free", "plug", "6 min", "2.4 km"),
             ("Observatory", "Sternwarte · Summit Road", "flag", "26 min", "22 km")]
    drows = [list_row(f"Dest {i}", ic, n, a, right=tm, right_sub=d, accent=(i == 2)) for i, (n, a, ic, tm, d) in enumerate(dests)]
    rows = [
        gcard("Search", gicon("Search I", "search", 20, MUT, 1.7), t("Search T", "Where to?", 16, MUT), dir="row", align="centerLeft",
              radius=6, pad=(0, 18, 0, 18), gap=12, hs="fixed", h=48, border=True),
        box("Nearby", *[gcard(f"Near {n_}", gicon(f"Near {n_} I", ic, 16, TXT, 1.6), t(f"Near {n_} T", n_, 13.5, TXT, W_MED),
                              fill=GLASS_HI2, radius=5, pad=(0, 8, 0, 8), gap=7, dir="row", align="center", ws="fill", grow=1, hs="fixed", h=40)
                        for n_, ic in (("Charging", "plug"), ("Parking", "park"), ("Coffee", "cup"), ("Food", "fork"))],
            ws="fill", dir="row", gap=8),
        box("Fav Head", cap("Fav L", "Favourites"), spacer("Fav Sp"), t("Fav E", "Edit", 14, ACC, W_MED), ws="fill", dir="row", align="centerLeft"),
        box("Dest List", *drows, ws="fill", hs="hug", gap=8),
        hair("Eta Rule"),
        box("Eta", *[box(f"Eta {l}", kv(f"Eta {l} KV", l, v, vsize=24), ws="fill", grow=1)
                     for l, v in (("Traffic", "Light"), ("Chargers", "8 free"), ("Home", "9 min"))], ws="fill", dir="row"),
    ]
    return panel_glass(2, "Navigate", "Route · Favourites · Traffic", "nav", rows, cx, x)


ALBUM_ID = nid()   # assets/album.jpg: generated cover art for the fictitious "Rocket Squadron - Main Theme" (512 px)
MAP_ID = nid()     # assets/map_wall.jpg: idle light-grey aerial city map (1024 x 576, no route / car / text) for the LED wall in Navigate


def album_img(name, size, iid=None):
    """The album cover centred on (0, 0) at `size` px."""
    return E("Image", assetId=ALBUM_ID, name=name, id=iid or nid(), scaleX=size / 512, scaleY=size / 512)


def cover_art(name, size):
    """Album art in a rounded, clipped glass tile (Media panel and dock mini player)."""
    s = size
    return gcard(name, box(name + " Art", node(name + " Center", album_img(name + " Img", s), x=s / 2, y=s / 2), w=s, h=s,
                           ws="fixed", hs="fixed", stack=True),
                 fill=argb("#000000", 0), radius=max(3, s * 0.03), pad=0, gap=0, ws="fixed", hs="fixed", w=s, h=s, clip=True)


def tunes_panel(x):
    cx = Ctx()
    songs = [("Main Theme", "Rocket Squadron", "3:12"), ("Afterburner", "Rocket Squadron", "2:48"), ("Night Shift", "Lumen Drive", "4:05"),
             ("Glass Horizon", "Aurelia", "2:31"), ("Isar at Dusk", "Kollektiv Süd", "3:57"), ("Wide Open", "Halcyon Run", "2:59"),
             ("Quiet Power", "Volta Park", "3:41"), ("Lime Light", "Neon Alps", "3:20")]
    qrows = []
    for i, (ti, a, d) in enumerate(songs):
        qrows.append(gcard(f"Q {i}", t(f"Q {i} N", f"{i + 1:02d}", 15, ACC if i == 0 else FAINT, W_MED),
                           box(f"Q {i} Txt", t(f"Q {i} T", ti, 16, TXT, W_MED), t(f"Q {i} A", a, 13, MUT), gap=2),
                           spacer(f"Q {i} Sp"), t(f"Q {i} D", d, 14, MUT, W_REG),
                           fill=GLASS_HI2 if i == 0 else argb("#FFFFFF", 0x08), dir="row", align="centerLeft", pad=(10, 16, 10, 16), gap=16, radius=5))
    play_id, pause_id, pb = nid(), nid(), nid()
    play_btn = gcard("Play", gicon("Play I", "play", 24, INKD, 2.4, art_id=play_id), gicon("Pause I", "pause", 24, INKD, 3, art_id=pause_id),
                     fill=argb(ACC), radius=32, pad=0, gap=0, align="center", ws="fixed", hs="fixed", w=64, h=64, bid=pb)
    for c in play_btn.children:
        if c.tag == "LayoutComponentStyle":
            c.attrs["layoutTypeValue"] = "stack"
    cx.toggle("Playing", "playing", [(play_id, 18, 1, 0, "d"), (pause_id, 18, 0, 1, "d")])
    cx.click(pb, "req", 40, name="Play Pause")
    rows = [
        hero_cover(cx),
        box("Now", box("Now Txt", t("Song", "Main Theme", 28, TXT, W_LIGHT, bindname="song"),
                       t("Artist", "Rocket Squadron", 16, ACC, W_MED, bindname="artist"), gap=4),
            spacer("Now Sp"),
            gcard("Src", gicon("Src I", "signal", 14, TXT, 1.6), t("Src T", "Lossless", 12.5, TXT, W_MED), dir="row",
                  align="center", radius=5, pad=(5, 12, 5, 10), gap=6, ws="hug", fill=GLASS_HI2),
            ws="fill", dir="row", align="centerLeft", gap=12),
        box("Prog", bar("Bar", 218 / 532, binds=[bind("songPx", 7)]),
            box("Times", t("El", "1:42", 13, MUT, bindname="elapsed"), spacer("Times Sp"), t("Len", "3:12", 13, MUT, bindname="songLen"), ws="fill", dir="row"),
            ws="fill", gap=8),
        box("Controls", circle_btn("Shuffle", "shuffle", 44, border=False, fill=argb("#FFFFFF", 0)), circle_btn("Prev", "prev", 52),
            play_btn, circle_btn("Next", "next", 52), circle_btn("Repeat", "repeat", 44, border=False, fill=argb("#FFFFFF", 0)),
            ws="fill", dir="row", align="center", gap=20),
        box("Queue Head", cap("Q L", "Up next"), spacer("Q Sp"), cap("Q C", "8 songs"), ws="fill", dir="row"),
        box("Queue List", *qrows, ws="fill", hs="hug", gap=6),
    ]
    return panel_glass(3, "Media", "Now playing", "note", rows, cx, x)


def climate_panel(x):
    cx = Ctx()
    zones = []
    for z, (lab, prop, dn, up) in enumerate((("Driver", "tempL", 10, 11), ("Passenger", "tempR", 12, 13))):
        b_dn, b_up = nid(), nid()
        cx.click(b_dn, "req", dn, name=f"{lab} -")
        cx.click(b_up, "req", up, name=f"{lab} +")
        zones.append(box(f"Zone {lab}", cap(f"Zone {lab} L", lab),
                         bignum(f"Zone {lab} T", "21.5", 54, bindname=prop, unit="°", usize=24),
                         box(f"Zone {lab} Btns", circle_btn(f"Zone {lab} Dn", "minus", 44, bid=b_dn), circle_btn(f"Zone {lab} Up", "plus", 44, bid=b_up),
                             dir="row", gap=10),
                         align="topCenter", gap=10, w=134, ws="fixed"))
    bars = []
    for i in range(6):
        bid = nid()
        b = gcard(f"Fan {i}", fill=argb("#FFFFFF", 0x26), radius=4, pad=0, ws="fill", grow=1, hs="fixed", h=14 + i * 8, bid=bid)
        cx.toggle(f"Fan {i}", "fan", [(gfill_id(b), 37, argb("#FFFFFF", 0x26), argb(ACC), "c")], on_op="greaterThan", on_val=i + 0.5, dur=8)
        cx.click(bid, "fan", i + 1, name=f"Fan {i + 1}")
        bars.append(b)
    f_dn, f_up = nid(), nid()
    cx.click(f_dn, "req", 14, name="Fan -")
    cx.click(f_up, "req", 15, name="Fan +")
    fan = gcard("Fan", box("Fan Head", gicon("Fan I", "fan", 18, MUT, 1.6), cap("Fan L", "Fan speed"), dir="row", align="center", gap=8),
                box("Fan Row", circle_btn("Fan Dn", "minus", 40, bid=f_dn), box("Fan Bars", *bars, ws="fill", grow=1, dir="row", align="bottomLeft", gap=8),
                    circle_btn("Fan Up", "plus", 40, bid=f_up), ws="fill", dir="row", align="bottomLeft", gap=14),
                gap=12, pad=(16, 18, 16, 18))
    modes = [("A/C", "snow", "ac", 30), ("Auto", "auto", "auto", 31), ("Recirc", "recirc", "recirc", 32), ("Defrost", "defrost", "defrost", 33),
             ("Seat heat", "seat", "seat", 34), ("Sync", "sync", "sync", 35)]
    grid_rows = []
    for r in range(2):
        cells = []
        for (ti, ic, prop, req) in modes[r * 3:r * 3 + 3]:
            bid, icid, tcid = nid(), nid(), nid()
            c = gcard(f"Mode {ti}", gicon(f"Mode {ti} I", ic, 22, TXT, 1.7), t(f"Mode {ti} T", ti, 13.5, TXT, W_MED, cid=tcid),
                      fill=GLASS_HI, radius=6, pad=(12, 6, 12, 6), gap=6, align="center", ws="fill", grow=1, bid=bid)
            # on: lime-tinted glass with lime label (a solid lime tile would swallow the white icon)
            cx.toggle(f"Mode {ti}", prop, [(gfill_id(c), 37, GLASS_HI, argb(ACC, 0x2E), "c"), (tcid, 37, argb(TXT), argb(ACC), "c")])
            cx.click(bid, "req", req, name=f"Mode {ti}")
            cells.append(c)
        grid_rows.append(box(f"Modes {r}", *cells, ws="fill", dir="row", gap=8))
    rows = [box("Zones", zones[0], spacer("Zones Sp1"), hero_cabin(cx), spacer("Zones Sp2"), zones[1], ws="fill", dir="row", align="center"), fan, box("Modes", *grid_rows, ws="fill", gap=8),
            cap("Air L", "Airflow"), gseg(cx, "Air", ["Face", "Face + feet", "Windscreen"], "airflow"),
            cap("Sched L", "Pre-conditioning"),
            gcard("Sched", *[box(f"Sched {i}", circle_btn(f"Sched {i} B", ic, 40),
                                 box(f"Sched {i} T", t(f"Sched {i} H", h_, 16, TXT, W_MED), t(f"Sched {i} D", d, 13.5, MUT), gap=2),
                                 spacer(f"Sched {i} Sp"), t(f"Sched {i} V", v, 22, TXT, W_LIGHT),
                                 ws="fill", dir="row", align="centerLeft", gap=12)
                             for i, (ic, h_, d, v) in enumerate((("sun", "Weekdays", "Warm cabin to 22°", "07:30"),
                                                                 ("snow", "Saturday", "Cool cabin to 20°", "09:00")))],
                  pad=(14, 16, 14, 16), gap=12)]
    return panel_glass(4, "Climate", "Dual zone · 12° outside", "fan", rows, cx, x)


# ---------------------------------------------------------------- Garage (main): world + HUD
PIN_DEFS = [  # (icon, action prop, value) — world.as writes pin{k}x / pin{k}y / pin{k}a every frame
    ("light", "req", 20),     # headlight: toggles the lights
    ("tyre", "section", 1),   # front wheel: Vehicle
    ("plug", "section", 0),   # charge flap: Status
    ("fan", "section", 4),    # cabin: Climate
]




VISOR_AB_ID = nid()


def build_garage(panels, led):
    W, H = 1280, 720
    anims = []
    cx = Ctx()     # Garage: pins
    cv = Ctx()     # Visor: top bar + dock (drawn by world.as onto a curved visor)
    world = E("ScriptedLayout", *[E("ScriptInputArtboard", artboardId=panels[i].id, name=f"wall{i}") for i in range(len(panels))],
              E("ScriptInputArtboard", artboardId=led.id, name="led"),
              E("ScriptInputArtboard", artboardId=VISOR_AB_ID, name="visor"),
              E("FocusData"), scriptAssetId=SCRIPTS["world"], name="World", id=nid())
    stage = box("Stage", world, ws="fill", hs="fill")

    def keycap(label=None, kind=None):
        inner = t(f"Key {label} T", label, 11.5, TXT, W_MED) if label else gicon(f"Key {kind} I", kind, 10, TXT, 1.6)
        return gcard(f"Key {label or kind}", inner, fill=argb("#FFFFFF", 0x1A), radius=3, pad=(2, 6, 2, 6) if label else (4, 4, 4, 4), gap=0,
                     align="center", ws="hug", border=True)

    def hint(label):
        return t(f"Hint {label}", label, 12, MUT, W_MED, ls=0.4)

    hints = box("Hints", keycap(kind="chevl"), keycap(kind="chev"), hint("Panels"), keycap("1–5"), hint("Jump"), keycap("L"), hint("Lights"),
                keycap("B"), hint("Boost"), keycap("G"), hint("Welcome light"), keycap("N"), hint("Day / night"), keycap("Q"), hint("Quality"), keycap("R"), hint("Replay"), dir="row", align="center", gap=6)
    readout = t("Readout", "Status  ·  Lights on", 12.5, ACC, W_MED, bindname="readout", ls=0.6)
    # keyboard shortcuts: hidden by default (keeps the sky clean); the Shortcuts button or K toggles them
    keys_id, kbtn_id = nid(), nid()
    cv.toggle("Keys", "keys", [(keys_id, 18, 0, 1, "d")])
    cv.click(kbtn_id, "req", 50, name="Shortcuts")
    kbtn = gcard("Shortcuts", gicon("Shortcuts I", "keys", 20, TXT, 1.5), t("Shortcuts T", "Shortcuts", 13, TXT, W_MED),
                 fill=argb("#FFFFFF", 0x14), radius=5, pad=(6, 12, 6, 10), gap=7, dir="row", align="center", ws="hug", bid=kbtn_id, border=True)
    # Responsive: the left group is pinned to the left edge and the right group to the right; the shortcut hints
    # float centred over the bar (a stack layer, so they never push the groups when shown). world.as writes
    # `compact` from the visor's width: 2 drops the status icons so a phone-width bar still fits.
    top_sig = box("Top Sig", gicon("T Sig", "signal", 18, TXT, 1.6), t("5G", "5G", 13, TXT, W_SEMI),
                  gicon("T Bt", "bt", 18, TXT, 1.6), gicon("T Cam", "cam", 20, TXT, 1.6), dir="row", align="center", gap=18)
    # the key list is a desktop affordance: it doesn't fit a narrow bar (the readout stays)
    cv.toggle("Compact Hints", "compact", [(style_id(hints), 596, 0, 1, "u")], on_op="greaterThan", on_val=0.5)
    cv.toggle("Compact Top", "compact", [(style_id(top_sig), 596, 0, 1, "u")], on_op="greaterThan", on_val=1.5)
    top_row = box("Top Row",
                  box("Top L", gicon("T User", "user", 20, TXT, 1.6), gicon("T Mute", "mute", 20, TXT, 1.6),
                      t("Clock", "14:30", 20, TXT, W_MED, bindname="clock"), dir="row", align="centerLeft", gap=22),
                  spacer("Top Sp1"),
                  box("Top R", kbtn, t("OutT", "12°C", 16, TXT, W_MED), top_sig, dir="row", align="centerRight", gap=18),
                  ws="fill", hs="fill", dir="row", align="centerLeft")
    # the hints card hangs off a 0x0 centred anchor: in a stack its hug width would otherwise set the bar's
    # min width and shove the right group off a narrow screen
    top_c = box("Top C Layer",
                box("Top C Anchor",
                    gcard("Top C", hints, readout, fill=GLASS, radius=6, pad=(7, 14, 7, 14), gap=5, align="center", ws="hug", border=True,
                          bid=keys_id),
                    w=0, h=0, ws="fixed", hs="fixed", align="center"),
                ws="fill", hs="fill", align="center")
    top = box("Top Bar", top_c, top_row, ws="fill", h=64, hs="fixed", pad=(0, 34, 0, 34), stack=True)

    def dock_btn(name, kind, sec):
        bid, icid = nid(), nid()
        c = gcard(name, gicon(name + " I", kind, 24, TXT, 1.7), fill=argb(ACC, 0), radius=6, pad=0, gap=0, align="center", ws="fixed", hs="fixed",
                  w=56, h=52, bid=bid)
        cv.toggle(name, "section", [(gfill_id(c), 37, argb(ACC, 0), argb("#FFFFFF", 0x24), "c")], on_op="equal", on_val=sec)
        cv.click(bid, "section", sec, name=f"Go {name}")
        return c

    def temp_ctl(name, prop, dn, up):
        d_id, u_id = nid(), nid()
        cv.click(d_id, "req", dn, name=f"{name} -")
        cv.click(u_id, "req", up, name=f"{name} +")
        return box(name, gcard(name + " Dn", gicon(name + " DnI", "chevl", 18, TXT, 1.8), fill=argb("#FFFFFF", 0), radius=5, pad=0, align="center",
                               ws="fixed", hs="fixed", w=34, h=44, bid=d_id),
                   bignum(name + " V", "21.5", 26, bindname=prop, unit="°", usize=14, weight=W_LIGHT),
                   gcard(name + " Up", gicon(name + " UpI", "chev", 18, TXT, 1.8), fill=argb("#FFFFFF", 0), radius=5, pad=0, align="center",
                         ws="fixed", hs="fixed", w=34, h=44, bid=u_id),
                   dir="row", align="center", gap=2)

    def vdiv(name):
        return box(name, w=1, h=34, ws="fixed", hs="fixed", fill=HAIR)

    fan_id, seat_id, def_id = nid(), nid(), nid()
    fan_btn = gcard("D Fan", gicon("D Fan I", "fan", 24, TXT, 1.7), fill=argb(ACC, 0), radius=6, pad=0, align="center", ws="fixed", hs="fixed",
                    w=52, h=52, bid=fan_id)
    seat_btn = gcard("D Seat", gicon("D Seat I", "seat", 24, TXT, 1.7), fill=argb(ACC, 0), radius=6, pad=0, align="center", ws="fixed", hs="fixed",
                     w=52, h=52, bid=seat_id)
    def_btn = gcard("D Def", gicon("D Def I", "defrost", 24, TXT, 1.7), fill=argb(ACC, 0), radius=6, pad=0, align="center", ws="fixed", hs="fixed",
                    w=52, h=52, bid=def_id)
    cv.toggle("D Fan", "section", [(gfill_id(fan_btn), 37, argb(ACC, 0), argb("#FFFFFF", 0x24), "c")], on_op="equal", on_val=4)
    cv.click(fan_id, "section", 4, name="Go Climate")
    cv.toggle("D Seat", "seat", [(gfill_id(seat_btn), 37, argb(ACC, 0), argb("#FFFFFF", 0x24), "c")])
    cv.toggle("D Def", "defrost", [(gfill_id(def_btn), 37, argb(ACC, 0), argb("#FFFFFF", 0x24), "c")])
    cv.click(seat_id, "req", 34, name="Seat")
    cv.click(def_id, "req", 33, name="Defrost")

    media_id, mpb, mplay, mpause = nid(), nid(), nid(), nid()
    mbtn = gcard("M Play", gicon("M Play I", "play", 18, TXT, 2.0, art_id=mplay), gicon("M Pause I", "pause", 18, TXT, 2.2, art_id=mpause),
                 fill=argb("#FFFFFF", 0), radius=22, pad=0, align="center", ws="fixed", hs="fixed", w=44, h=44, bid=mpb, border=True)
    for c in mbtn.children:
        if c.tag == "LayoutComponentStyle":
            c.attrs["layoutTypeValue"] = "stack"
    cv.toggle("M Playing", "playing", [(mplay, 18, 1, 0, "d"), (mpause, 18, 0, 1, "d")])
    cv.click(mpb, "req", 40, name="Mini Play")
    m_txt = box("M Txt", t("M Song", "Main Theme", 15, TXT, W_MED, bindname="song"), t("M Artist", "Rocket Squadron", 12.5, MUT, bindname="artist"),
                gap=1)
    cv.toggle("Compact Media", "compact", [(style_id(m_txt), 596, 0, 1, "u")], on_op="greaterThan", on_val=1.5)
    media_info = box("M Info", cover_art("M Cover", 46), m_txt, dir="row", align="center", gap=12, bid=media_id)
    cv.click(media_id, "section", 3, name="Go Media")
    # Responsive like the top bar: section tabs pinned left, media pinned right, the climate group centred on its
    # own stack layer; it drops out (display none) once the bar is too narrow for all three (compact >= 1)
    dock_c = box("Dock C Grp", vdiv("Div 1"),
                 box("Dock C", temp_ctl("TL", "tempL", 10, 11), seat_btn, fan_btn, def_btn, temp_ctl("TR", "tempR", 12, 13),
                     dir="row", align="center", gap=8, pad=(0, 16, 0, 16)),
                 vdiv("Div 2"), dir="row", align="center", gap=8)
    cv.toggle("Compact Dock", "compact", [(style_id(dock_c), 596, 0, 1, "u")], on_op="greaterThan", on_val=0.5)
    dock_row = box("Dock Row",
                   box("Dock L", dock_btn("D Home", "apps", 0), dock_btn("D Car", "car", 1), dock_btn("D Nav", "nav", 2),
                       dir="row", align="centerLeft", gap=8),
                   spacer("Dock Sp1"),
                   box("Dock R", media_info, mbtn, dir="row", align="centerRight", gap=12),
                   ws="fill", hs="fill", dir="row", align="centerLeft")
    dock = box("Dock", box("Dock C Layer", dock_c, ws="fill", hs="fill", align="center"), dock_row,
               ws="fill", h=64, hs="fixed", pad=(0, 6, 0, 6), stack=True)
    # no glass slab: a single white hairline with the controls below it, mirroring the top bar
    dock_rule = box("Dock Rule", ws="fill", h=1, hs="fixed", fill=argb("#FFFFFF", 0x38))
    dock_wrap = box("Dock Wrap", dock_rule, dock, ws="fill", pad=(0, 34, 14, 34), gap=4)

    # hotspot pins over the car (positions from world.as)
    pin_nodes = []
    for k, (kind, prop, val) in enumerate(PIN_DEFS):
        hit_id, ring_id, ringn_id = nid(), nid(), nid()
        ring = shape(f"Pin {k} Ring", ellipse(56, 56), stroke(argb(ACC, 0xB0), 1.5), sid=ring_id)
        disc = shape(f"Pin {k} Disc", ellipse(44, 44), stroke(argb("#FFFFFF", 0x50), 1.2), solid(argb("#0B0E11", 0xC8)), sid=hit_id)
        s = 44 / 2 * 0.86 * 0.55
        art = []
        for i, (pts, closed, filled) in enumerate(ICON[kind]):
            P = [(round(px * s, 2), round(py * s, 2)) for px, py in pts]
            art.append(shape(f"Pin {k} I{i}", poly(P, closed=closed), stroke(argb(TXT), 1.8), *([solid(argb(TXT))] if filled else [])))
        pn = node(f"Pin {k}", *art, disc, node(f"Pin {k} RingN", ring, nid_=ringn_id),
                  binds=[bind(f"pin{k}x", 13), bind(f"pin{k}y", 14), bind(f"pin{k}a", 18)])
        pin_nodes.append((pn, hit_id, ringn_id))
        cx.click(hit_id, prop, val, name=f"Pin {k}")
    pins = box("Pins", box("Pin Anchor", *[p for p, _, _ in pin_nodes], w=0, h=0, ws="fixed", hs="fixed"), ws="fill", hs="fill", align="topLeft")
    # idle: rings breathe, staggered
    m_pulse = Motion("Pin Pulse", 150, loop="loop")
    for k, (_, _, rn) in enumerate(pin_nodes):
        o = k * 18
        for key in (16, 17):
            m_pulse.k(rn, key, kf(1.0, 0, "cubic", ease=EASE_IO), kf(1.0, o, "cubic", ease=EASE_OUT), kf(1.35, o + 60, "hold"), kf(1.0, 150, "hold"))
        m_pulse.k(rn, 18, kf(1.0, 0, "linear"), kf(1.0, o, "linear"), kf(0.0, o + 60, "hold"), kf(1.0, 150, "hold"))
    a_pulse = m_pulse.build()
    anims.append(a_pulse)

    # a hairline under the top bar: on the visor it becomes the long arc that reads the curve (Flightlab)
    top_rule = box("Top Rule Wrap", box("Top Rule", ws="fill", h=1, hs="fixed", fill=argb("#FFFFFF", 0x38)), ws="fill", pad=(0, 34, 0, 34))
    hud_inner = box("HUD Inner", top, top_rule, box("HUD Mid", ws="fill", hs="fill", grow=1), dock_wrap, ws="fill", hs="fill")
    hud_id = nid()
    hud = box("HUD", hud_inner, ws="fill", hs="fill", bid=hud_id, opacity=0)
    pins_id = nid()
    pins_layer = box("Pins Layer", pins, ws="fill", hs="fill", bid=pins_id, opacity=0)

    def show_layer(name, oid, t_in, d_in, d_out):
        a_in = E("LinearAnimation", keyed(oid, kprop(18, kf(0, 0, "hold"), kf(0, t_in, "linear"), kf(1, t_in + d_in, "hold"))),
                 name=f"{name} In", id=nid(), duration=t_in + d_in, fps=60)
        a_out = E("LinearAnimation", keyed(oid, kprop(18, kf(1, 0, "linear"), kf(0, d_out, "hold"))), name=f"{name} Out", id=nid(),
                  duration=d_out, fps=60)
        s_o, s_i = nid(), nid()
        lay = E("StateMachineLayer", E("AnyState", x=0, y=-120), E("ExitState", x=500, y=-120),
                E("EntryState", E("StateTransition", stateToId=s_o), x=0, y=0),
                E("AnimationState", E("StateTransition", cond_num("hud", "greaterThan", 0.5), stateToId=s_i), animationId=a_out.id, id=s_o, x=200, y=0),
                E("AnimationState", E("StateTransition", cond_num("hud", "lessThan", 0.5), stateToId=s_o), animationId=a_in.id, id=s_i, x=200, y=140),
                name=name, id=nid())
        return lay, [a_in, a_out]

    hud_layer, hud_anims = show_layer("HUD", hud_id, 0, 24, 12)
    pins_sl, pins_anims = show_layer("Pins", pins_id, 14, 20, 8)
    anims += pins_anims

    # Visor artboard: top bar + dock. world.as sizes it to the stage, renders it to a canvas and wraps it onto a
    # cylinder around the camera (a visor), so both bars bow like the Flightlab concept.
    vs_, vsid = style(layoutWidthScaleType="fill", layoutHeightScaleType="fill", layoutTypeValue="stack")
    visor = E("Artboard", vs_, hud, name="Visor", id=VISOR_AB_ID, width=W, height=H, styleId=vsid, viewModelId=VM_ID,
              viewModelInstanceId=VMI_ID, x=1500, y=3000)
    visor.add(*hud_anims, *cv.anims)
    vsm = E("StateMachine", hud_layer, *cv.layers, *cv.listeners, name="Visor", id=nid())
    visor.attrs["defaultStateMachineId"] = vsm.id
    visor.add(vsm)

    intro_layer, intro_anims, intro_sm = build_intro()
    # Keyboard shortcuts on the web: key events only reach the focused node, and an embedded file starts with
    # nothing focused (the rive CLI player focuses the first FocusData for you, which hid this). Focus the
    # World layout (it owns the FocusData its keyboardEvent needs) as the state machine starts, in both intro
    # states the entry can run into.
    for st_ in intro_sm.children:
        if getattr(st_, "tag", None) == "AnimationState":
            st_.children.insert(0, E("FocusActionTarget", targetId=world.attrs["id"]))
    anims += intro_anims

    s, sid = style(layoutWidthScaleType="fill", layoutHeightScaleType="fill", layoutTypeValue="stack")
    ab = E("Artboard", s, intro_layer, pins_layer, stage, name="Garage", id=nid(), width=W, height=H, styleId=sid,
           viewModelId=VM_ID, viewModelInstanceId=VMI_ID)
    ab.add(E("Fill", E("SolidColor", colorValue=argb("#000000"), name="C"), name="Background"))
    ab.add(*anims, *cx.anims)
    sm = E("StateMachine", intro_sm, pins_sl, loop_layer(a_pulse), *cx.layers, *cx.listeners, name="Garage", id=nid())
    ab.attrs["defaultStateMachineId"] = sm.id
    ab.add(sm)
    return ab, visor


def build_intro():
    """Black, then the world rises; a thin wordmark with a lime rule draws in and leaves before the HUD."""
    black_id, title_id, rule_id, sub_id = nid(), nid(), nid(), nid()
    black = box("Intro Black", ws="fill", hs="fill", fill=argb("#000000"), bid=black_id)
    title = box("Intro Title", t("Intro Word", "CNCPT R1", 54, TXT, W_LIGHT, ls=14),
                box("Intro Rule", w=0, h=2, ws="fixed", hs="fixed", fill=argb(ACC), radius=1, bid=rule_id),
                t("Intro Sub", "RIVE VEHICLE INTERFACE", 12.5, MUT, W_MED, ls=4.5), align="center", gap=14, bid=title_id, opacity=0)
    sub_wrap = box("Intro Center", title, ws="fill", hs="fill", align="center")
    layer = box("Intro", sub_wrap, black, ws="fill", hs="fill", stack=True)
    mi = Motion("Intro", 260)
    mi.k(black_id, 18, kf(1, 0, "hold"), kf(1, 40, "cubic", ease=EASE_IO), kf(0, 110, "hold"))
    mi.k(title_id, 18, kf(0, 0, "hold"), kf(0, 30, "cubic", ease=EASE_OUT), kf(1, 70, "hold"), kf(1, 150, "cubic", ease=EASE_IN), kf(0, 185, "hold"))
    mi.k(rule_id, 7, kf(0, 0, "hold"), kf(0, 44, "cubic", ease=EASE_OUT), kf(220, 100, "hold"), kf(220, 150, "cubic", ease=EASE_IN), kf(0, 185, "hold"))
    a_intro = mi.build()
    a_off = E("LinearAnimation", keyed(black_id, kprop(18, kf(0, 0, "hold"))), keyed(title_id, kprop(18, kf(0, 0, "hold"))),
              name="Intro Done", id=nid(), duration=1, fps=60)
    s_ip, s_id = nid(), nid()
    sm = E("StateMachineLayer", E("AnyState", x=0, y=-120), E("ExitState", x=500, y=-120),
           E("EntryState", E("StateTransition", stateToId=s_ip), x=0, y=0),
           E("AnimationState", E("StateTransition", cond_num("hud", "greaterThan", 0.5), stateToId=s_id), animationId=a_intro.id, id=s_ip, x=200, y=0),
           E("AnimationState", E("StateTransition", cond_num("hud", "lessThan", 0.5), stateToId=s_ip), animationId=a_off.id, id=s_id, x=200, y=140),
           name="Intro", id=nid())
    return layer, [a_intro, a_off], sm


# ---------------------------------------------------------------- LED wall (live Rive motion graphics)
# The light wall behind the car is an 18 x 3.5 m LED screen. This artboard is drawn into a canvas every
# frame by world.as and sampled by env.wgsl (backdrop + environment cube) and car.wgsl (floor mirror and
# coloured light pools), so every frame of the motion graphics lights the car and the ground in real time.
LED_W, LED_H = 1860, 360
LED_DUR = 1200  # 20 s loop
# NuRiveWordmark01 (logo.rml, shared with Rive City): 800 x 400 artboard, wordmark 448 x 80 centred;
# its In/Out play when LogoVM.showLogo flips (world.as drives logoA / logoB on the LED clock)
LOGO_AB, LOGO_VM, LOGO_SM = "90:547", "90:470", "90:1003"
LOGO_S = 0.95  # wordmark ~425 px wide on the 1860 px screen
PRISM = ["#F30058", "#FF483C", "#FFA41C", "#71FF19", "#19F2FF", "#3084FF"]


def load_marks():
    import xml.etree.ElementTree as ET
    r = ET.parse(os.path.join(ROOT, "tools", "rive_marks.xml")).getroot()

    def conv(el):
        attrs = {k: v for k, v in el.attrib.items() if k not in ("id", "artboard")}
        return E(el.tag, *[conv(c) for c in el], **attrs)

    return {s.get("name"): (float(s.get("x", 0)), float(s.get("y", 0)), [conv(c) for c in s if c.tag == "PointsPath"]) for s in r}


def kcol(col, frame, interp="linear"):
    return E("KeyFrameColor", value=argb(col) if col.startswith("#") else col, frame=frame, interpolationType=interp)


def lerp_hex(stops, t):
    t = max(0.0, min(1.0, t)) * (len(stops) - 1)
    i = min(int(t), len(stops) - 2)
    f = t - i
    a = [int(stops[i][j:j + 2], 16) for j in (1, 3, 5)]
    b = [int(stops[i + 1][j:j + 2], 16) for j in (1, 3, 5)]
    return "#" + "".join(f"{round(a[j] + (b[j] - a[j]) * f):02X}" for j in range(3))


def ttext(name, s, size, col, weight, ls=None, x=0, y=0, cid=None, tid=None):
    sid = nid()
    paint = E("TextStylePaint", E("Fill", E("SolidColor", colorValue=argb(col), name="C", id=cid), name="Fill"),
              E("TextStyleAxis", tag=WGHT, axisValue=weight, name="W"), fontSize=size, fontAssetId=F_INT, letterSpacing=ls, id=sid, name="Style")
    return E("Text", paint, E("TextValueRun", styleId=sid, text=s, name="Run"), name=name, id=tid or nid(), alignValue="center",
             sizingValue="autoWidth", wrapValue="noWrap", x=x, y=y, originX=0.5, originY=0.5)


def build_led(x_off):
    """LED wall. Default: the prism bands scroll sideways like a barber pole, so the light on the floor and
    the car keeps changing colour. In the Media section (section == 3) a restrained music visualizer fades
    in over them (hairline spectrum, fine waveform, breathing album cover, slow dust, occasional soft glow),
    and fades back out when you leave. Both loops are seamless."""
    import random
    rnd = random.Random(66)
    cx, cy = LED_W / 2, LED_H / 2
    TAU = 2 * math.pi

    # ================================================================ colour show (always running)
    # One Rive prism colour fills the wall for ~4 s (so the ground and the car take a single strong tint),
    # then the next colour swipes in on a slanted edge led by three bright speed lines; a soft glint
    # crosses each colour while it holds.
    CYC, HOLD = 300, 236           # 5 s per colour, ~1 s swipe
    POLE = CYC * 6                 # 30 s loop
    W, H = LED_W, LED_H
    sk = 130                       # slant of the swipe edge (px over the screen height)
    base_c, wipe_id, wipe_c, glint_id = nid(), nid(), nid(), nid()
    base = shape("Base", rect(W + 40, H + 40, 0), E("Fill", E("SolidColor", colorValue=argb(PRISM[0]), name="C", id=base_c), name="Fill"),
                 x=cx, y=cy)
    span = W + 500
    wipe_shape = shape("Wipe S", poly([(-span, -H / 2 - 20), (sk / 2, -H / 2 - 20), (-sk / 2, H / 2 + 20), (-span - sk, H / 2 + 20)]),
                       E("Fill", E("SolidColor", colorValue=argb(PRISM[1]), name="C", id=wipe_c), name="Fill"))
    lines = []
    for j, (off, wd, al) in enumerate(((34, 22, 0xE6), (88, 11, 0xB0), (132, 5, 0x80))):
        lines.append(shape(f"Speed {j}", poly([(off + sk / 2, -H / 2 - 20), (off + wd + sk / 2, -H / 2 - 20),
                                               (off + wd - sk / 2, H / 2 + 20), (off - sk / 2, H / 2 + 20)]), solid(argb("#FFFFFF", al))))
    wipe = node("Wipe", *lines, wipe_shape, x=-260, y=cy, nid_=wipe_id)
    glint = node("Glint", shape("Glint S", poly([(-160 + sk / 2, -H / 2 - 20), (160 + sk / 2, -H / 2 - 20), (160 - sk / 2, H / 2 + 20),
                                                 (-160 - sk / 2, H / 2 + 20)]),
                                E("Fill", E("LinearGradient", E("GradientStop", colorValue=argb("#FFFFFF", 0), position=0),
                                            E("GradientStop", colorValue=argb("#FFFFFF", 0x2E), position=0.5),
                                            E("GradientStop", colorValue=argb("#FFFFFF", 0), position=1),
                                            startX=-160, startY=0, endX=160, endY=0, name="G"), name="Fill")),
                 x=-400, y=cy, nid_=glint_id)
    mp = Motion("Colour Show", POLE, loop="loop")
    bc, wc, wx, gx = [], [], [], []
    for k in range(6):
        c0 = k * CYC
        bc.append(kcol(PRISM[k], c0, "hold"))
        wc.append(kcol(PRISM[(k + 1) % 6], c0 + 1 if k else 0, "hold"))
        wx += [kf(-260, c0 + 1 if k else 0, "hold"), kf(-260, c0 + HOLD, "cubic", ease=(0.55, 0.0, 0.25, 1.0)), kf(W + 260, c0 + CYC, "hold")]
        gx += [kf(-400, c0 + (1 if k else 0), "hold"), kf(-400, c0 + 50, "cubic", ease=EASE_IO), kf(W + 400, c0 + 200, "hold")]
    mp.k(base_c, 37, *bc)
    mp.k(wipe_c, 37, *wc)
    mp.k(wipe_id, 13, *wx)
    mp.k(glint_id, 13, *gx)
    a_pole = mp.build()
    pole = node("Colour Show", glint, wipe, base)

    # ================================================================ visualizer (Media section)
    P = 480                        # 8 s loop = 16 beats at 120 BPM
    BEAT = 30
    m = Motion("Viz Loop", P, loop="loop")

    def pump(f, decay=4.0):
        return math.exp(-(f % BEAT) / BEAT * decay)

    def w(k):                      # angular frequency that loops exactly every P frames
        return TAU * k / P

    viz = []
    AS = 168
    alb_id = nid()
    viz.append(node("Album", album_img("Album Img", AS),
                    shape("Album Edge", rect(AS + 2, AS + 2, 0), stroke(argb("#FFFFFF", 0x80), 1.2)), x=cx, y=cy - 20, nid_=alb_id))

    def breathe():
        fr = []
        for f in range(0, P + 1, 4 * BEAT):
            fr += [kf(1.0, f, "linear")]
            if f < P:
                fr += [kf(1.018, f + 4, "cubic", ease=EASE_IO)]
        return fr
    m.k(alb_id, 16, *breathe())
    m.k(alb_id, 17, *breathe())

    # fine waveform: small dots tracing a slow layered sine (tapers to the screen edges)
    ND = 150
    for i in range(ND):
        xx = (i + 0.5) * LED_W / ND
        if abs(xx - cx) < AS / 2 + 30:
            continue
        did = nid()
        viz.append(node(f"Dot {i}", shape(f"Dot {i} S", ellipse(3.2, 3.2), solid(argb("#FFFFFF", 0xE6))), x=xx, y=cy - 20, nid_=did))
        env_ = math.sin(math.pi * min(1.0, abs(xx - cx) / (LED_W / 2)))
        fr = []
        for f in range(0, P + 1, 8):
            amp = 22 + 30 * pump(f, 2.5)
            yv = cy - 20 + amp * env_ * (math.sin(i * 0.12 - f * w(4)) * 0.7 + math.sin(i * 0.31 + f * w(2)) * 0.3)
            fr.append(kf(round(yv, 1), f, "cubic", ease=EASE_IO))
        m.k(did, 14, *fr)

    # hairline spectrum mirrored about the centre line
    NB = 120
    pitch = LED_W / NB
    for i in range(NB):
        bx = pitch * (i + 0.5)
        if abs(bx - cx) < AS / 2 + 26:
            continue
        bid = nid()
        d = abs(i - (NB - 1) / 2) / ((NB - 1) / 2)
        viz.append(node(f"Bar {i}", shape(f"Bar {i} S", rect(2.4, LED_H - 70, 1.2), solid(argb("#FFFFFF", 0x70))),
                        x=bx, y=cy - 20, sx=1, sy=0.1, nid_=bid))
        fr = []
        for f in range(0, P + 1, 10):
            v = 0.04 + 0.62 * (0.5 + 0.5 * math.sin(i * 0.17 + f * w(3))) * (0.55 + 0.45 * math.sin(i * 0.05 - f * w(2))) * (1 - 0.55 * d) \
                + 0.14 * (1 - d) ** 2 * pump(f, 3.0)
            fr.append(kf(round(max(0.03, min(v, 0.9)), 3), f, "cubic", ease=EASE_IO))
        m.k(bid, 17, *fr)

    viz.append(node("Centre Line", shape("Centre Line S", rect(LED_W - 120, 1, 0), solid(argb("#FFFFFF", 0x30))), x=cx, y=cy - 20))

    # slow dust: each speck rises once per loop, staggered
    for i in range(26):
        pid = nid()
        x0 = rnd.uniform(40, LED_W - 40)
        t0 = rnd.randint(1, P - 2)
        viz.append(node(f"Dust {i}", shape(f"Dust {i} S", ellipse(2.6, 2.6), solid(argb("#FFFFFF", 0x90))), x=x0, y=LED_H + 10, nid_=pid))
        # y(f) = linear rise from LED_H+10 at t0 to -10 at t0+P (wrapping): split at the loop boundary
        y_at0 = LED_H + 10 - (LED_H + 20) * ((P - t0) / P)
        m.k(pid, 14, kf(round(y_at0, 1), 0, "linear"), kf(-10, t0, "hold"), kf(LED_H + 10, t0 + 1, "linear"), kf(round(y_at0, 1), P, "linear"))

    # occasional colour: one soft glow at a time
    for k, (col, t0) in enumerate((("#3084FF", 0), ("#F30058", 120), ("#FFA41C", 240), ("#19F2FF", 360))):
        gid = nid()
        gx = cx + (-520, 480, -380, 560)[k]
        glow = shape(f"Glow {k} S", ellipse(1100, 560),
                     E("Fill", E("RadialGradient", E("GradientStop", colorValue=argb(col, 0xC0), position=0),
                                 E("GradientStop", colorValue=argb(col, 0x40), position=0.45),
                                 E("GradientStop", colorValue=argb(col, 0), position=1),
                                 startX=0, startY=0, endX=550, endY=0, name="G"), name="Fill"))
        viz.append(node(f"Glow {k}", glow, x=gx, y=cy, opacity=0, nid_=gid))
        fr = [kf(0, 0, "hold")] if t0 > 0 else []
        fr += [kf(0, t0, "cubic", ease=EASE_IO), kf(0.8, t0 + 40, "cubic", ease=EASE_IO), kf(0.8, t0 + 100, "cubic", ease=EASE_IO),
               kf(0, t0 + 180, "hold")]
        m.k(gid, 18, *fr)

    # black backing so the visualizer reads on black over the pole
    viz.append(node("Viz Black", shape("Viz Black S", rect(LED_W + 40, LED_H + 40, 0), solid(argb("#000000"))), x=cx, y=cy))
    a_viz = m.build()

    viz_id = nid()
    viz_group = node("Visualizer", *viz, opacity=0, nid_=viz_id)
    a_off = E("LinearAnimation", keyed(viz_id, kprop(18, kf(0, 0, "hold"))), name="Viz Off", id=nid(), duration=1, fps=60)
    a_in = E("LinearAnimation", keyed(viz_id, kprop(18, kf(0, 0, "cubic", ease=EASE_IO), kf(1, 45, "hold"))), name="Viz In", id=nid(),
             duration=45, fps=60)
    a_out = E("LinearAnimation", keyed(viz_id, kprop(18, kf(1, 0, "cubic", ease=EASE_IO), kf(0, 45, "hold"))), name="Viz Out", id=nid(),
              duration=45, fps=60)
    s_off, s_in, s_out = nid(), nid(), nid()
    fade = E("StateMachineLayer", E("AnyState", x=0, y=-160), E("ExitState", x=600, y=-160),
             E("EntryState", E("StateTransition", stateToId=s_off), x=0, y=0),
             E("AnimationState", E("StateTransition", cond_num("section", "equal", 3), stateToId=s_in), animationId=a_off.id, id=s_off, x=200, y=0),
             E("AnimationState", E("StateTransition", cond_num("section", "notEqual", 3), stateToId=s_out), animationId=a_in.id, id=s_in, x=400, y=0),
             E("AnimationState", E("StateTransition", cond_num("section", "equal", 3), stateToId=s_in), animationId=a_out.id, id=s_out, x=400, y=160),
             name="Viz Fade", id=nid())

    # ================================================================ city map (Navigate, section == 2)
    # The idle city map fills the wall (a band of the aerial image), drifting slowly across the city, dimmed a
    # touch so the white map doesn't blow out the set. Fades in / out with the section like the visualizer.
    msc = LED_W * 1.12 / 1024
    mh = 576 * msc
    map_drift = nid()
    map_img = E("Image", assetId=MAP_ID, name="Map Wall Img", id=nid(), scaleX=msc, scaleY=msc)
    map_node = node("Map Drift", map_img, x=cx, y=cy, nid_=map_drift)
    map_dim = shape("Map Dim", rect(LED_W + 40, LED_H + 40, 0), solid(argb("#05070A", 0x38)), x=cx, y=cy)
    map_id = nid()
    map_group = node("City Map", map_dim, map_node, opacity=0, nid_=map_id)
    MD = 60 * 40                                        # 40 s drift loop (ping-pong)
    dx = (LED_W * 1.12 - LED_W) / 2 - 4
    dy = (mh - LED_H) / 2 - 4
    mm = Motion("Map Drift", MD, loop="loop")
    mm.k(map_drift, 13, kf(cx - dx, 0, "cubic", ease=EASE_IO), kf(cx + dx, MD // 2, "cubic", ease=EASE_IO), kf(cx - dx, MD, "hold"))
    mm.k(map_drift, 14, kf(cy + dy * 0.6, 0, "cubic", ease=EASE_IO), kf(cy - dy * 0.6, MD // 2, "cubic", ease=EASE_IO), kf(cy + dy * 0.6, MD, "hold"))
    a_map = mm.build()
    m_off = E("LinearAnimation", keyed(map_id, kprop(18, kf(0, 0, "hold"))), name="Map Off", id=nid(), duration=1, fps=60)
    m_in = E("LinearAnimation", keyed(map_id, kprop(18, kf(0, 0, "cubic", ease=EASE_IO), kf(1, 45, "hold"))), name="Map In", id=nid(),
             duration=45, fps=60)
    m_out = E("LinearAnimation", keyed(map_id, kprop(18, kf(1, 0, "cubic", ease=EASE_IO), kf(0, 45, "hold"))), name="Map Out", id=nid(),
              duration=45, fps=60)
    q_off, q_in, q_out = nid(), nid(), nid()
    mfade = E("StateMachineLayer", E("AnyState", x=0, y=-160), E("ExitState", x=600, y=-160),
              E("EntryState", E("StateTransition", stateToId=q_off), x=0, y=0),
              E("AnimationState", E("StateTransition", cond_num("section", "equal", 2), stateToId=q_in), animationId=m_off.id, id=q_off, x=200, y=0),
              E("AnimationState", E("StateTransition", cond_num("section", "notEqual", 2), stateToId=q_out), animationId=m_in.id, id=q_in, x=400, y=0),
              E("AnimationState", E("StateTransition", cond_num("section", "equal", 2), stateToId=q_in), animationId=m_out.id, id=q_out, x=400, y=160),
              name="Map Fade", id=nid())

    st, sid = style(layoutWidthScaleType="fixed", layoutHeightScaleType="fixed", layoutTypeValue="stack")
    ab = E("Artboard", st, map_group, viz_group, pole, name="LED Wall", id=nid(), width=LED_W, height=LED_H, styleId=sid, viewModelId=VM_ID,
           viewModelInstanceId=VMI_ID, x=x_off, y=2200, clip=True)
    ab.add(E("Fill", E("SolidColor", colorValue=argb("#000000"), name="C"), name="Background"))
    ab.add(a_pole, a_viz, a_off, a_in, a_out, a_map, m_off, m_in, m_out)
    sm = E("StateMachine", loop_layer(a_pole), loop_layer(a_viz), loop_layer(a_map), fade, mfade, name="LED", id=nid())
    ab.attrs["defaultStateMachineId"] = sm.id
    ab.add(sm)
    return ab


def main():
    panels = [status_panel(1500), vehicle_panel(2200), nav_panel(2900), tunes_panel(3600), climate_panel(4300)]
    led = build_led(1500)
    garage, visor = build_garage(panels, led)
    root = E("Rive", build_vm(), garage, *panels, led, visor,
             E("FontAsset", file="fonts/Inter.ttf", name="Inter", id=F_INT),
             E("ImageAsset", file="assets/album.jpg", name="album", id=ALBUM_ID),
             E("ImageAsset", file="assets/map_wall.jpg", name="map", id=MAP_ID),
             E("ScriptAsset", file="world.as", name="world", id=SCRIPTS["world"]),
             version="1", kind="fragment")
    # car mesh pack (tools/export_car.py) and its texture (tools/make_plate.py)
    root.add(E("BlobAsset", file="assets/car.bin", name="car", id=nid()))
    root.add(E("BlobAsset", file="assets/tex/plate.png", name="t_plate", id=nid()))
    root.assign_ids()
    out = "<!-- GENERATED by tools/gen_glass.py — edit the generator, not this file -->\n" + root.render()
    open(os.path.join(ROOT, "scene.rml"), "w").write(out)
    print("wrote scene.rml", len(out), "bytes")


if __name__ == "__main__":
    main()
