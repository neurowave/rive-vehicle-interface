// post.wgsl — bloom chain + filmic resolve to the canvas.
//
// fs_bright : HDR -> half-res, soft-knee threshold (first bloom level)
// fs_down   : 13-tap downsample (Jimenez, CoD:AW) for the remaining levels
// fs_up     : 9-tap tent upsample, blended additively into the next larger level
// fs_tone   : HDR + bloom -> ACES fit -> vignette -> grain -> sRGB canvas
// fs_down2d : plain 2x2 box for texture mip chains (tex.as) and reflection blur levels

struct P {
    p0: vec4f, // xy = 1 / source size, z = time, w = vignette
    p1: vec4f, // x = bloom threshold, y = knee, z = bloom strength, w = grain
    p2: vec4f, // x = chromatic aberration, y = exposure, zw = unused
};

@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var tSrc: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;
@group(0) @binding(3) var tBloom: texture_2d<f32>;

// Every fragment entry statically uses every binding of this file (`let keepLayoutUse = keepLayout();`), so the pipeline's
// auto layout is the same on every CLI: 1.6 bakes it from all the bindings a file declares, 1.7 from what each
// pipeline's entries use, and world.as mkBG binds all of them. No discard and no effect on the output.
fn keepLayout() -> f32 {
    let d = textureDimensions(tSrc).x + textureDimensions(tBloom).x;
    return f32(d) + textureSampleLevel(tSrc, samp, vec2f(0.0), 0.0).x + p.p0.x;
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

fn s(uv: vec2f) -> vec3f { return textureSampleLevel(tSrc, samp, uv, 0.0).rgb; }

fn uv0(uv: vec2f, d: vec2f, x: f32, y: f32) -> vec2f { return uv + d * vec2f(x, y); }

fn down13(uv: vec2f) -> vec3f {
    let d = p.p0.xy;
    let a = s(uv + d * vec2f(-2.0, -2.0));
    let b = s(uv + d * vec2f(0.0, -2.0));
    let c = s(uv + d * vec2f(2.0, -2.0));
    let dd = s(uv + d * vec2f(-2.0, 0.0));
    let e = s(uv);
    let f = s(uv + d * vec2f(2.0, 0.0));
    let g = s(uv + d * vec2f(-2.0, 2.0));
    let h = s(uv + d * vec2f(0.0, 2.0));
    let i = s(uv + d * vec2f(2.0, 2.0));
    let j = s(uv + d * vec2f(-1.0, -1.0));
    let k = s(uv + d * vec2f(1.0, -1.0));
    let l = s(uv + d * vec2f(-1.0, 1.0));
    let m = s(uv + d * vec2f(1.0, 1.0));
    return e * 0.125 + (a + c + g + i) * 0.03125 + (b + dd + f + h) * 0.0625 + (j + k + l + m) * 0.125;
}

@fragment
fn fs_bright(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let c = min(down13(i.uv), vec3f(64.0));
    let br = max(c.r, max(c.g, c.b));
    let t = p.p1.x;
    let knee = p.p1.y;
    var soft = clamp(br - t + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    let w = max(soft, br - t) / max(br, 1e-4);
    return vec4f(c * w, 1.0);
}

@fragment
fn fs_down(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    return vec4f(down13(i.uv), 1.0);
}

@fragment
fn fs_up(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let d = p.p0.xy;
    var c = s(uv0(i.uv, d, -1.0, -1.0)) + s(uv0(i.uv, d, 1.0, -1.0)) + s(uv0(i.uv, d, -1.0, 1.0)) + s(uv0(i.uv, d, 1.0, 1.0));
    c += 2.0 * (s(uv0(i.uv, d, 0.0, -1.0)) + s(uv0(i.uv, d, 0.0, 1.0)) + s(uv0(i.uv, d, -1.0, 0.0)) + s(uv0(i.uv, d, 1.0, 0.0)));
    c += 4.0 * s(i.uv);
    return vec4f(c / 16.0, 1.0);
}

@fragment
fn fs_down2d(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    return textureSampleLevel(tSrc, samp, i.uv, 0.0);
}

fn rrtOdt(v: vec3f) -> vec3f {
    let a = v * (v + 0.0245786) - 0.000090537;
    let b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

fn aces(c: vec3f) -> vec3f {
    let i = mat3x3<f32>(
        vec3f(0.59719, 0.07600, 0.02840),
        vec3f(0.35458, 0.90834, 0.13383),
        vec3f(0.04823, 0.01566, 0.83777));
    let o = mat3x3<f32>(
        vec3f(1.60475, -0.10208, -0.00327),
        vec3f(-0.53108, 1.10813, -0.07276),
        vec3f(-0.07367, -0.00605, 1.07602));
    return clamp(o * rrtOdt(i * c), vec3f(0.0), vec3f(1.0));
}

@fragment
fn fs_tone(i: VOut) -> @location(0) vec4f {
    let keepLayoutUse = keepLayout();
    let d = i.uv - vec2f(0.5);
    let ca = p.p2.x * dot(d, d);
    var c = vec3f(
        textureSampleLevel(tSrc, samp, i.uv - d * ca, 0.0).r,
        textureSampleLevel(tSrc, samp, i.uv, 0.0).g,
        textureSampleLevel(tSrc, samp, i.uv + d * ca, 0.0).b);
    // camera motion blur along the frame's screen-space sweep (p2.zw, uv units)
    let mb = p.p2.zw;
    if (dot(mb, mb) > 1e-7) {
        var acc = vec3f(0.0);
        let jit = fract(sin(dot(i.pos.xy, vec2f(12.9898, 78.233))) * 43758.5453) / 14.0;
        for (var k = 0; k < 14; k++) {
            let t = (f32(k) / 14.0 + jit) - 0.5;
            acc += textureSampleLevel(tSrc, samp, i.uv + mb * t, 0.0).rgb;
        }
        c = acc / 14.0;
    }
    let bloom = textureSampleLevel(tBloom, samp, i.uv, 0.0).rgb;
    // bloom off (p1.z = 0): skip the never-written chain entirely (uninitialised float texels can be NaN)
    if (p.p1.z > 0.0) { c = c + bloom * p.p1.z; }
    c *= p.p2.y;
    c *= 1.0 - p.p0.w * dot(d, d) * 1.6;
    c = aces(c);
    c = pow(c, vec3f(1.0 / 2.2));
    let n = fract(sin(dot(i.pos.xy + vec2f(p.p0.z * 37.0, p.p0.z * 11.0), vec2f(12.9898, 78.233))) * 43758.5453);
    c += (n - 0.5) * p.p1.w;
    return vec4f(c, 1.0);
}
