// env.wgsl — the studio environment, rendered and prefiltered on the GPU every time it changes.
//
// fs_env      : radiance of the studio for one cube face (mip 0 of the source cube)
// fs_down     : 2x box downsample of the source cube (builds its mip chain)
// fs_prefilter: split-sum GGX prefilter of the source cube into one mip of the specular cube
// fs_brdf     : split-sum BRDF lookup table (scale, bias) — rendered once
//
// Cube faces follow WebGPU order: +X, -X, +Y, -Y, +Z, -Z.

struct E {
    p0: vec4f, // x = face, y = roughness, z = source size (mip 0 texels), w = time
    p1: vec4f, // x = wall intensity, y = strip intensity, z = softbox intensity, w = source mip count
    p2: vec4f, // x = exposure ramp (intro), y = light-wall intensity, z = night (0 day .. 1 night), w = backdrop flag
    wa: array<vec4f, 5>, // comic walls: centre xyz, power
    wb: array<vec4f, 5>, // yaw, half width, half height, emissive intensity
    ivp: mat4x4<f32>,    // backdrop only: inverse view-projection
    cam: vec4f,          // backdrop only: camera position, exposure
};

@group(0) @binding(0) var<uniform> e: E;
@group(0) @binding(1) var tSrc: texture_cube<f32>;
@group(0) @binding(2) var samp: sampler;
@group(0) @binding(3) var tW0: texture_2d<f32>;
@group(0) @binding(4) var tW1: texture_2d<f32>;
@group(0) @binding(5) var tW2: texture_2d<f32>;
@group(0) @binding(6) var tW3: texture_2d<f32>;
@group(0) @binding(7) var tW4: texture_2d<f32>; // the LED wall's live Rive canvas (panel 4 has no env slot)

// Every fragment entry statically uses every binding of this file (`let keepLayoutUse = keepLayout();`), so the pipeline's
// auto layout is the same on every CLI: 1.6 bakes it from all the bindings a file declares, 1.7 from what each
// pipeline's entries use, and world.as mkBG binds all of them. No discard and no effect on the output.
fn keepLayout() -> f32 {
    let d = textureDimensions(tSrc).x + textureDimensions(tW0).x + textureDimensions(tW1).x + textureDimensions(tW2).x + textureDimensions(tW3).x + textureDimensions(tW4).x;
    return f32(d) + textureSampleLevel(tW0, samp, vec2f(0.0), 0.0).x + e.p0.x;
}

struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f, };

@vertex
fn vs_full(@builtin(vertex_index) vi: u32) -> VOut {
    var o: VOut;
    let x = f32((vi << 1u) & 2u);
    let y = f32(vi & 2u);
    o.pos = vec4f(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    o.uv = vec2f(x, y);
    return o;
}

const PI: f32 = 3.14159265;

fn faceDir(face: i32, uv: vec2f) -> vec3f {
    let s = uv.x * 2.0 - 1.0;
    let t = uv.y * 2.0 - 1.0;
    var d: vec3f;
    switch face {
        case 0: { d = vec3f(1.0, -t, -s); }
        case 1: { d = vec3f(-1.0, -t, s); }
        case 2: { d = vec3f(s, 1.0, t); }
        case 3: { d = vec3f(s, -1.0, -t); }
        case 4: { d = vec3f(s, -t, 1.0); }
        default: { d = vec3f(-s, -t, -1.0); }
    }
    return normalize(d);
}

fn srgb(c: vec3f) -> vec3f { return pow(c, vec3f(2.2)); }

// soft-edged rectangle mask in a plane's 2D coordinates
fn rectMask(p: vec2f, lo: vec2f, hi: vec2f, soft: f32) -> f32 {
    let a = smoothstep(lo - vec2f(soft), lo + vec2f(soft), p);
    let b = 1.0 - smoothstep(hi - vec2f(soft), hi + vec2f(soft), p);
    return a.x * a.y * b.x * b.y;
}

// The garage studio, seen from the car's centre (eye at y = 0.8).
// A big warm-grey cyclorama hall with long overhead light strips (the white lines that run along
// the body), a dim ceiling, polished concrete, and the comic panels: live Rive artboards hanging in
// the space, which are emissive lightboxes and the main colour of every reflection.
fn wallTex(k: i32, uv: vec2f) -> vec4f {
    switch k {
        case 0: { return textureSampleLevel(tW0, samp, uv, 0.0); }
        case 1: { return textureSampleLevel(tW1, samp, uv, 0.0); }
        case 2: { return textureSampleLevel(tW2, samp, uv, 0.0); }
        case 3: { return textureSampleLevel(tW3, samp, uv, 0.0); }
        default: { return textureSampleLevel(tW4, samp, uv, 0.0); }
    }
}

fn hash2(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn noise2(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + vec2f(1.0, 0.0)), u.x), mix(hash2(i + vec2f(0.0, 1.0)), hash2(i + vec2f(1.0, 1.0)), u.x), u.y);
}

fn fbm2(p0: vec2f) -> f32 {
    var p = p0;
    var a = 0.5;
    var s = 0.0;
    for (var k = 0; k < 5; k++) {
        s += a * noise2(p);
        p = p * 2.03 + vec2f(17.1, 9.3);
        a *= 0.5;
    }
    return s;
}

// low sun off the car's right, just past the wall's far end: rims the car from the left of the opening
// shot without staring into the lens (cameras work the car's left side, looking toward az ~-2.5)
const SUN: vec3f = vec3f(-0.567, 0.062, -0.825);

// Day <-> night moves the lights instead of fading them: over the first 60% of the blend the sun sinks
// along its azimuth from 3.5 deg to below the far shore (it slips behind the mountains and the horizon);
// over the last 60% the moon climbs from below the horizon to its spot above the car. Reversed for sunrise.
fn sunDir() -> vec3f {
    let s = smoothstep(0.0, 0.6, e.p2.z);
    let el = mix(0.062, -0.09, s);
    let hz = normalize(vec3f(SUN.x, 0.0, SUN.z));
    return normalize(vec3f(hz.x * cos(el), sin(el), hz.z * cos(el)));
}
fn moonDir() -> vec3f {
    let s = smoothstep(0.4, 1.0, e.p2.z);
    let el = mix(-0.08, 0.17, s);
    let hz = normalize(vec3f(MOON.x, 0.0, MOON.z));
    return normalize(vec3f(hz.x * cos(el), sin(el), hz.z * cos(el)));
}

