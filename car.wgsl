// car.wgsl — physically based shading for the showroom: the hero car (quantised vertices), the
// studio floor (planar reflection + contact shadow), glass, and the environment backdrop.
//
// Lighting is image based: a GGX-prefiltered cube (env.wgsl) + split-sum LUT with multiple-scattering
// compensation. Car paint = metallic-flake base under a clearcoat. Per-vertex ambient occlusion comes
// from an offline Cycles bake (tools/export_car.py --ao).

struct O {
    mvp: mat4x4<f32>,
    model: mat4x4<f32>,
    base: vec4f,  // rgb linear albedo, a = metallic
    m1: vec4f,    // roughness, clearcoat, clearcoat roughness, flake strength
    m2: vec4f,    // mode, texture flags (1 albedo, 2 bump), exposure, time
    eye: vec4f,   // camera xyz, max lod of the specular cube
    q: vec4f,     // quantisation half extents xyz, bump strength
    uvr: vec4f,   // uv min xy, uv range zw
    uvt: vec4f,   // uv tiling xy, albedo-texture mix, ao strength
    emit: vec4f,  // emissive rgb (linear, pre-exposure), glass tint alpha
    shd: vec4f,   // contact-shadow ortho: centre x, centre z, half x, half z
    scr: vec4f,   // 1/target w, 1/target h, reflection strength, floor tone
    key: vec4f,   // key light direction (towards light) xyz, intensity
    keyc: vec4f,  // key light colour rgb, specular size
    wl: array<vec4f, 10>, // comic walls as area lights: (centre xyz, power) (avg colour rgb, yaw)
};

@group(0) @binding(0) var<uniform> o: O;
@group(0) @binding(1) var tSpec: texture_cube<f32>;
@group(0) @binding(2) var samp: sampler;
@group(0) @binding(3) var tLut: texture_2d<f32>;
@group(0) @binding(4) var tA: texture_2d<f32>;
@group(0) @binding(5) var tB: texture_2d<f32>;
@group(0) @binding(6) var tLed: texture_2d<f32>; // floor only: the LED wall's live Rive canvas

// Every fragment entry statically uses every binding of this file (`let keepLayoutUse = keepLayout();`), so the pipeline's
// auto layout is the same on every CLI: 1.6 bakes it from all the bindings a file declares, 1.7 from what each
// pipeline's entries use, and world.as mkBG binds all of them. No discard and no effect on the output.
fn keepLayout() -> f32 {
    let d = textureDimensions(tSpec).x + textureDimensions(tLut).x + textureDimensions(tA).x + textureDimensions(tB).x + textureDimensions(tLed).x;
    return f32(d) + textureSampleLevel(tLut, samp, vec2f(0.0), 0.0).x + o.base.x;
}

const PI: f32 = 3.14159265;

struct VOut {
    @builtin(position) pos: vec4f,
    @location(0) wpos: vec3f,
    @location(1) wnrm: vec3f,
    @location(2) uv: vec2f,
    @location(3) ao: f32,
    @location(4) opos: vec3f,
};

fn octDecode(e: vec2f) -> vec3f {
    var v = vec3f(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    let t = max(-v.z, 0.0);
    v.x += select(t, -t, v.x >= 0.0);
    v.y += select(t, -t, v.y >= 0.0);
    return normalize(v);
}

struct CarIn {
    @location(0) p: vec4<i32>,
    @location(1) n: vec2f,
    @location(2) uv: vec2f,
    @location(3) ao: vec4f,
};

@vertex
fn vs_car(v: CarIn) -> VOut {
    var r: VOut;
    let lp = vec3f(v.p.xyz) / 32767.0 * o.q.xyz;
    let wp = o.model * vec4f(lp, 1.0);
    r.pos = o.mvp * vec4f(lp, 1.0);
    r.wpos = wp.xyz;
    r.wnrm = normalize((o.model * vec4f(octDecode(v.n), 0.0)).xyz);
    let buv = o.uvr.xy + v.uv * o.uvr.zw;
    r.uv = vec2f(buv.x, 1.0 - buv.y) * o.uvt.xy; // Blender uv origin is bottom-left
    r.ao = v.ao.x;
    r.opos = lp;
    return r;
}

// contact-shadow height pass: orthographic from below, colour = world height of the lowest surface
struct HOut { @builtin(position) pos: vec4f, @location(0) h: f32, };

@vertex
fn vs_hgt(v: CarIn) -> HOut {
    var r: HOut;
    let wp = (o.model * vec4f(vec3f(v.p.xyz) / 32767.0 * o.q.xyz, 1.0)).xyz;
    r.pos = vec4f((wp.x - o.shd.x) / o.shd.z, -(wp.z - o.shd.y) / o.shd.w, clamp((wp.y + 1.0) / 8.0, 0.0, 1.0), 1.0);
    r.h = wp.y;
    return r;
}

@fragment
fn fs_hgt(i: HOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    return vec4f(i.h, 0.0, 0.0, 1.0);
}

struct FloorIn {
    @location(0) pos: vec3f,
    @location(1) nrm: vec3f,
    @location(2) uv: vec2f,
};

@vertex
fn vs_floor(v: FloorIn) -> VOut {
    var r: VOut;
    let wp = o.model * vec4f(v.pos, 1.0);
    r.pos = o.mvp * vec4f(v.pos, 1.0);
    r.wpos = wp.xyz;
    r.wnrm = normalize((o.model * vec4f(v.nrm, 0.0)).xyz);
    r.uv = v.uv;
    r.ao = 1.0;
    r.opos = v.pos;
    return r;
}

// UI cards go through the same visor lens as the top bar and dock (fs_visor's forward map): the projected
// position is read as a point on the flat HUD and moved to where the visor shows it, so a card's edges bow
// exactly like the bars. o.shd = (visor tan, aspect, inset, -).
fn visorWarp(ndc: vec2f) -> vec2f {
    let tX = o.shd.x;
    let th = clamp(ndc.x, -3.0, 3.0) * atan(tX);
    return vec2f(tan(th) / tX, ndc.y * o.shd.z / cos(th));
}

@vertex
fn vs_ui(v: FloorIn) -> VOut {
    var r: VOut;
    let wp = o.model * vec4f(v.pos, 1.0);
    r.pos = o.mvp * vec4f(v.pos, 1.0);
    r.wpos = wp.xyz;
    r.wnrm = normalize((o.model * vec4f(v.nrm, 0.0)).xyz);
    r.uv = v.uv;
    r.ao = 1.0;
    r.opos = v.pos;
    if (r.pos.w > 1e-4) {
        r.pos = vec4f(visorWarp(r.pos.xy / r.pos.w) * r.pos.w, r.pos.z, r.pos.w);
    }
    return r;
}

// ---------------------------------------------------------------- shared shading
fn srgb(c: vec3f) -> vec3f { return pow(max(c, vec3f(0.0)), vec3f(2.2)); }

fn hash3(p: vec3f) -> vec3f {
    let q = vec3f(dot(p, vec3f(127.1, 311.7, 74.7)), dot(p, vec3f(269.5, 183.3, 246.1)),
                  dot(p, vec3f(113.5, 271.9, 124.6)));
    return fract(sin(q) * 43758.5453);
}

fn hash1(p: vec2f) -> f32 { return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453); }

fn vnoise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash1(i), hash1(i + vec2f(1.0, 0.0)), u.x),
               mix(hash1(i + vec2f(0.0, 1.0)), hash1(i + vec2f(1.0, 1.0)), u.x), u.y);
}

fn envSpec(r: vec3f, rough: f32) -> vec3f {
    return textureSampleLevel(tSpec, samp, r, rough * o.eye.w).rgb;
}

fn envDiffuse(n: vec3f) -> vec3f {
    return textureSampleLevel(tSpec, samp, n, o.eye.w).rgb;
}

fn lut(nv: f32, rough: f32) -> vec2f {
    return textureSampleLevel(tLut, samp, vec2f(nv, 1.0 - rough), 0.0).rg;
}

struct Lit { diff: vec3f, spec: vec3f, };

fn ibl(n: vec3f, v: vec3f, f0: vec3f, rough: f32, albedo: vec3f) -> Lit {
    var l: Lit;
    let nv = clamp(dot(n, v), 1e-4, 1.0);
    let r = reflect(-v, n);
    let ab = lut(nv, rough);
    let pre = envSpec(r, rough);
    let irr = envDiffuse(n);
    let fss = f0 * ab.x + ab.y;
    let ess = ab.x + ab.y;
    let ems = 1.0 - ess;
    let favg = f0 + (1.0 - f0) / 21.0;
    let fms = fss * favg / (1.0 - ems * favg);
    let kd = albedo * (1.0 - fss - fms * ems);
    l.diff = (fms * ems + kd) * irr;
    l.spec = fss * pre;
    return l;
}

// analytic soft key light (GGX with widened lobe for the light's size)
fn keyLight(n: vec3f, v: vec3f, f0: vec3f, rough: f32, albedo: vec3f) -> vec3f {
    let L = normalize(o.key.xyz);
    let nl = max(dot(n, L), 0.0);
    if (nl <= 0.0 || o.key.w <= 0.0) { return vec3f(0.0); }
    let h = normalize(L + v);
    let nh = max(dot(n, h), 0.0);
    let vh = max(dot(v, h), 0.0);
    let a = clamp(rough * rough + o.keyc.w, 0.002, 1.0);
    let a2 = a * a;
    let d = nh * nh * (a2 - 1.0) + 1.0;
    let D = a2 / (PI * d * d);
    let F = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
    let k = (rough + 1.0) * (rough + 1.0) / 8.0;
    let nv = max(dot(n, v), 1e-4);
    let G = nv / (nv * (1.0 - k) + k) * nl / (nl * (1.0 - k) + k);
    let spec = D * F * G / max(4.0 * nv * nl, 1e-4);
    return (albedo / PI + spec) * nl * o.keyc.rgb * o.key.w;
}

// bump mapping from a height texture with screen-space derivatives (Mikkelsen 2010)
fn bumpNormal(p: vec3f, n: vec3f, h: f32, strength: f32) -> vec3f {
    let dpx = dpdx(p);
    let dpy = dpdy(p);
    let dhx = dpdx(h) * strength;
    let dhy = dpdy(h) * strength;
    let r1 = cross(dpy, n);
    let r2 = cross(n, dpx);
    let det = dot(dpx, r1);
    let g = sign(det) * (dhx * r1 + dhy * r2);
    return normalize(abs(det) * n - g);
}