// Dusk sky: deep blue zenith, a hot pop-art horizon (tangerine -> pink) toward the low sun, clouds.
fn sky(d: vec3f) -> vec3f {
    let sd = sunDir();
    let h = max(d.y, 0.0);
    let toward = max(dot(normalize(vec3f(d.x, 0.0, d.z) + vec3f(1e-5)), normalize(vec3f(sd.x, 0.0, sd.z))), 0.0);
    let zen = vec3f(0.05, 0.085, 0.19);
    let midc = vec3f(0.3, 0.37, 0.56);
    let warm = mix(vec3f(1.05, 0.72, 0.78), vec3f(1.9, 1.1, 0.6), pow(toward, 6.0));
    let hor = mix(vec3f(0.66, 0.72, 0.9), warm, pow(toward, 2.2));
    var c = mix(hor, midc, smoothstep(0.0, 0.22, h));
    c = mix(c, zen, smoothstep(0.18, 0.75, h));
    // sun + glow
    // clouds on a plane, lit warm from below near the sun
    if (d.y > 0.01) {
        let uv = d.xz / (d.y + 0.08) * 1.4;
        let cl = smoothstep(0.48, 0.78, fbm2(uv * 0.9 + vec2f(3.0, 1.0)));
        let lit = mix(vec3f(0.3, 0.32, 0.46), vec3f(1.8, 0.85, 0.6), pow(toward, 3.0) * (1.0 - smoothstep(0.0, 0.5, h)));
        c = mix(c, lit, cl * 0.75 * smoothstep(0.01, 0.12, d.y));
    }
    let nk = e.p2.z;
    if (nk > 0.0) {
        c = mix(c, nightSky(d), nk);
    }
    return c;
}

// Sun disc + glow and the moon disc. Added in skyAll() only where no mountain range covers the sky, so
// the part of the sun that has sunk behind a ridge is really hidden (it used to shine through the ranges'
// haze, which mixes in the base sky). Added after the night blend, so the sun stays bright as it sinks and
// simply disappears behind the horizon instead of fading out.
fn skyLights(d: vec3f) -> vec3f {
    let nk = e.p2.z;
    let sd = sunDir();
    let sdot = max(dot(d, sd), 0.0);
    let setK = smoothstep(0.0, 0.6, nk);
    let sunTint = mix(vec3f(1.0), vec3f(1.0, 0.5, 0.22), setK);
    let sunDisc = vec3f(1.6, 0.8, 0.35) * pow(sdot, 60.0) * 0.8 * (1.0 + setK)
                  + vec3f(30.0, 18.0, 9.0) * sunTint * smoothstep(0.9993, 0.9997, sdot);
    var c = sunDisc * smoothstep(-0.01, 0.004, d.y) * (1.0 - smoothstep(0.6, 0.7, nk));
    let mdot = max(dot(d, moonDir()), 0.0);
    c += vec3f(3.0, 3.1, 3.4) * smoothstep(0.99990, 0.99994, mdot) * nk * smoothstep(-0.01, 0.004, d.y);
    return c;
}

// Night: deep blue-black, a faint cool glow along the horizon, a moon high behind the car in the opening
// shot, a dense field of small stars and dark clouds catching a little moonlight.
const MOON: vec3f = vec3f(-0.507, 0.169, -0.845);
fn nightSky(d: vec3f) -> vec3f {
    let h = max(d.y, 0.0);
    var c = mix(vec3f(0.022, 0.03, 0.055), vec3f(0.006, 0.009, 0.022), smoothstep(0.0, 0.35, h));
    c = mix(c, vec3f(0.002, 0.003, 0.008), smoothstep(0.3, 0.9, h));
    let md = moonDir();
    let mdot = max(dot(d, md), 0.0);
    c += vec3f(0.35, 0.42, 0.6) * pow(mdot, 40.0) * 0.12 + vec3f(0.03, 0.04, 0.06) * pow(mdot, 6.0);
    // stars: one candidate per small cell of (azimuth, elevation), sparse, varied brightness
    if (d.y > 0.02) {
        let az = atan2(d.x, d.z);
        let g = vec2f(az * 260.0, asin(clamp(d.y, -1.0, 1.0)) * 260.0);
        let cell = floor(g);
        let r = hash2(cell);
        if (r > 0.985) {
            let off = vec2f(hash2(cell + 17.0), hash2(cell + 41.0)) * 0.6 + 0.2;
            let dd = length(g - cell - off);
            let b = (r - 0.985) / 0.015;
            c += vec3f(0.9, 0.95, 1.0) * (0.15 + 1.4 * b * b) * smoothstep(0.32, 0.0, dd) * smoothstep(0.02, 0.2, d.y);
        }
        let uv = d.xz / (d.y + 0.08) * 1.4;
        let cl = smoothstep(0.48, 0.78, fbm2(uv * 0.9 + vec2f(3.0, 1.0)));
        c = mix(c, vec3f(0.012, 0.016, 0.03) + vec3f(0.03, 0.035, 0.05) * pow(mdot, 4.0), cl * 0.8 * smoothstep(0.01, 0.12, d.y));
    }
    return c;
}

fn ridged(p0: vec2f) -> f32 {
    var p = p0;
    var a = 0.5;
    var s = 0.0;
    for (var k = 0; k < 6; k++) {
        let n = 1.0 - abs(noise2(p) * 2.0 - 1.0);
        s += a * n * n;
        p = p * 2.07 + vec2f(5.3, 1.7);
        a *= 0.5;
    }
    return s;
}

// Mountain ranges: four layers of ridged-noise silhouettes, near to far, kilometres away (so even the
// nearest keeps some blue air in front of it). Faces are shaded like pyramids under each peak (the
// silhouette slope over a window that widens with depth) plus diagonal couloirs and ribs; snow holds on
// the upper ribs with a crisp, broken edge; valley mist pools at each foot. All fields are functions of
// azimuth, so mountains() blends two evaluations across the atan2 seam at az = +-pi (otherwise there is a
// hard vertical break in the range behind the camera's usual view).
fn mtnRidge(az: f32, k: f32) -> f32 {
    let x = az * (1.5 + k * 1.2) + k * 7.3;
    let env = 0.45 + 0.55 * noise2(vec2f(az * 0.9 + k * 3.0, k * 1.7));
    let r = ridged(vec2f(x, k * 3.1));
    let jag = (noise2(vec2f(az * 60.0 + k * 13.0, k)) - 0.5) * 0.006;   // fine crags on the skyline
    return 0.015 + (0.34 - k * 0.07) * env * pow(r, 2.6) + jag * env;
}