fn exposureOut(c: vec3f) -> vec4f {
    return vec4f(c * o.m2.z, 1.0);
}

// ---------------------------------------------------------------- car
// geometric specular anti-aliasing (Tokuyoshi & Kaplanyan): widen the lobe where the normal changes
// faster than a pixel can resolve, so chrome trim and tight body curves stop sparkling.
fn aaRough(r: f32, k: f32) -> f32 {
    let a = r * r;
    return sqrt(sqrt(a * a + k));
}

@fragment
fn fs_car(i: VOut, @builtin(front_facing) ff: bool) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let mode = i32(o.m2.x + 0.5);
    let flags = i32(o.m2.y + 0.5);
    let gn = normalize(i.wnrm);
    let dnx = dpdx(gn);
    let dny = dpdy(gn);
    let kAA = min(0.5 * (dot(dnx, dnx) + dot(dny, dny)), 0.12);
    var n = normalize(i.wnrm);
    if (!ff) { n = -n; }
    let v = normalize(o.eye.xyz - i.wpos);
    var albedo = o.base.rgb;
    var metal = o.base.a;
    var rough = max(o.m1.x, 0.02);
    var texc = vec4f(1.0);
    if ((flags & 1) != 0) {
        texc = textureSample(tA, samp, i.uv);
        albedo = mix(albedo, albedo * srgb(texc.rgb), o.uvt.z);
    }
    if ((flags & 2) != 0) {
        let h = textureSample(tB, samp, i.uv).r;
        n = bumpNormal(i.wpos, n, h, o.q.w);
    }
    let aoS = mix(1.0, i.ao, o.uvt.w);
    var emissive = o.emit.rgb;

    if (mode == 5) {
        // tyre: the texture's bright sidewall ring is a painted whitewall (smoother than the rubber)
        let white = smoothstep(0.35, 0.6, dot(texc.rgb, vec3f(0.333)));
        rough = mix(0.82, 0.45, white);
        albedo = mix(vec3f(0.018), vec3f(0.62, 0.6, 0.56), white);
    }
    if (mode == 4) {
        // lens: emissive under a glossy glass skin
        let lens = srgb(texc.rgb);
        emissive = o.emit.rgb * (0.4 + 0.6 * dot(lens, vec3f(0.6, 0.3, 0.1)) * 2.0);
        albedo = albedo * 0.2;
    }

    // paint: metallic flakes perturb only the base layer; clearcoat stays a mirror
    var nb = n;
    let flake = o.m1.w;
    var baseRough = rough;
    if (flake > 0.0) {
        let cell = 0.0035;
        let q = i.opos / cell;
        let h = hash3(floor(q));
        let px = length(fwidth(i.opos));
        let vis = 1.0 - smoothstep(cell * 0.6, cell * 2.5, px);
        let tilt = (h - vec3f(0.5)) * 2.0;
        nb = normalize(n + tilt * 0.45 * flake * vis * step(0.4, h.x));
        baseRough = mix(rough + flake * 0.12, rough, vis);
    }
    baseRough = aaRough(baseRough, kAA);
    let f0 = mix(vec3f(0.04), albedo, metal);
    let dAlb = albedo * (1.0 - metal);
    let L = ibl(nb, v, f0, baseRough, dAlb);
    var c = L.diff * aoS + L.spec * mix(1.0, aoS, 0.75);
    c += keyLight(nb, v, f0, baseRough, dAlb) * aoS;
    let cc = o.m1.y;
    if (cc > 0.0) {
        let ccr = aaRough(max(o.m1.z, 0.02), kAA);
        let nv = clamp(dot(n, v), 1e-4, 1.0);
        let ab = lut(nv, ccr);
        let fc = 0.04 * ab.x + ab.y;
        let coat = envSpec(reflect(-v, n), ccr) * fc * mix(1.0, aoS, 0.6);
        let fres = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        c = c * (1.0 - cc * fres) + coat * cc + keyLight(n, v, vec3f(0.04), ccr, vec3f(0.0)) * cc * aoS;
    }
    c += emissive;
    return exposureOut(c);
}

// ---------------------------------------------------------------- glass (premultiplied blend)
@fragment
fn fs_glass(i: VOut, @builtin(front_facing) ff: bool) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let gn = normalize(i.wnrm);
    let dnx = dpdx(gn);
    let dny = dpdy(gn);
    let gr = aaRough(0.02, min(0.5 * (dot(dnx, dnx) + dot(dny, dny)), 0.12));
    var n = normalize(i.wnrm);
    if (!ff) { n = -n; }
    let v = normalize(o.eye.xyz - i.wpos);
    let nv = clamp(dot(n, v), 1e-4, 1.0);
    let ab = lut(nv, gr);
    let F = 0.04 * ab.x + ab.y;
    let fres = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
    let spec = envSpec(reflect(-v, n), gr) * F + keyLight(n, v, vec3f(0.04), gr, vec3f(0.0));
    let tint = o.emit.a;
    let a = clamp(fres + tint, 0.0, 1.0);
    let body = o.base.rgb * envDiffuse(n) * tint;
    return vec4f((spec + body) * o.m2.z, a);
}

// ---------------------------------------------------------------- light wall (mirrors env.wgsl WALL_*)
const WALL_C: vec3f = vec3f(8.13, 2.64, -8.5); // screen bottom 0.9 m up, on a dark plinth
const WALL_YAW: f32 = -0.547;
const WALL_HW: f32 = 9.0;
const WALL_HH: f32 = 1.74;
const WALL_COL: vec3f = vec3f(0.92, 0.95, 0.08);
// The LED wall is curved: an arc of a cylinder (radius WALL_R round the car, vertical axis) centred on
// azimuth WALL_AZ, 18 m of arc, screen from 0.9 m to 4.38 m on a plinth down to the ground. It stays on
// the island (shoreline >= 12.5 m) whatever the camera does.
const WALL_R: f32 = 11.0;
const WALL_AZ: f32 = -1.37;   // off the car's right / rear-right (world.as cameras work the left side)
const WALL_ARC: f32 = 1.6364;    // 18 m / WALL_R
const WALL_BOT: f32 = 0.12;
const WALL_TOP: f32 = 3.6;       // WALL_BOT + 2 * WALL_HH

// x = t (< 0: miss), y = u (0..1 left -> right seen from the car), z = height, w = +1 inner (screen) face / -1 back
fn wallHit(eye: vec3f, d: vec3f, tmax: f32, pad: f32) -> vec4f {
    let a = dot(d.xz, d.xz);
    if (a < 1e-8) { return vec4f(-1.0); }
    let b = dot(eye.xz, d.xz);
    let c = dot(eye.xz, eye.xz) - WALL_R * WALL_R;
    let disc = b * b - a * c;
    if (disc < 0.0) { return vec4f(-1.0); }
    let sq = sqrt(disc);
    for (var k = 0; k < 2; k++) {
        let t = (-b + (f32(k) * 2.0 - 1.0) * sq) / a;
        if (t <= 0.0 || t > tmax) { continue; }
        let q = eye + d * t;
        var da = atan2(q.x, q.z) - WALL_AZ;
        da = da - 6.2831853 * round(da / 6.2831853);
        if (abs(da) > WALL_ARC * 0.5 + pad / WALL_R) { continue; }
        if (q.y < 0.0 || q.y > WALL_TOP + pad) { continue; }
        let front = select(-1.0, 1.0, dot(d.xz, q.xz) > 0.0);
        return vec4f(t, 0.5 - da / WALL_ARC, q.y, front);
    }
    return vec4f(-1.0);
}

// position and inward normal of the wall at screen coordinate u (light sources for the pools)
fn wallPoint(u: f32) -> vec3f {
    let az = WALL_AZ + (0.5 - u) * WALL_ARC;
    return vec3f(sin(az) * WALL_R, 0.5 * (WALL_BOT + WALL_TOP), cos(az) * WALL_R);
}

fn ledTexF(uv: vec2f) -> vec3f {
    return pow(textureSampleLevel(tLed, samp, uv, 0.0).rgb, vec3f(2.2));
}

// the LED wall seen in a reflected ray from a floor point; blurred (5 taps) and edge-softened by
// roughness x distance
fn wallMirror(p: vec3f, d: vec3f, rough: f32) -> vec3f {
    // generous pad: the blurred mirror image spreads up to a few metres past the wall's edges; a small pad
    // cut it off and left a hard vertical edge in the floor glow
    let h = wallHit(p, d, 1e9, 4.0);
    if (h.x < 0.0 || h.w < 0.0) { return vec3f(0.0); }
    let t = h.x;
    let blur = 0.05 + rough * rough * t * 0.9;
    let span = WALL_ARC * WALL_R;
    let hh = WALL_TOP - WALL_BOT;
    let um = h.y * span;
    let vm = h.z - WALL_BOT;
    let mu = smoothstep(-blur, blur, um) * (1.0 - smoothstep(span - blur, span + blur, um));
    let mv = smoothstep(-blur, blur, vm) * (1.0 - smoothstep(hh - blur, hh + blur, vm));
    if (mu * mv <= 0.0) { return vec3f(0.0); }
    let uv = vec2f(clamp(h.y, 0.0, 1.0), clamp(1.0 - vm / hh, 0.0, 1.0));
    let bu = vec2f(blur / span, 0.0);
    let bv = vec2f(0.0, blur / hh);
    let col = (ledTexF(uv) * 2.0 + ledTexF(uv + bu) + ledTexF(uv - bu) + ledTexF(uv + bv) + ledTexF(uv - bv)) / 6.0;
    return col * o.wl[0].w / 1.1 * mu * mv * mix(1.0, 0.6, rough) * 1.5;
}