// seam weight: within 0.6 rad of +pi every azimuth field fades toward its value at az - 2pi, which is
// exactly what the -pi side shows, so the fields are continuous all the way round
fn seamT(az: f32) -> f32 { return smoothstep(3.14159265 - 0.6, 3.14159265, az); }
fn ridgeW(az: f32, k: f32) -> f32 {
    let t = seamT(az);
    var r = mtnRidge(az, k);
    if (t > 0.0) { r = mix(r, mtnRidge(az - 6.2831853, k), t); }
    return r;
}
fn ridgedW(az: f32, el: f32, sa: f32, sh: f32, off: f32) -> f32 {
    let t = seamT(az);
    var g = ridged(vec2f((az + el * sh) * sa + off, el * sa * 0.45));
    if (t > 0.0) { g = mix(g, ridged(vec2f((az - 6.2831853 + el * sh) * sa + off, el * sa * 0.45)), t); }
    return g;
}
fn screeFbm(az: f32, el: f32, fk: f32) -> f32 {
    let t = seamT(az);
    var f = fbm2(vec2f(az * 220.0, el * 180.0) + fk * 7.0);
    if (t > 0.0) { f = mix(f, fbm2(vec2f((az - 6.2831853) * 220.0, el * 180.0) + fk * 7.0), t); }
    return f;
}
fn noiseW(az: f32, s: f32, o: vec2f) -> f32 {
    let t = seamT(az);
    var n = noise2(vec2f(az * s, 0.0) + o);
    if (t > 0.0) { n = mix(n, noise2(vec2f((az - 6.2831853) * s, 0.0) + o), t); }
    return n;
}

// az here is the mountain-field azimuth (seam rotated to sit behind the LED wall, where the wall hides it
// from most camera positions); lighting terms come in from the true direction.
fn mtnLayer(az: f32, el: f32, fk: f32, sunSide: f32, toward: f32) -> vec4f {
    let ridge = ridgeW(az, fk);
    if (el >= ridge) { return vec4f(0.0); }
    let depth = (ridge - el) / max(ridge, 1e-3);          // 0 at the ridge line, 1 at the foot
    let wdt = 0.012 + 0.07 * depth;
    let rs = (ridgeW(az + wdt, fk) - ridgeW(az - wdt, fk)) / (2.0 * wdt);
    let sa = 26.0 * (1.0 + fk * 0.6);
    let sh = 0.55 * sign(rs);
    let g0 = ridgedW(az, el, sa, sh, fk * 11.0);
    let g1 = ridgedW(az + 0.06 / sa, el, sa, sh, fk * 11.0);
    let rib = (g1 - g0) / 0.06;
    let fine = screeFbm(az, el, fk);                           // scree / rock texture
    let lit = clamp(0.45 + 1.0 * sunSide * clamp(rs * 3.0, -1.0, 1.0) + 0.3 * sunSide * clamp(rib, -1.0, 1.0)
                    + 0.25 * (g0 - 0.5) + 0.2 * (fine - 0.5), 0.06, 1.5);
    var rock = vec3f(0.05, 0.06, 0.08) * (0.65 + 0.5 * g0) * (0.75 + 0.5 * fine) * (0.3 + lit * 1.05);
    rock += vec3f(0.5, 0.32, 0.22) * pow(toward, 3.0) * lit * 0.05;
    let snowLine = 0.16 + 0.26 * noiseW(az, 9.0, vec2f(fk * 5.0, fk));
    let sv = g0 + 0.12 * (1.0 - depth) + 0.18 * (fine - 0.5);
    let snowAmt = smoothstep(snowLine + 0.12, snowLine - 0.15, depth + (fine - 0.5) * 0.12)
                  * smoothstep(0.55, 0.62, sv) * (0.95 - fk * 0.15);
    let snow = mix(vec3f(0.24, 0.28, 0.4), vec3f(0.8, 0.83, 0.91), clamp(lit * 0.8, 0.0, 1.0)) * (0.92 + 0.16 * fine);
    let nk = e.p2.z;
    let rockN = rock * 0.18;
    let snowN = mix(vec3f(0.02, 0.025, 0.04), vec3f(0.09, 0.11, 0.17), clamp(lit * 0.8, 0.0, 1.0));
    let m = mix(mix(rock, snow, snowAmt), mix(rockN, snowN, snowAmt), nk);
    let mist = smoothstep(0.55, 1.0, depth) * (0.35 + fk * 0.1);
    let fog = clamp(0.16 + fk * 0.16 + mist, 0.0, 0.9);
    return vec4f(m, fog);
}

const MTN_SEAM_AZ: f32 = -1.62;   // world azimuth of the field seam = the LED wall's centre

fn mountains(d: vec3f, base: vec3f) -> vec3f {
    let el = d.y;
    if (el > 0.4 || el < -0.02) { return base; }
    let az = atan2(d.x, d.z);
    var fa = az - MTN_SEAM_AZ - 3.14159265;
    fa = fa - 6.2831853 * round(fa / 6.2831853);          // field azimuth in [-pi, pi], seam behind the wall
    var c = base;
    let sd = sunDir();
    let toward = max(dot(normalize(vec3f(d.x, 0.0, d.z) + vec3f(1e-5)), normalize(vec3f(sd.x, 0.0, sd.z))), 0.0);
    let haze = mix(mix(vec3f(0.42, 0.47, 0.64), vec3f(0.95, 0.66, 0.62), pow(toward, 2.0)), vec3f(0.025, 0.033, 0.06), e.p2.z);
    let skyHaze = mix(haze, base, 0.55);
    var dAz = atan2(sd.x, sd.z) - az;
    dAz = dAz - 6.2831853 * round(dAz / 6.2831853);
    let sunSide = select(-1.0, 1.0, dAz > 0.0);
    let bd = (u32(e.p2.w + 0.5) & 1u) != 0u;
    // Front to back with an early out: a layer that covers the pixel hides every range behind it completely
    // (its colour replaces c), so the far layers' shading is only paid where they actually show. Same image as
    // the old back-to-front loop.
    for (var k = 0; k < 4; k++) {
        let fk = f32(k);
        if (el >= 0.02 + (0.34 - fk * 0.07)) { continue; }   // above this range's highest possible peak
        if (bd) {
            // backdrop: a conservative per-azimuth bound on this range's skyline (baked once, fs_ridgeb)
            // skips the ridge evaluation for the open sky above it; same image, the bound never undercuts
            let rb = textureSampleLevel(tW1, samp, vec2f(fa * 0.15915494 + 0.5, (fk + 0.5) * 0.25), 0.0).r;
            if (el >= rb) { continue; }
        }
        let L = mtnLayer(fa, el, fk, sunSide, toward);
        if (L.w > 0.0) { return mix(L.rgb, skyHaze, L.w); }
    }
    return c;
}