// coloured light pools from the LED wall: six area lights along the arc, each the colour of its strip
fn ledPool(p: vec3f, nrm: vec3f) -> vec3f {
    let area = WALL_ARC * WALL_R * (WALL_TOP - WALL_BOT) / 6.0;
    var sum = vec3f(0.0);
    for (var j = 0; j < 6; j++) {
        let u = (f32(j) + 0.5) / 6.0;
        let col = (ledTexF(vec2f(u - 0.05, 0.3)) + ledTexF(vec2f(u + 0.05, 0.5)) + ledTexF(vec2f(u, 0.75))) / 3.0;
        let c = wallPoint(u);
        let n = -normalize(vec3f(c.x, 0.0, c.z));
        let dv = c - p;
        let d2 = dot(dv, dv);
        let l = dv * inverseSqrt(d2);
        sum += col * area * max(dot(nrm, l), 0.0) * max(dot(-l, n), 0.0) / (PI * (d2 + area * 0.3));
    }
    return sum * o.wl[0].w / 1.1 * 2.6;   // the wall floods the ground in front of it
}

fn floorRelief(p: vec2f, a1: f32, a2: f32, a3: f32) -> f32 {
    return a1 * vnoise(p * 4.0) + a2 * vnoise(p * 12.0 + vec2f(3.1, 7.7)) + a3 * vnoise(p * 33.0 + vec2f(8.3, 1.9));
}