fn skyAll(d: vec3f) -> vec3f {
    let s = sky(d);
    var m = s;
    if ((u32(e.p2.w + 0.5) & 8u) == 0u) { m = mountains(d, s); }   // bit 3: profiling switch, mountains off
    if (all(m == s)) {
        return s + skyLights(d);   // open sky: the sun / moon show
    }
    return m;                      // a range covers this direction: the lights behind it are hidden
}

// The light wall: a huge freestanding emissive panel behind the car's rear-left quarter.
// It lights the paint through the env cube, pools on the asphalt and shows in its reflection.
// Centre, yaw (facing the car), half extents and colour are mirrored in world.as (WALL_*).
const WALL_C: vec3f = vec3f(8.13, 2.64, -8.5); // screen bottom 0.9 m up, on a dark plinth
const WALL_YAW: f32 = -0.547;
const WALL_HW: f32 = 9.0;
const WALL_HH: f32 = 1.74;
const WALL_COL: vec3f = vec3f(0.92, 0.95, 0.08);
// The LED wall is curved: an arc of a cylinder (radius WALL_R round the car, vertical axis) centred on
// azimuth WALL_AZ, 18 m of arc, screen from 0.12 m to 3.6 m on a thin black base. It stays on
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

// LED wall texel (linear rgb). uv: 0..1 left->right, top->bottom as seen from the car side.
fn ledTex(uv: vec2f) -> vec3f {
    return srgb(textureSampleLevel(tW4, samp, uv, 0.0).rgb);
}

// LED pixel structure: 465 x 90 modules (3.9 cm pitch); fades out with distance before it can moire.
// (No fwidth: this runs in non-uniform control flow; ~0.6 mrad per screen pixel instead.)
fn ledGrid(uv: vec2f, t: f32) -> f32 {
    let g = uv * vec2f(465.0, 90.0);
    let fw = t * 0.0006 * 465.0 / (2.0 * WALL_HW);
    let f = abs(fract(g) - 0.5) * 2.0;
    let dotm = 1.0 - smoothstep(0.55, 0.95, max(f.x, f.y));
    return mix(0.55 + 0.6 * dotm, 1.0, smoothstep(0.15, 0.45, fw));
}

// returns rgb + hit distance in w (1e9 = miss)
fn lightWall(eye: vec3f, d: vec3f) -> vec4f {
    let bez = 0.06;
    let h = wallHit(eye, d, 1e9, bez);
    if (h.x < 0.0) { return vec4f(0.0, 0.0, 0.0, 1e9); }
    let t = h.x;
    if (h.w < 0.0) {
        // back of the panel: dark steel
        return vec4f(vec3f(0.012, 0.012, 0.014), t);
    }
    let v = (WALL_TOP - h.z) / (WALL_TOP - WALL_BOT);
    if (h.y < 0.0 || h.y > 1.0 || v < 0.0 || v > 1.0) {
        // bezel / plinth: satin black, a faint sky sheen toward the top of the plinth
        let sheen = 0.004 + 0.01 * smoothstep(0.0, WALL_BOT, h.z);
        return vec4f(vec3f(sheen, sheen, sheen * 1.1), t);
    }
    let uv = vec2f(h.y, v);
    var c: vec3f;
    if (e.p2.w > 0.5) {
        c = ledTex(uv) * ledGrid(uv, t);
    } else {
        let o = vec2f(1.5 / 465.0, 1.5 / 90.0);
        c = (ledTex(uv) * 2.0 + ledTex(uv + vec2f(o.x, 0.0)) + ledTex(uv - vec2f(o.x, 0.0))
             + ledTex(uv + vec2f(0.0, o.y)) + ledTex(uv - vec2f(0.0, o.y))) / 6.0;
    }
    return vec4f(max(c * e.p2.y, vec3f(0.006, 0.006, 0.007)), t);
}

// light from the LED wall falling on a ground point: six area lights along the screen, each the
// colour of its strip of the live canvas, so the pools on the ground follow the motion graphics
fn wallPool(p: vec3f) -> vec3f {
    let area = WALL_ARC * WALL_R * (WALL_TOP - WALL_BOT) / 6.0;
    var sum = vec3f(0.0);
    for (var j = 0; j < 6; j++) {
        let u = (f32(j) + 0.5) / 6.0;
        let col = (ledTex(vec2f(u - 0.05, 0.3)) + ledTex(vec2f(u + 0.05, 0.5)) + ledTex(vec2f(u, 0.75))) / 3.0;
        let c = wallPoint(u);
        let n = -normalize(vec3f(c.x, 0.0, c.z));
        let dv = c - p;
        let d2 = dot(dv, dv);
        let l = dv * inverseSqrt(d2);
        sum += col * area * max(l.y, 0.0) * max(dot(-l, n), 0.0) / (PI * (d2 + area * 0.3));
    }
    return sum * e.p2.y;
}


// ---------------------------------------------------------------- basalt shoreline
// Clusters of jagged dark rock rise out of the shallows beyond the pad's shoreline (rad > 20.5, same
// jittered radius as the floor shader), thinning out toward the far shore. Heightfield raymarch.
fn ridged4(p0: vec2f) -> f32 {
    var p = p0;
    var a = 0.5;
    var s = 0.0;
    for (var k = 0; k < 4; k++) {
        let n = 1.0 - abs(noise2(p) * 2.0 - 1.0);
        s += a * n * n;
        p = p * 2.11 + vec2f(5.3, 1.7);
        a *= 0.5;
    }
    return s;
}

fn shoreRad(q: vec2f) -> f32 {
    return length(q) + (noise2(q * 0.12) - 0.5) * 6.0;
}