// ---------------------------------------------------------------- floor
@fragment
fn fs_floor(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let p = i.wpos.xz;
    var n = vec3f(0.0, 1.0, 0.0);
    let v = normalize(o.eye.xyz - i.wpos);
    // The view ray reaches the LED wall (or its plinth) before this floor point: the backdrop draws the
    // wall, so let it show (the backdrop has no depth; without this the floor painted over the wall's foot)
    {
        let rd = i.wpos - o.eye.xyz;
        let tf = length(rd);
        if (wallHit(o.eye.xyz, rd / tf, tf, 0.06).x > 0.0) { discard; }
    }
    // beyond the shoreline (jittered radius 15.5) the backdrop owns the ground: the lake and the basalt rocks (env.wgsl studio())
    let rad = length(p) + (vnoise(p * 0.12) - 0.5) * 6.0;
    if (rad > 15.5) { discard; }

    // Large irregular stone-concrete slabs: Voronoi cells ~5 m across with thin dark seams,
    // a quiet per-slab tone shift and fine low-contrast grain. Satin, not wet: roughness ~0.55-0.7 gives
    // the broad soft sheen, the car's mirror image is only a faint hint, and there is no bump ripple.
    let px = max(length(fwidth(p)), 1e-4);
    let gp = p / 5.0;
    let gc = floor(gp);
    var f1 = 9.0;
    var f2 = 9.0;
    var cid = vec2f(0.0);
    for (var yy = -1; yy <= 1; yy++) {
        for (var xx = -1; xx <= 1; xx++) {
            let cc = gc + vec2f(f32(xx), f32(yy));
            let jp = cc + 0.15 + 0.7 * hash3(vec3f(cc, 3.0)).xy;
            let dd = length(gp - jp);
            if (dd < f1) { f2 = f1; f1 = dd; cid = cc; } else if (dd < f2) { f2 = dd; }
        }
    }
    let edge = (f2 - f1) * 5.0 * 0.5;                    // metres to the nearest seam (approx.)
    let seam = 1.0 - smoothstep(0.007, 0.007 + px * 1.5, edge);
    let sh = hash3(vec3f(cid, 7.0));
    let nz = vnoise(p * 0.6) * 0.5 + vnoise(p * 2.7) * 0.3 + vnoise(p * 13.0) * 0.2;
    let fine = vnoise(p * 40.0) * (1.0 - smoothstep(0.004, 0.02, px));
    let stain = smoothstep(0.3, 0.8, vnoise(p * 0.18 + vec2f(4.0, 1.0)) * 0.7 + vnoise(p * 0.9) * 0.3);
    // dark charcoal stone; slabs differ clearly in tone (some near-black, some ash grey)
    let sand = (vnoise(p * 70.0) * 0.6 + vnoise(p * 150.0 + vec2f(5.0, 3.0)) * 0.4) * (1.0 - smoothstep(0.003, 0.012, px));
    let tone = 0.075;
    var albedo = vec3f(tone) * mix(0.6, 1.4, sh.x * sh.x) * mix(0.8, 1.2, stain) * mix(0.9, 1.08, nz) * (0.82 + 0.36 * sand) * (0.95 + 0.1 * fine)
                 * vec3f(0.99, 0.99, 1.0);
    // cloudy mid-scale mottling (10 cm - 1 m), the main texture you read at this distance
    let mott = vnoise(p * 1.7 + vec2f(2.0, 5.0)) * 0.5 + vnoise(p * 4.6) * 0.3 + vnoise(p * 11.0 + vec2f(7.0, 1.0)) * 0.2;
    albedo *= mix(0.72, 1.28, mott);
    albedo *= 1.0 - 0.3 * seam;
    let damp = 0.0;
    // micro-relief (raw stone / concrete): gentle undulation plus three octaves of grit whose slopes catch
    // the wall light and the sky sheen as grain. Each octave fades out once it gets smaller than a pixel.
    let e = 0.01;
    let a1 = 0.3 * (1.0 - smoothstep(0.06, 0.18, px));    // ~25 cm undulation
    let a2 = 0.16 * (1.0 - smoothstep(0.02, 0.06, px));   // ~8 cm bumps
    let a3 = 0.08 * (1.0 - smoothstep(0.008, 0.025, px)); // ~3 cm grit
    let h0 = floorRelief(p, a1, a2, a3);
    let hx = floorRelief(p + vec2f(e, 0.0), a1, a2, a3);
    let hz = floorRelief(p + vec2f(0.0, e), a1, a2, a3);
    let u0 = vnoise(p * 0.7);
    // slab finish: ~40% of slabs are polished (smooth, dark, reflective), the rest honed/rough with strong grit
    let polished = 1.0 - smoothstep(0.36, 0.44, sh.z);
    let bumpK = mix(0.1, 0.02, polished);
    let gx = (hx - h0) / e * bumpK + (vnoise((p + vec2f(0.25, 0.0)) * 0.7) - u0) / 0.25 * 0.08;
    let gz = (hz - h0) / e * bumpK + (vnoise((p + vec2f(0.0, 0.25)) * 0.7) - u0) / 0.25 * 0.08;
    n = normalize(vec3f(-gx, 1.0, -gz));
    // pores (dark pits) and pale aggregate flecks, only where they can resolve
    let res = 1.0 - smoothstep(0.008, 0.03, px);
    let pore = smoothstep(0.8, 0.93, vnoise(p * 22.0 + vec2f(9.0, 2.0))) * res;
    let fleck = smoothstep(0.85, 0.96, vnoise(p * 28.0 + vec2f(1.0, 7.0))) * res;
    // cavity: low spots darker, raised grit lighter (reads as texture even in flat light)
    let hn = h0 / max(a1 + a2 + a3, 1e-3);
    albedo *= mix((1.0 - 0.4 * pore) * (1.0 + 0.5 * fleck) * mix(0.7, 1.25, hn), 0.72 * mix(0.95, 1.05, hn), polished);
    var rough = mix(mix(0.66, 0.82, sh.y) + pore * 0.08 + (sand - 0.5) * 0.08, mix(0.3, 0.4, sh.y), polished) + (nz - 0.5) * 0.06;
    rough = mix(rough, 0.85, seam);
    let groove = 0.0;
    let trk = 0.0;
    // slightly darker toward the shore
    let shore = smoothstep(11.0, 15.5, rad);
    albedo *= 1.0 - 0.25 * shore;

    // contact shadow from the height map (soft: penumbra widens with the occluder's height)
    let suv = vec2f((p.x - o.shd.x) / o.shd.z, (p.y - o.shd.y) / o.shd.w) * 0.5 + vec2f(0.5);
    var occ = 0.0;
    var wide = 0.0;
    if (all(suv > vec2f(0.0)) && all(suv < vec2f(1.0))) {
        let h0 = textureSampleLevel(tB, samp, suv, 0.0).r;
        let texel = 1.0 / (2.0 * o.shd.z);
        let r = (0.03 + clamp(h0, 0.0, 1.5) * 0.18) * texel;
        let ga = 2.39996;
        for (var k = 0; k < 16; k++) {
            let fk = f32(k) + 0.5;
            let rr = sqrt(fk / 16.0);
            let a = fk * ga;
            let off = vec2f(cos(a), sin(a)) * rr;
            let h = textureSampleLevel(tB, samp, suv + off * r, 0.0).r;
            occ += 1.0 - smoothstep(0.0, 0.9, h);
            let hw = textureSampleLevel(tB, samp, suv + off * texel * 0.75, 0.0).r;
            wide += 1.0 - smoothstep(0.0, 2.2, hw);
        }
        occ /= 16.0;
        wide /= 16.0;
    }
    let ao = (1.0 - 0.95 * occ) * (1.0 - 0.75 * wide);

    // The grit normal (n) is for the directional light only (wall pools, key): it makes the grain catch the
    // light. The sky sheen and reflections use a much calmer normal (nS) so the broad satin gradient and the
    // slab seams survive instead of breaking into noise.
    let nS = normalize(mix(vec3f(0.0, 1.0, 0.0), n, mix(0.45, 0.25, polished)));
    let L = ibl(nS, v, vec3f(0.04), rough, albedo);
    // matte, dusty asphalt has little sheen except where it's damp (keeps the texture readable at grazing angles)
    // satin: broad, soft reflections everywhere (rough ~0.4-0.55), sharper in the damp patches
    let sheen = 1.0;
    var spec = L.spec * sheen;
    // the LED wall's coloured light pools on the concrete (follow the motion graphics frame by frame)
    let pool = ledPool(i.wpos, n);
    // planar reflection of the car, blurred by roughness
    let suv2 = i.pos.xy * o.scr.xy;
    let refl = textureSampleLevel(tA, samp, suv2, mix(3.5, 2.6, polished));
    let nv = clamp(dot(nS, v), 1e-4, 1.0);
    let ab = lut(nv, rough);
    let fr = 0.04 * ab.x + ab.y;
    spec += wallMirror(i.wpos, reflect(-v, nS), rough) * fr * sheen;
    // the car's mirror image: only a faint, very soft hint on satin stone (it read as a wet floor)
    spec = mix(spec, refl.rgb * fr * o.scr.z, refl.a * mix(0.06, 0.32, polished));
    // soft overhead fill around the car (a big diffuse softbox), falling off toward the shore
    let fillR = length(p - vec2f(0.0, 0.5));
    let fill = vec3f(0.5, 0.52, 0.56) * 0.35 * exp(-fillR * fillR / 60.0) * mix(1.0, 0.25, o.base.w);   // base.w = night
    var c = (L.diff * 0.9 + keyLight(n, v, vec3f(0.04), rough, albedo) + albedo * (pool + fill)) * ao + spec * ao;
    // underglow gadget: coloured light pooled under the car
    let gl = o.wl[9];
    if (gl.w > 0.0) {
        let q = max(abs(p) - vec2f(0.95, 2.6), vec2f(0.0));
        let dq = length(q);
        c += gl.rgb * gl.w * exp(-dq * 1.7) * (albedo * 6.0 + vec3f(0.01)) * (1.0 - 0.6 * occ);
    }
    // light haze with distance (matches the backdrop's ground haze)
    let dist = length(i.wpos - o.eye.xyz);
    let far = smoothstep(18.0, 60.0, dist) * 0.35;
    let envF = envSpec(normalize(i.wpos - o.eye.xyz), 0.6);
    c = mix(c, envF, far);
    return exposureOut(c);
}

// ---------------------------------------------------------------- comic wall lightbox
// The live Rive artboard is the diffuser of a lightbox: emissive, with a faint paper grain and a
// soft falloff toward the frame so it reads as a printed panel lit from behind, not a flat screen.
@fragment
fn fs_wall(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    var c = srgb(textureSample(tA, samp, i.uv).rgb);
    let grain = vnoise(i.uv * vec2f(900.0, 600.0)) * 0.06 + 0.97;
    let e = vec2f(min(i.uv.x, 1.0 - i.uv.x), min(i.uv.y, 1.0 - i.uv.y));
    let edge = smoothstep(0.0, 0.08, min(e.x, e.y * 1.5));
    c *= grain * (0.86 + 0.14 * edge);
    return vec4f(c * o.emit.rgb * o.m2.z, 1.0);
}

// ---------------------------------------------------------------- UI panel (post-grade composite)
fn acesUI(v0: vec3f) -> vec3f {
    let i = mat3x3<f32>(vec3f(0.59719, 0.07600, 0.02840), vec3f(0.35458, 0.90834, 0.13383), vec3f(0.04823, 0.01566, 0.83777));
    let oo = mat3x3<f32>(vec3f(1.60475, -0.10208, -0.00327), vec3f(-0.53108, 1.10813, -0.07276), vec3f(-0.07367, -0.00605, 1.07602));
    let v = i * v0;
    let a = v * (v + 0.0245786) - 0.000090537;
    let b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return clamp(oo * (a / b), vec3f(0.0), vec3f(1.0));
}

@fragment
fn fs_ui(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    // canvas is premultiplied sRGB; written straight to the display target so UI colours stay exact.
    // Frosted glass: where the panel's glass covers, the scene behind is replaced by a heavily blurred,
    // tone-mapped, slightly darkened copy (1/8-res 13-tap chain), seen through the panel's tint.
    let fade = o.emit.r;
    let ui = textureSample(tA, samp, i.uv) * fade;
    let suv = i.pos.xy * o.scr.xy;
    // 1/16-res frost level, 9 taps on a ~2-texel ring (32 px at full res): a deep, smooth glass blur
    let px = o.scr.xy * 30.0;
    var hdr = textureSampleLevel(tB, samp, suv, 0.0).rgb * 0.2;
    hdr += (textureSampleLevel(tB, samp, suv + vec2f(px.x, 0.0), 0.0).rgb + textureSampleLevel(tB, samp, suv - vec2f(px.x, 0.0), 0.0).rgb
            + textureSampleLevel(tB, samp, suv + vec2f(0.0, px.y), 0.0).rgb + textureSampleLevel(tB, samp, suv - vec2f(0.0, px.y), 0.0).rgb) * 0.12;
    hdr += (textureSampleLevel(tB, samp, suv + px * 0.7, 0.0).rgb + textureSampleLevel(tB, samp, suv - px * 0.7, 0.0).rgb
            + textureSampleLevel(tB, samp, suv + vec2f(px.x, -px.y) * 0.7, 0.0).rgb + textureSampleLevel(tB, samp, suv + vec2f(-px.x, px.y) * 0.7, 0.0).rgb) * 0.08;
    var frost = pow(acesUI(hdr), vec3f(1.0 / 2.2)) * 0.72 + vec3f(0.02);
    // Graphics > Glass blur off (o.m2.x = 1): a plain smoked tint instead of the blurred scene
    frost = mix(frost, vec3f(0.07, 0.075, 0.085), o.m2.x);
    // Glass lit by the scene: the curved card reflects the studio (env cube: sky, mountains, the live LED
    // wall, the softboxes). Fresnel-weighted and glossy, so the LED colour washes across the glass and the
    // highlight slides over the bent surface as the camera orbits. Plus a fine frosted grain.
    var n = normalize(i.wnrm);
    let v = normalize(o.eye.xyz - i.wpos);
    if (dot(n, v) < 0.0) { n = -n; }
    let nv = clamp(dot(n, v), 0.0, 1.0);
    let r = reflect(-v, n);
    let env = textureSampleLevel(tSpec, samp, r, 2.2).rgb * o.m2.z;
    let fres = 0.12 + 0.6 * pow(1.0 - nv, 3.0);
    let refl = pow(acesUI(env), vec3f(1.0 / 2.2)) * fres;
    let grain = fract(sin(dot(floor(i.pos.xy), vec2f(12.9898, 78.233))) * 43758.5453) - 0.5;
    frost *= 1.0 + grain * 0.05;
    let cover = smoothstep(0.04, 0.45, ui.a / max(fade, 1e-3)) * fade;
    let a = max(ui.a, cover);
    // the reflection sits on the front of the glass, over the content (premultiplied: screen-like add)
    let base = ui.rgb + frost * (1.0 - ui.a) * cover;
    return vec4f(base + refl * (1.0 - base) * cover, a);
}