fn rockH(q: vec2f) -> f32 {
    let rad = shoreRad(q);
    // a band of open water first (the lake right behind the car), then the rocky shore
    let zone = smoothstep(24.0, 32.0, rad) * (1.0 - smoothstep(110.0, 170.0, rad));
    let cl = smoothstep(0.42, 0.6, noise2(q * 0.028 + vec2f(7.0, 3.0))) * 0.9 + 0.1 * smoothstep(0.6, 0.72, noise2(q * 0.11));
    let m = zone * cl;
    if (m <= 0.002) { return -0.4; }
    // broad, low lava-rock shelves with blocky tops (not spires): ~0.5-2.4 m above the water
    let r = ridged4(q * 0.09 + vec2f(2.0, 9.0));
    let shelf = smoothstep(0.2, 0.55, r);
    let top = 1.0 - 0.35 * pow(1.0 - shelf, 2.0);
    return m * (shelf * top * 2.2 + noise2(q * 0.9) * 0.35 + noise2(q * 4.0) * 0.08) - 0.4;
}

// Rock heights for the backdrop's ray marches, from a heightmap baked once (fs_rockhm) instead of the
// procedural ridged noise at every step: bound at binding 3 of the backdrop's group (the backdrop never
// draws the panels, so tW0 is free there). Shading (rockSurf) still uses the exact procedural rockH.
const HM_EXTENT: f32 = 348.0;
fn rockHM(q: vec2f) -> f32 {
    if ((u32(e.p2.w + 0.5) & 1u) != 0u) {
        return textureSampleLevel(tW0, samp, q / HM_EXTENT + vec2f(0.5), 0.0).r;
    }
    return rockH(q);
}

// skyline bound per range (row k of RB_N x 4): the max of ridgeW over +-1.5 bins around the bin centre (so a
// linear blend of two neighbouring bins still bounds every azimuth between them) plus a margin for the
// crags between the 32 samples
@fragment
fn fs_ridgeb(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let n = e.p0.y;
    let fk = floor(i.pos.y);
    let c = i.pos.x / n * 6.2831853 - 3.14159265;
    let w = 1.5 / n * 6.2831853;
    var m = -1.0;
    for (var s = 0; s <= 32; s++) {
        m = max(m, ridgeW(c - w + 2.0 * w * f32(s) / 32.0, fk));
    }
    return vec4f(m + 0.006, 0.0, 0.0, 1.0);
}

@fragment
fn fs_rockhm(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let q = (i.pos.xy / e.p0.y - vec2f(0.5)) * HM_EXTENT;
    return vec4f(rockH(q), 0.0, 0.0, 1.0);
}

// first rock hit along eye + d t (t < tmax), or -1.
// The rocks live in a thin slab (y -0.4..2.3) inside an annulus (shore radius ~22..175 m). Clip the ray to
// both first, then march with a minimum step that grows with distance. The old fixed-start march ran out
// of its 72 steps ~30-70 m out on grazing rays (a low camera, and the lake's reflection rays), so far shelves
// went missing from the reflection and the rocks looked like they floated above a bright band.
fn marchRocks(eye: vec3f, d: vec3f, t0: f32, tmax: f32) -> f32 {
    return marchRocksK(eye, d, t0, tmax, 0.1, 0.018, 120);
}

// kMin + kT * t = minimum step; coarse settings for the lake's (rippled) reflection rays
fn marchRocksK(eye: vec3f, d: vec3f, t0: f32, tmax: f32, kMin: f32, kT: f32, nMax: i32) -> f32 {
    if ((u32(e.p2.w + 0.5) & 4u) != 0u) { return -1.0; }   // bit 2: profiling switch, rocks off
    var ta = t0;
    var tb = tmax;
    // slab
    if (abs(d.y) > 1e-5) {
        let t1 = (2.35 - eye.y) / d.y;
        let t2 = (-0.4 - eye.y) / d.y;
        ta = max(ta, min(t1, t2));
        tb = min(tb, max(t1, t2));
    } else if (eye.y > 2.35 || eye.y < -0.4) {
        return -1.0;
    }
    // annulus: rocks need shoreRad in (24, 170) and shoreRad = |q| +- 3, so they only exist for 21 < |q| < 173
    // (horizontal distance): skip the open water inside r = 20 and stop where the ray leaves r = 173 (exact:
    // the steps before that point are unchanged)
    let dh2 = dot(d.xz, d.xz);
    if (dh2 > 1e-8) {
        let b = dot(eye.xz, d.xz) / dh2;
        let e2 = dot(eye.xz, eye.xz);
        let cc = (e2 - 400.0) / dh2;
        let disc = b * b - cc;
        if (disc > 0.0) {
            let tin = -b + sqrt(disc);          // leaving the inner disc
            if (cc < 0.0) { ta = max(ta, tin); }
        }
        let co = (e2 - 29929.0) / dh2;
        let disco = b * b - co;
        if (disco > 0.0) {
            tb = min(tb, -b + sqrt(disco));     // leaving the outer disc
        } else {
            return -1.0;
        }
    }
    if (ta >= tb) { return -1.0; }
    var t = ta;
    var prev = ta;
    for (var k = 0; k < nMax; k++) {
        if (t > tb) { break; }
        let q = eye + d * t;
        let dh = q.y - rockHM(q.xz);
        if (dh < 0.0) {
            var lo = prev;
            var hi = t;
            for (var j = 0; j < 6; j++) {
                let mid = 0.5 * (lo + hi);
                let qm = eye + d * mid;
                if (qm.y - rockHM(qm.xz) < 0.0) { hi = mid; } else { lo = mid; }
            }
            return hi;
        }
        prev = t;
        t += max(kMin + t * kT, dh * 0.6);
    }
    return -1.0;
}

// rock normal + albedo (shared by the shading and the env cube's dynamic pool pass)
struct RockSurf { n: vec3f, alb: vec3f, wet: f32, };
fn rockSurf(p: vec3f, t: f32) -> RockSurf {
    let ep = 0.12 * (1.0 + t * 0.02);
    let hx = rockH(p.xz + vec2f(ep, 0.0)) - rockH(p.xz - vec2f(ep, 0.0));
    let hz = rockH(p.xz + vec2f(0.0, ep)) - rockH(p.xz - vec2f(0.0, ep));
    let n = normalize(vec3f(-hx, 2.0 * ep, -hz));
    // basalt: near-black to dusty grey-brown by cluster, lighter weathered tops and ledges, wet and glossy at
    // the waterline (catches the sky)
    let grit = noise2(p.xz * 3.1) * 0.6 + noise2(p.xz * 11.0) * 0.4;
    let kind = noise2(p.xz * 0.05 + vec2f(3.0, 1.0));
    var alb = mix(vec3f(0.03, 0.031, 0.036), vec3f(0.075, 0.068, 0.062), smoothstep(0.35, 0.75, kind)) * (0.65 + 0.7 * grit);
    alb = mix(alb, vec3f(0.16, 0.155, 0.15), smoothstep(0.72, 0.96, n.y) * smoothstep(0.3, 0.7, grit) * 0.9);
    let wet = 1.0 - smoothstep(0.0, 0.35, p.y);
    alb *= mix(1.0, 0.45, wet);
    return RockSurf(n, alb, wet);
}

// rock colour without the LED wall's light (static: cached in the env cube)
fn rockShadeStatic(p: vec3f, t: f32) -> vec3f {
    return rockLit(rockSurf(p, t));
}

fn rockLit(s: RockSurf) -> vec3f {
    let sd = sunDir();
    let nk = e.p2.z;
    let amb = vec3f(0.36, 0.41, 0.58) * (0.4 + 0.6 * s.n.y) * mix(1.0, 0.1, nk);
    let sun = vec3f(1.2, 0.8, 0.6) * max(dot(s.n, sd), 0.0) * 0.45 * (1.0 - nk);
    var col = s.alb * (amb + sun);
    // glossy wet rim: a little sky reflection near the water
    col += vec3f(0.32, 0.37, 0.52) * 0.08 * s.wet * pow(1.0 - max(s.n.y, 0.0), 2.0) * mix(1.0, 0.1, nk);
    return col;
}

// (one rockSurf: it was evaluated twice, eight procedural height samples instead of four)
fn rockShade(p: vec3f, t: f32) -> vec3f {
    let s = rockSurf(p, t);
    return rockLit(s) + wallPool(p) * s.alb * 2.0;
}


fn studioLights(eye: vec3f, d: vec3f, c0: vec3f) -> vec3f {
    let up = e.p2.x;
    let backdrop = e.p2.w > 0.5;
    var c = c0;
    // photo-studio lights that only the car sees (env cube, never the on-screen backdrop): a big overhead
    // softbox for the long hood / roof highlights, and a tall strip on the camera side for a crisp line
    // along the flanks
    if (!backdrop) {
        if (d.y > 0.05) {
            let t = (7.0 - eye.y) / d.y;
            let q = eye + d * t;
            let m = rectMask(q.xz, vec2f(-2.4, -4.6), vec2f(2.4, 4.6), 0.5);
            c = mix(c, vec3f(2.6, 2.6, 2.7) * mix(1.0, 0.45, e.p2.z), m);
        }
        if (d.x > 0.05) {
            let t = (8.0 - eye.x) / d.x;
            let q = eye + d * t;
            let m = rectMask(q.zy, vec2f(-5.5, 0.6), vec2f(5.5, 2.4), 0.25);
            c = mix(c, vec3f(1.5, 1.52, 1.6) * mix(1.0, 0.45, e.p2.z), m * 0.8);
        }
    }
    // comic panels (camera-attached UI) as soft light sources for reflections
    let wallI = e.p1.x;
    var best = 1e9;
    for (var k = 0; k < 4; k++) {
        let wa = e.wa[k];
        let wb = e.wb[k];
        if (wa.w <= 0.001 || e.p2.w > 0.5) { continue; }
        let n = vec3f(sin(wb.x), 0.0, cos(wb.x));
        let r = vec3f(cos(wb.x), 0.0, -sin(wb.x));
        let dn = dot(d, n);
        if (abs(dn) < 1e-4) { continue; }
        let t = dot(wa.xyz - eye, n) / dn;
        if (t <= 0.0 || t > best) { continue; }
        let p = eye + d * t - wa.xyz;
        let u = dot(p, r) / (2.0 * wb.y) + 0.5;
        let v = 0.5 - p.y / (2.0 * wb.z);
        if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) { continue; }
        best = t;
        let tx = wallTex(k, vec2f(u, v));
        c = mix(c, srgb(tx.rgb) * wb.w * wa.w * wallI, tx.a);
    }
    // underglow tint on the strips no longer exists: disco hue drives the ground glow (floor shader)
    return c * up;
}

fn studio(eye: vec3f, d: vec3f) -> vec3f {
    let up = e.p2.x;
    // Fast path, same result: inside r = 14.5 m the ground is the plain pad (no water, no rocks, and the haze
    // weight is exactly 0 closer than 30 m), so skip the sky/mountain evaluations (skyAll, haze) and the rock
    // march. These pixels are mostly hidden behind the floor mesh anyway (it covers r < 15.5), but the
    // reduced-res backdrop trace ran the full studio() for every one of them.
    if (d.y < -0.004) {
        let t0 = -eye.y / d.y;
        let p0 = eye + d * t0;
        if (shoreRad(p0.xz) < 14.5) {
            var pad0 = padAlbedo(p0);
            pad0 += pad0 * wallPool(p0) * 2.0;
            let lw0 = lightWall(eye, d);
            return studioLights(eye, d, select(pad0, lw0.rgb, lw0.w < t0));
        }
    }
    // Front to back, same image as before: the LED wall (r = 11 m) and the rocks (r > 21 m) hide everything
    // behind them, so find them first and skip the sky, mountain and lake work for the pixels they cover
    // (the wall fills a big part of most shots). The rock march stops at the wall: anything it could find
    // behind it would be hidden anyway.
    let backdrop = e.p2.w > 0.5;
    let lw = lightWall(eye, d);
    var tr = -1.0;
    if (d.y < 0.08) {
        // rocks only show in front of the water plane: stop the march where the ray meets it
        let tw = select(320.0, min(320.0, -eye.y / min(d.y, -1e-4) + 0.05), d.y < 0.0);
        tr = marchRocks(eye, d, 8.0, min(tw, lw.w));
    }
    if (d.y < 0.0) {
        let t = -eye.y / min(d.y, -1e-4);
        if (lw.w < min(t, select(1e9, tr, tr > 0.0))) { return studioLights(eye, d, lw.rgb); }
        // low mist over the water, thickening with distance
        let haze = skyCached(normalize(vec3f(d.x, 0.002, d.z)));
        if (tr > 0.0 && tr < t) {
            let q = eye + d * tr;
            return studioLights(eye, d, mix(rockShade(q, tr), haze, smoothstep(40.0, 260.0, tr) * 0.75));
        }
        var c = vec3f(0.0);
        if (d.y > -0.004) { c = skyAll(d); }   // below that the ground replaces it entirely (s = 1)
        let p = eye + d * t;
        let rad = shoreRad(p.xz);
        // lake: mirror of sky, ridges and rocks, fine ripples
        let rip = (noise2(p.xz * 2.0) - 0.5) * 0.02;
        let dr = normalize(vec3f(d.x + rip, -d.y, d.z + rip));
        let nv = clamp(-d.y, 0.0, 1.0);
        let fres = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
        var refl = skyCached(dr);
        if (backdrop && rad > 15.5) {
            // Graphics Balanced / Fast (p2.w bit 1): a coarser march for the rippled lake reflection of the rocks
            var trr = -1.0;
            if ((u32(e.p2.w + 0.5) & 2u) != 0u) { trr = marchRocksK(p, dr, 0.3, 160.0, 0.25, 0.03, 60); } else { trr = marchRocks(p, dr, 0.3, 160.0); }
            if (trr > 0.0) {
                let qr = p + dr * trr;
                refl = mix(rockShade(qr, trr + t), skyCached(normalize(vec3f(dr.x, 0.002, dr.z))), smoothstep(40.0, 220.0, trr + t) * 0.8);
            }
        }
        let lake = refl * fres + vec3f(0.003, 0.005, 0.008);
        // pad: dark volcanic asphalt (the floor mesh draws it near the car; this is what reflections see)
        var pad = padAlbedo(p);
        pad += pad * wallPool(p) * 2.0;
        let water = smoothstep(15.3, 15.6, rad);
        var g = mix(pad, lake, water);
        g = mix(g, haze, smoothstep(30.0, 900.0, t) * 0.85);
        c = mix(c, g, smoothstep(0.0, -0.004, d.y));
        return studioLights(eye, d, c);
    }
    if (lw.w < select(1e8, tr, tr > 0.0)) { return studioLights(eye, d, lw.rgb); }
    if (tr > 0.0) {
        let q = eye + d * tr;
        return studioLights(eye, d, mix(rockShade(q, tr), skyCached(normalize(vec3f(d.x, 0.002, d.z))), smoothstep(40.0, 260.0, tr) * 0.75));
    }
    return studioLights(eye, d, skyAll(d));
}