// ---------------------------------------------------------------- visor (top bar + dock)
struct SOut { @builtin(position) pos: vec4f, @location(0) ndc: vec2f, };

// The bars' canvas is wrapped onto a vertical cylinder around the camera (a visor): every screen ray is
// intersected with the cylinder and the hit's (angle, height) indexes the flat canvas, so horizontal lines bow
// (the top bar sags toward the middle, the dock lifts), text rotates along the curve, and the glass gets the
// same frost + scene reflection as the panels, reflected about the cylinder's normal.
@fragment
fn fs_visor(s: SOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let tX = o.emit.x;
    let aspect = o.emit.y;
    let dx = s.ndc.x * tX;
    let dy = s.ndc.y * tX / aspect;
    let th = atan(dx);
    let h = dy * inverseSqrt(dx * dx + 1.0);
    let uv = vec2f(0.5 + th / (2.0 * atan(tX)), 0.5 - h / (2.0 * (tX / aspect) * o.emit.z));
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return vec4f(0.0); }
    let ui = textureSampleLevel(tA, samp, uv, 0.0);
    if (ui.a < 0.002) { return vec4f(0.0); }
    let suv = s.pos.xy * o.scr.xy;
    let px = o.scr.xy * 30.0;
    var hdr = textureSampleLevel(tB, samp, suv, 0.0).rgb * 0.2;
    hdr += (textureSampleLevel(tB, samp, suv + vec2f(px.x, 0.0), 0.0).rgb + textureSampleLevel(tB, samp, suv - vec2f(px.x, 0.0), 0.0).rgb
            + textureSampleLevel(tB, samp, suv + vec2f(0.0, px.y), 0.0).rgb + textureSampleLevel(tB, samp, suv - vec2f(0.0, px.y), 0.0).rgb) * 0.12;
    hdr += (textureSampleLevel(tB, samp, suv + px * 0.7, 0.0).rgb + textureSampleLevel(tB, samp, suv - px * 0.7, 0.0).rgb
            + textureSampleLevel(tB, samp, suv + vec2f(px.x, -px.y) * 0.7, 0.0).rgb + textureSampleLevel(tB, samp, suv + vec2f(-px.x, px.y) * 0.7, 0.0).rgb) * 0.08;
    var frost = pow(acesUI(hdr), vec3f(1.0 / 2.2)) * 0.72 + vec3f(0.02);
    frost = mix(frost, vec3f(0.07, 0.075, 0.085), o.m2.x);
    // world view ray; the visor's normal points back at the eye, horizontally (cylinder axis = up)
    let a = o.mvp * vec4f(s.ndc, 0.0, 1.0);
    let b = o.mvp * vec4f(s.ndc, 1.0, 1.0);
    let d = normalize(b.xyz / b.w - a.xyz / a.w);
    let n = -normalize(vec3f(d.x, 0.0, d.z) + vec3f(0.0, 0.0, 1e-4));
    let nv = clamp(dot(n, -d), 0.0, 1.0);
    let env = textureSampleLevel(tSpec, samp, reflect(d, n), 2.2).rgb * o.m2.z;
    let fres = 0.1 + 0.6 * pow(1.0 - nv, 3.0);
    let refl = pow(acesUI(env), vec3f(1.0 / 2.2)) * fres;
    let grain = fract(sin(dot(floor(s.pos.xy), vec2f(12.9898, 78.233))) * 43758.5453) - 0.5;
    frost *= 1.0 + grain * 0.05;
    let cover = smoothstep(0.04, 0.45, ui.a);
    let base = ui.rgb + frost * (1.0 - ui.a) * cover;
    return vec4f(base + refl * (1.0 - base) * cover, max(ui.a, cover));
}

// ---------------------------------------------------------------- backdrop

@vertex
fn vs_sky(@builtin(vertex_index) vi: u32) -> SOut {
    var s: SOut;
    let x = f32((vi << 1u) & 2u);
    let y = f32(vi & 2u);
    s.pos = vec4f(x * 2.0 - 1.0, 1.0 - y * 2.0, 1.0, 1.0);
    s.ndc = s.pos.xy;
    return s;
}

@fragment
fn fs_backdrop(s: SOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let a = o.mvp * vec4f(s.ndc, 0.0, 1.0);
    let b = o.mvp * vec4f(s.ndc, 1.0, 1.0);
    let d = normalize(b.xyz / b.w - a.xyz / a.w);
    let c = textureSampleLevel(tSpec, samp, d, 0.0).rgb;
    return vec4f(c * o.m2.z, 1.0);
}