// ---------------------------------------------------------------- env cube: static cache + live pass
// Everything in the reflection cube that never changes (sky, mountains, raymarched rocks, lake, pad) is
// traced ONCE into a static cube (fs_env_static). Its alpha says what the live pass must add on top:
//   a > 0 : pad, weight of the LED wall's pool light on it      a < 0 : rock at distance -a
// fs_env then rebuilds the exact studio() result each frame from that cache: + LED pool light, the LED wall
// itself, the softbox / strip, the UI panel quads and the intro exposure. Same image, without re-marching
// the rocks and re-shading four mountain ranges on 1.5 M cube texels every frame.
const ENV_EYE: vec3f = vec3f(0.0, 0.8, 0.0);

fn studioStatic(eye: vec3f, d: vec3f) -> vec4f {
    var c = skyAll(d);
    var code = 0.0;
    var tr = -1.0;
    if (d.y < 0.08) {
        // rocks only show in front of the water plane: stop the march where the ray meets it
        let tw = select(320.0, min(320.0, -eye.y / min(d.y, -1e-4) + 0.05), d.y < 0.0);
        tr = marchRocks(eye, d, 8.0, tw);
    }
    if (d.y < 0.0) {
        let t = -eye.y / min(d.y, -1e-4);
        let p = eye + d * t;
        let rad = shoreRad(p.xz);
        let rip = (noise2(p.xz * 2.0) - 0.5) * 0.02;
        let dr = normalize(vec3f(d.x + rip, -d.y, d.z + rip));
        let nv = clamp(-d.y, 0.0, 1.0);
        let fres = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
        let refl = skyAll(dr);
        let lake = refl * fres + vec3f(0.003, 0.005, 0.008);
        let pad = padAlbedo(p);
        let water = smoothstep(15.3, 15.6, rad);
        var g = mix(pad, lake, water);
        let haze = skyAll(vec3f(d.x, 0.002, d.z));
        let hz = smoothstep(30.0, 900.0, t) * 0.85;
        g = mix(g, haze, hz);
        let s = smoothstep(0.0, -0.004, d.y);
        c = mix(c, g, s);
        code = (1.0 - water) * (1.0 - hz) * s;
        if (tr > 0.0 && tr < t) {
            let q = eye + d * tr;
            c = mix(rockShadeStatic(q, tr), haze, smoothstep(40.0, 260.0, tr) * 0.75);
            code = -tr;
        }
    } else {
        if (tr > 0.0) {
            let q = eye + d * tr;
            c = mix(rockShadeStatic(q, tr), skyAll(vec3f(d.x, 0.002, d.z)), smoothstep(40.0, 260.0, tr) * 0.75);
            code = -tr;
        }
    }
    return vec4f(c, code);
}

fn padAlbedo(p: vec3f) -> vec3f {
    let nz = noise2(p.xz * 0.07) * 0.6 + noise2(p.xz * 0.9) * 0.4;
    return vec3f(0.06, 0.06, 0.065) * (0.55 + 0.8 * nz) * mix(1.0, 0.12, e.p2.z);
}

// sky + mountains only (+ sun / moon), no rocks: rendered with the static cache, sampled by the backdrop
@fragment
fn fs_skycube(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    return vec4f(skyAll(faceDir(i32(e.p0.x + 0.5), i.uv)), 1.0);
}

// backdrop: the sky in direction d from the cached cube (bit 0 of p2.w = backdrop pass; env passes compute it)
fn skyCached(d: vec3f) -> vec3f {
    if ((u32(e.p2.w + 0.5) & 1u) != 0u) {
        return textureSampleLevel(tSrc, samp, d, 0.0).rgb;
    }
    return skyAll(d);
}

@fragment
fn fs_env_static(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let d = faceDir(i32(e.p0.x + 0.5), i.uv);
    return studioStatic(ENV_EYE, d);
}

@fragment
fn fs_env(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let d = faceDir(i32(e.p0.x + 0.5), i.uv);
    let eye = ENV_EYE;
    let s = textureSampleLevel(tSrc, samp, d, 0.0);
    var c = s.rgb;
    var tHit = 1e9;
    if (s.a > 0.0) {
        let t = -eye.y / min(d.y, -1e-4);
        let p = eye + d * t;
        c += padAlbedo(p) * wallPool(p) * 2.0 * s.a;
    } else if (s.a < 0.0) {
        let tr = -s.a;
        let q = eye + d * tr;
        c += wallPool(q) * rockSurf(q, tr).alb * 2.0 * (1.0 - smoothstep(40.0, 260.0, tr) * 0.75);
        tHit = tr;
    }
    if (d.y < 0.0) { tHit = min(tHit, -eye.y / min(d.y, -1e-4)); }
    let lw = lightWall(eye, d);
    if (lw.w < tHit) { c = lw.rgb; }
    return vec4f(studioLights(eye, d, c), 1.0);
}

// Backdrop: the studio traced from the real camera (sharp, correct parallax), behind everything.
struct VSky { @builtin(position) pos: vec4f, @location(0) ndc: vec2f, };

@vertex
fn vs_sky(@builtin(vertex_index) vi: u32) -> VSky {
    var o: VSky;
    let x = f32((vi << 1u) & 2u);
    let y = f32(vi & 2u);
    o.pos = vec4f(x * 2.0 - 1.0, 1.0 - y * 2.0, 1.0, 1.0);
    o.ndc = o.pos.xy;
    return o;
}

// composite the reduced-resolution backdrop (p0.xy = 1 / full render size)
@fragment
fn fs_bgcomp(i: VSky) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    return vec4f(textureSampleLevel(tW0, samp, i.pos.xy * e.p0.xy, 0.0).rgb, 1.0);
}

@fragment
fn fs_sky(i: VSky) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let a = e.ivp * vec4f(i.ndc, 0.0, 1.0);
    let b = e.ivp * vec4f(i.ndc, 1.0, 1.0);
    let d = normalize(b.xyz / b.w - a.xyz / a.w);
    return vec4f(studio(e.cam.xyz, d) * e.cam.w, 1.0);
}

// Downsample: the bound view exposes only the previous mip, so lod 0 = that mip.
@fragment
fn fs_down(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let face = i32(e.p0.x + 0.5);
    let px = 0.25 / e.p0.z; // quarter texel of the destination mip, in uv
    var c = vec3f(0.0);
    c += textureSampleLevel(tSrc, samp, faceDir(face, i.uv + vec2f(-px, -px)), 0.0).rgb;
    c += textureSampleLevel(tSrc, samp, faceDir(face, i.uv + vec2f(px, -px)), 0.0).rgb;
    c += textureSampleLevel(tSrc, samp, faceDir(face, i.uv + vec2f(-px, px)), 0.0).rgb;
    c += textureSampleLevel(tSrc, samp, faceDir(face, i.uv + vec2f(px, px)), 0.0).rgb;
    return vec4f(c * 0.25, 1.0);
}

fn hammersley(i: u32, n: u32) -> vec2f {
    var b = i;
    b = (b << 16u) | (b >> 16u);
    b = ((b & 0x55555555u) << 1u) | ((b & 0xAAAAAAAAu) >> 1u);
    b = ((b & 0x33333333u) << 2u) | ((b & 0xCCCCCCCCu) >> 2u);
    b = ((b & 0x0F0F0F0Fu) << 4u) | ((b & 0xF0F0F0F0u) >> 4u);
    b = ((b & 0x00FF00FFu) << 8u) | ((b & 0xFF00FF00u) >> 8u);
    return vec2f(f32(i) / f32(n), f32(b) * 2.3283064365386963e-10);
}

fn importanceGGX(xi: vec2f, n: vec3f, a: f32) -> vec3f {
    let phi = 2.0 * PI * xi.x;
    let ct = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
    let st = sqrt(1.0 - ct * ct);
    let h = vec3f(cos(phi) * st, sin(phi) * st, ct);
    var up = vec3f(0.0, 0.0, 1.0);
    if (abs(n.z) > 0.999) { up = vec3f(1.0, 0.0, 0.0); }
    let tx = normalize(cross(up, n));
    let ty = cross(n, tx);
    return normalize(tx * h.x + ty * h.y + n * h.z);
}

fn dGGX(nh: f32, a: f32) -> f32 {
    let a2 = a * a;
    let d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

@fragment
fn fs_prefilter(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let n = faceDir(i32(e.p0.x + 0.5), i.uv);
    let rough = e.p0.y;
    let maxLod = e.p1.w - 1.0;
    if (rough < 0.001) {
        return vec4f(textureSampleLevel(tSrc, samp, n, 0.0).rgb, 1.0);
    }
    let a = rough * rough;
    let srcRes = e.p0.z;
    let saTexel = 4.0 * PI / (6.0 * srcRes * srcRes);
    let N: u32 = 96u;
    var acc = vec3f(0.0);
    var w = 0.0;
    for (var k = 0u; k < N; k++) {
        let h = importanceGGX(hammersley(k, N), n, a);
        let l = normalize(2.0 * dot(n, h) * h - n);
        let nl = dot(n, l);
        if (nl > 0.0) {
            let nh = max(dot(n, h), 0.0);
            let pdf = dGGX(nh, a) * 0.25;
            let saSample = 1.0 / (f32(N) * pdf + 1e-4);
            let lod = clamp(0.5 * log2(saSample / saTexel) + 1.0, 0.0, maxLod);
            acc += textureSampleLevel(tSrc, samp, l, lod).rgb * nl;
            w += nl;
        }
    }
    return vec4f(acc / max(w, 1e-4), 1.0);
}

fn gSmith(nv: f32, nl: f32, rough: f32) -> f32 {
    let k = rough * rough / 2.0;
    let gv = nv / (nv * (1.0 - k) + k);
    let gl = nl / (nl * (1.0 - k) + k);
    return gv * gl;
}

@fragment
fn fs_brdf(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let keep = e.p0.x * 0.0;
    let nv = max(i.uv.x, 1e-3);
    let rough = max(1.0 - i.uv.y, 0.02); // v=0 (top row) = rough 1
    let v = vec3f(sqrt(1.0 - nv * nv), 0.0, nv);
    let n = vec3f(0.0, 0.0, 1.0);
    let a = rough * rough;
    var A = 0.0;
    var B = 0.0;
    let N: u32 = 256u;
    for (var k = 0u; k < N; k++) {
        let h = importanceGGX(hammersley(k, N), n, a);
        let l = normalize(2.0 * dot(v, h) * h - v);
        let nl = max(l.z, 0.0);
        let nh = max(h.z, 0.0);
        let vh = max(dot(v, h), 0.0);
        if (nl > 0.0) {
            let g = gSmith(nv, nl, rough);
            let gv = g * vh / (nh * nv);
            let fc = pow(1.0 - vh, 5.0);
            A += (1.0 - fc) * gv;
            B += fc * gv;
        }
    }
    return vec4f(A / f32(N), B / f32(N), keep, 1.0);
}
