// world.as — the showroom renderer (AnimaScript).
//
// Physically based, image-based lighting on the GPU:
//   * Studio environment rendered into a cube (env.wgsl), mip chain + GGX prefilter + BRDF LUT.
//   * Hero car from the mesh pack (carpack.as, assets/car.bin), per-material PBR (car.wgsl): clearcoat
//     flake paint, chrome, satin metal, whitewall tyres, emissive lenses, glass.
//   * Floor: planar reflection (mirrored car pass, blurred mip chain) + soft contact shadow from an
//     orthographic height map rendered from below.
//   * 4x MSAA rgba16float HDR, bloom chain, ACES resolve (post.wgsl).

import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Artboard } from "rive/artboard";
import { ViewModel, PropertyNumber, PropertyString } from "rive/data";
import { Canvas } from "rive/canvas";
import { Color } from "rive/color";
import { PointerEvent, KeyboardEvent, ScrollEvent } from "rive/events";
import { ImageSampler, ImageWrap, ImageFilter } from "rive/image";
import { BlendMode, Paint, PaintStyle, StrokeCap, StrokeJoin } from "rive/paint";
import { Path } from "rive/path";
import { Mat2D } from "rive/mat2d";
import { Mat4 } from "rive/mat4";
import { Vector } from "rive/vector";
import {
    GPUBindGroup, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBlendState, GPUBuffer,
    GPUCanvas, GPUColorAttachment, GPUColorTargetDesc, GPUDepthStencilDesc, GPUPassDesc, GPUPipeline,
    GPUPipelineDesc, GPUSampler, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
    GPUVertexAttribute, GPUVertexBufferLayout, GPUShaderModule, GPUBindGroupLayout, GPURenderPass,
} from "rive/gpu";
import {
    BlendFactor, BufferUsage, CompareFunction, CullMode, Filter, IndexFormat, LoadOp, 
    StoreOp, TextureAspect, TextureFormat, TextureType, TextureViewDimension, VertexFormat, WrapMode,
} from "rive/gpu_enums";
import { CarMesh, CarPack, CarReader, openCar } from "./carpack";
import { MipTex } from "./tex";

const ENV_SIZE: u32 = 512;   // crisper paint reflections
const FROST_LEVELS: i32 = 4;
const LED_W: u32 = 1860;
const LED_H: u32 = 360;
const ENV_MIPS: u32 = 6;
const HM_SIZE: u32 = 3072;   // rock heightmap texels per side over 348 m (0.11 m): the 0.25 m bump octave only loses silhouette detail
const SKY_CUBE: u32 = 512;
const RB_N: u32 = 2048;      // skyline-bound bins round the horizon (0.18 deg)   // sky + mountains cube for the lake reflection / haze (rippled and blended: 0.18 deg/texel is plenty)
const LUT_SIZE: u32 = 128;
const UBO_SIZE: u32 = 480;
const MSAA: u32 = 4;
const HGT_SIZE: u32 = 1024;
const REFL_MIPS: u32 = 5;
const BLOOM_LEVELS: i32 = 6;
const PI: f64 = Math.PI;
const ENV_UBO: u32 = 288;
const WALLS: i32 = 5;
const WALL_W: f64 = 8.4;
const WALL_H: f64 = 5.6;
const WALL_ART_W: f64 = 600;
const WALL_ART_H: f64 = 780;
const WALL_SCALE: f64 = 2.0;
const WALL_R: f64 = 12.5;
const WALL_Y: f64 = 2.95;
const KEY_LEFT: f64 = 263;
const KEY_RIGHT: f64 = 262;
const KEY_K: f64 = 75;
const KEY_L: f64 = 76;
const KEY_B: f64 = 66;
const KEY_R: f64 = 82;
const KEY_D: f64 = 68;
const KEY_G: f64 = 71;
const KEY_Q: f64 = 81;
const KEY_N: f64 = 78;
const MEDIA_DIST: f64 = 10.6;
// Navigate: high side-on view: car broadside on the right, the curved wall behind
const NAV_ANG: f64 = 1.6;
const NAV_DIST: f64 = 11.3;
const NAV_HGT: f64 = 4.4;
const NAV_TY: f64 = 0.35;
const NAV_FOV: f64 = 36;
const MEDIA_LENS: f64 = 0.5;
// backdrop (sky, mountains, lake, rocks, LED wall) resolution in device pixels per point: 1.5 on Retina,
// composited under the full-res car / floor / UI. Softer background, about half the backdrop cost. Q toggles.
const BG_RES: f64 = 1.5;
const PANEL_D: f64 = 2.0;
const PANEL_COLS: i32 = 32;
// Visor (Flightlab-style): the top bar and dock are wrapped onto a cylinder around the camera. VISOR_TAN is the
// tangent of the visor's half-angle across the screen width (more = stronger bow); VISOR_INSET pulls the bars
// toward the middle so their ends, which rise / fall with the curve, stay on screen.
const VISOR_TAN: f64 = 0.45;
const VISOR_INSET: f64 = 0.9;
// callouts: panel index, anchor in panel-artboard px (600 x 780), car point (pack frame), part normal (x, z)
// Vehicle panel (tools/callouts.json): FL tyre chip, RL tyre chip, charge-port marker, lock chip -> the car's
// left front wheel, left rear wheel, charge flap (rear wing) and driver's door
const CO_PANEL: StaticArray<i32> = [1, 1, 1, 1];
// anchors (panel px): FL chip bottom (drops below the drawing first: CO_DY), RL chip right edge, port marker
// right edge, lock chip right edge. The plan drawing is turned nose-left like the 3D car in this shot.
const CO_AX: StaticArray<f64> = [195.5, 442.5, 457, 333.5];
const CO_AY: StaticArray<f64> = [373.5, 356.5, 295, 250.5];
const CO_DY: StaticArray<f64> = [24, 0, 0, 0];
const CO_CX: StaticArray<f64> = [1.19, 1.19, 1.19, 1.17];
const CO_CY: StaticArray<f64> = [0.42, 0.42, 0.84, 0.92];
const CO_CZ: StaticArray<f64> = [1.35, -1.68, -1.24, 0.0];
const CO_NX: StaticArray<f64> = [1.0, 1.0, 1.0, 1.0];
const CO_NZ: StaticArray<f64> = [0.0, 0.0, -0.2, 0.0];
const PANEL_SAG: f64 = 0.0;      // own bend (fraction of card width); 0 now that the visor lens bends the cards
// Rest pose on the visor: no own yaw (the lens supplies the curve), a touch smaller since a frontal card is wider
const PANEL_REST_YAW: f64 = 0.0;
const PANEL_SCALE: f64 = 0.88;
const F_HGT: bool = true;
const F_REFL: bool = true;
const F_CAR: bool = true;
const F_FLOOR: bool = true;
const F_GLASS: bool = true;
const F_BLOOM: bool = true;
const F_TEX: bool = true;

// ---------------------------------------------------------------- helpers
function colorTarget(fmt: TextureFormat): GPUColorTargetDesc {
    let c = new GPUColorTargetDesc();
    c.format = fmt;
    return c;
}

function blendTarget(fmt: TextureFormat, src: BlendFactor, dst: BlendFactor): GPUColorTargetDesc {
    let c = new GPUColorTargetDesc();
    c.format = fmt;
    let b = new GPUBlendState();
    b.srcColor = src;
    b.dstColor = dst;
    b.srcAlpha = src;
    b.dstAlpha = dst;
    c.blend = b;
    return c;
}

function attachment(view: GPUTextureView?, resolve: GPUTextureView?, load: LoadOp, r: f32, g: f32, b: f32, a: f32): GPUColorAttachment {
    let c = new GPUColorAttachment();
    c.view = view;
    c.resolveTarget = resolve;
    c.loadOp = load;
    c.storeOp = resolve != null ? StoreOp.discard : StoreOp.store;
    c.clearR = r;
    c.clearG = g;
    c.clearB = b;
    c.clearA = a;
    return c;
}

function tex2d(w: u32, h: u32, fmt: TextureFormat, samples: u32, mips: u32 = 1): GPUTexture {
    let d = new GPUTextureDesc();
    d.width = w;
    d.height = h;
    d.format = fmt;
    d.renderTarget = true;
    d.sampleCount = samples;
    d.numMipmaps = mips;
    return new GPUTexture(d);
}

function cubeTex(size: u32, mips: u32): GPUTexture {
    let d = new GPUTextureDesc();
    d.width = size;
    d.height = size;
    d.depthOrArrayLayers = 6;
    d.textureType = TextureType.cube;
    d.format = TextureFormat.rgba16float;
    d.renderTarget = true;
    d.numMipmaps = mips;
    return new GPUTexture(d);
}

function faceView(t: GPUTexture, face: u32, mip: u32): GPUTextureView {
    let d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.texture2D;
    d.baseMipLevel = mip;
    d.mipCount = 1;
    d.baseLayer = face;
    d.layerCount = 1;
    return t.view(d);
}

function mipView(t: GPUTexture, mip: u32, count: u32): GPUTextureView {
    let d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.texture2D;
    d.baseMipLevel = mip;
    d.mipCount = count;
    return t.view(d);
}

function cubeView(t: GPUTexture, baseMip: u32, count: u32): GPUTextureView {
    let d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.cube;
    d.baseMipLevel = baseMip;
    d.mipCount = count;
    d.baseLayer = 0;
    d.layerCount = 6;
    return t.view(d);
}

function clamp(x: f64, a: f64, b: f64): f64 {
    return x < a ? a : (x > b ? b : x);
}

function smooth(x: f64): f64 {
    let t = clamp(x, 0, 1);
    return t * t * (3 - 2 * t);
}

// Intro approach: the same cubic ease-in as easeInOut, but the ease-out is a long quintic tail. C1 join at
// x = 0.35 (A x^3 = 1 - B (1-x)^5 with matching slope): it gets going like the original move, then spends
// the last ~half of the flight settling slowly into the shot.
function easeGlide(x: f64): f64 {
    let t = clamp(x, 0, 1);
    let p = 0.35;
    let q = 1 - p;
    let A = 1 / (p * p * p + 0.6 * p * p * q);
    let B = 3 * A * p * p / (5 * q * q * q * q);
    return t < p ? A * t * t * t : 1 - B * Math.pow(1 - t, 5);
}

// ray (a -> c, panel-local space) against the curved card z = PANEL_SAG * (2x)^2 (fixed-point on the plane hit)
function curveHitT(a: Vector, c: Vector): f64 {
    let dz = <f64>(c.z - a.z);
    let t = -<f64>a.z / dz;
    for (let i = 0; i < 4; i++) {
        let x = <f64>a.x + <f64>(c.x - a.x) * t;
        let zt = PANEL_SAG * 4.0 * x * x;
        t = (zt - <f64>a.z) / dz;
    }
    return t;
}

function easeInOut(x: f64): f64 {
    let t = clamp(x, 0, 1);
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

function v3(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

// ---------------------------------------------------------------- materials
class Mat {
    mode: f64 = 0; // 0 std, 2 glass, 3 paint, 4 lens, 5 tyre
    r: f64 = 0.5;
    g: f64 = 0.5;
    b: f64 = 0.5;
    metal: f64 = 0;
    rough: f64 = 0.5;
    coat: f64 = 0;
    coatRough: f64 = 0.03;
    flake: f64 = 0;
    tex: string = "";
    bump: string = "";
    tileU: f64 = 1;
    tileV: f64 = 1;
    texMix: f64 = 1;
    bumpS: f64 = 0;
    ao: f64 = 1;
    er: f64 = 0;
    eg: f64 = 0;
    eb: f64 = 0;
    tint: f64 = 0;
    glass: bool = false;
    lights: f64 = 0; // emissive scales with the car's light state
}

function mat(r: f64, g: f64, b: f64, metal: f64, rough: f64): Mat {
    let m = new Mat();
    m.r = r;
    m.g = g;
    m.b = b;
    m.metal = metal;
    m.rough = rough;
    return m;
}

// Materials for the car pack (assets/car.bin, written by tools/export_car.py). Mesh names are material
// names; "W_" = on a wheel (spins).

function paint(): Mat {
    // mineral silver metallic under a mirror clearcoat (reads the lime wall like the reference car)
    let m = mat(0.5, 0.52, 0.54, 0.65, 0.32);
    m.mode = 3;
    m.coat = 1;
    m.coatRough = 0.02;
    m.flake = 0.1;   // finer: 0.22 read as sparkly noise on the bumper at hero distance
    return m;
}

function bronze(): Mat {
    return mat(0.66, 0.45, 0.24, 1, 0.14);
}

function glass(r: f64, g: f64, b: f64, tint: f64): Mat {
    let m = mat(r, g, b, 0, 0.02);
    m.mode = 2;
    m.glass = true;
    m.tint = tint;
    return m;
}

function emit(r: f64, g: f64, b: f64, er: f64, eg: f64, eb: f64): Mat {
    let m = mat(r, g, b, 0, 0.2);
    m.er = er;
    m.eg = eg;
    m.eb = eb;
    m.lights = 1;
    return m;
}

// "21.5" / "21.0": cabin temperatures step in half degrees
function celsius(v: f64): string {
    let h = <i32>Math.round(v * 2);
    return (h / 2).toString() + "." + (h % 2 == 1 ? "5" : "0");
}

function matFor(name: string): Mat {
    if (name == "CarPaint") {
        return paint();
    }
    if (name == "MetallicBlack02") {
        // gloss black second colour: roof, sills, mirror caps, cowl
        let m = mat(0.018, 0.018, 0.02, 0, 0.1);
        m.coat = 0.6;
        m.coatRough = 0.03;
        return m;
    }
    if (name == "Caliper") {
        return bronze();
    }
    if (name == "MetallicGray") {
        return mat(0.28, 0.28, 0.29, 0.85, 0.3);
    }
    if (name == "Mirror") {
        return mat(0.92, 0.92, 0.94, 1, 0.02);
    }
    if (name == "Interior") {
        return mat(0.045, 0.043, 0.042, 0, 0.6);
    }
    if (name == "InteriorAccent") {
        // carmine leather seats and door cards
        return mat(0.22, 0.03, 0.025, 0, 0.5);
    }
    if (name == "Rubber") {
        // gaskets, wipers, frames
        return mat(0.025, 0.025, 0.027, 0, 0.7);
    }
    if (name == "BottomCar") {
        return mat(0.02, 0.02, 0.02, 0, 0.85);
    }
    if (name == "GlassBlack") {
        return glass(0.02, 0.02, 0.025, 0.22);
    }
    if (name == "GlassAmber") {
        return glass(0.6, 0.28, 0.02, 0.35);
    }
    if (name == "Light") {
        return emit(0.9, 0.92, 0.95, 6.0, 6.3, 7.2);
    }
    if (name == "LightRed") {
        return emit(0.5, 0.02, 0.02, 7.0, 0.18, 0.08);
    }
    if (name == "NumberPlate") {
        let m = mat(1, 1, 1, 0, 0.35);
        m.tex = "t_plate";
        return m;
    }
    if (name == "W_TireColor") {
        return mat(0.022, 0.022, 0.024, 0, 0.85);
    }
    if (name == "W_MetallicBlack02") {
        // rim body: dark polished "black chrome" under a clear coat
        let m = mat(0.09, 0.09, 0.1, 1, 0.1);
        m.coat = 0.8;
        m.coatRough = 0.03;
        return m;
    }
    if (name == "W_WheelFace") {
        // machined titanium rim lip and spoke details
        let m = mat(0.70, 0.71, 0.73, 1, 0.12);
        m.coat = 0.6;
        m.coatRough = 0.03;
        return m;
    }
    if (name == "W_Disc") {
        return mat(0.6, 0.6, 0.62, 1, 0.32);
    }
    return mat(0.3, 0.3, 0.3, 0, 0.5);
}

// ---------------------------------------------------------------- draws
class Draw {
    mesh: CarMesh;
    mat: Mat;
    ubo: GPUBuffer? = null;
    uboR: GPUBuffer? = null;
    uboH: GPUBuffer? = null;
    bg: GPUBindGroup? = null;
    bgR: GPUBindGroup? = null;
    bgH: GPUBindGroup? = null;

    constructor(mesh: CarMesh, mat: Mat) {
        this.mesh = mesh;
        this.mat = mat;
    }
}

class FloorMesh {
    vbuf: GPUBuffer? = null;
    ibuf: GPUBuffer? = null;
    count: u32 = 6;
}

// ---------------------------------------------------------------- the layout
// A comic panel: a live Rive artboard rendered into a canvas and hung in the 3D space.
class Wall {
    inst: Artboard? = null;
    canvas: Canvas? = null;
    view: GPUTextureView? = null;
    ang: f64 = 0; // position angle around the car (from +Z toward +X)
    yaw: f64 = 0;
    cx: f64 = 0;
    cy: f64 = WALL_Y;
    cz: f64 = 0;
    power: f64 = 0;
    p: f64 = 0;   // presence spring (0 hidden .. 1 on screen)
    pv: f64 = 0;
    ww: f64 = 1;  // world size of the quad
    wh: f64 = 1;
    model: Mat4 = Mat4.identity();
    invModel: Mat4 = Mat4.identity();
    uboU: GPUBuffer? = null;
    bgU: GPUBindGroup? = null;
    ubo: GPUBuffer? = null;
    uboR: GPUBuffer? = null;
    bg: GPUBindGroup? = null;
    bgR: GPUBindGroup? = null;
}

export class Showroom extends Layout {
    @input wall0: Artboard? = null;
    @input wall1: Artboard? = null;
    @input wall2: Artboard? = null;
    @input wall3: Artboard? = null;
    @input wall4: Artboard? = null;
    @input visor: Artboard? = null; // top bar + dock, wrapped onto a curved visor (fs_visor)
    @input led: Artboard? = null;   // LED wall motion graphics (sampled by env.wgsl and the floor)
    walls: Array<Wall> = [];
    wallPipe: GPUPipeline? = null;
    wallPipeR: GPUPipeline? = null;
    uiPipe: GPUPipeline? = null;
    lens: f64 = 0;
    lensFrom: f64 = 0;
    invView: Mat4 = Mat4.identity();
    wallVB: GPUBuffer? = null;
    wallIB: GPUBuffer? = null;
    wallIdx: u32 = 6;

    // view model
    vmN: Map<string, PropertyNumber> = new Map<string, PropertyNumber>();
    vmS: Map<string, PropertyString> = new Map<string, PropertyString>();
    vmMissing: Set<string> = new Set<string>();

    // director: sections, camera flights, intro
    section: i32 = -1;
    introT: f64 = 0;
    flyT: f64 = 1;
    flyDur: f64 = 1.5;
    flyGlide: bool = false;   // intro approach: long-glide ease
    fromEx: f64 = 4;
    fromEy: f64 = 3.4;
    fromEz: f64 = 5;
    fromTx: f64 = 0;
    fromTy: f64 = 1;
    fromTz: f64 = 0;
    fromFov: f64 = 40;
    tx: f64 = 0;
    ty: f64 = 1;
    tz: f64 = 0;
    boostT: f64 = 0;
    boostOn: bool = false;
    beaconOn: bool = false;
    discoOn: bool = false;
    lightsOn: bool = true;
    tempL: f64 = 21.5;
    tempR: f64 = 21.0;
    hoverWall: i32 = -1;
    up: f64 = 0;
    shake: f64 = 0;
    discoHue: f64 = 0;
    driveMode: i32 = 0;
    // mouse: panel capture, orbit, zoom
    capture: i32 = -1;
    orbitMode: i32 = 0; // 0 idle, 1 pending (inside slop), 2 orbiting
    downX: f64 = 0;
    downY: f64 = 0;
    lastX: f64 = 0;
    lastY: f64 = 0;
    orbitYaw: f64 = 0;
    orbitPitch: f64 = 0;
    orbitZoom: f64 = 1;
    yawVel: f64 = 0;
    yawFrom: f64 = 0;
    zoomFrom: f64 = 1;
    songT: f64 = 102;
    fan: f64 = 3;

    context: Context? = null;
    gpu: GPUCanvas? = null;
    ready: bool = false;
    sizeX: f64 = 0;
    sizeY: f64 = 0;
    hostScale: f64 = 1;
    // graphics settings (Vehicle panel > Graphics; VM gfxQ / gfxBlur / gfxRefl / gfxBloom)
    gfxQ: i32 = 0;            // 0 high, 1 balanced, 2 fast
    gfxBlur: bool = true;
    gfxRefl: bool = true;
    gfxBloom: bool = true;
    dbgOff: i32 = 0;          // profiling switches (VM dbgOff bitmask, never set by the UI): see updateGfx
    gfxUser: bool = false;    // the user picked a quality: auto never overrides it
    perfAvg: f64 = 0;         // smoothed frame time (s)
    perfSlow: f64 = 0;        // seconds spent below ~30 fps
    perfHold: f64 = 0;        // settle time after an automatic step
    perfFast: f64 = 0;        // seconds spent comfortably fast (> ~55 fps)
    autoDown: i32 = 0;        // levels the auto mode has taken away (it gives them back when frames recover)
    autoUpAt: f64 = -100;     // time of the last automatic step back up
    autoLocked: bool = false; // stepped up, got slow again: stay at the lower level
    renderScale: f64 = 1;     // 3D render resolution (device px per point): Graphics quality lowers it
    outScale: f64 = 1;        // output canvas + UI (panels, visor): always full device resolution, so the vector UI stays crisp
    ow: u32 = 1;
    oh: u32 = 1;
    tw: u32 = 1;
    th: u32 = 1;
    time: f64 = 0;
    printed: bool = false;

    car: CarPack? = null;
    carReader: CarReader? = null;
    draws: Array<Draw> = [];
    glassDraws: Array<Draw> = [];
    floor: FloorMesh = new FloorMesh();
    floorUbo: GPUBuffer? = null;
    floorBG: GPUBindGroup? = null;
    texNames: Array<string> = ["t_plate"];
    texs: Map<string, MipTex> = new Map<string, MipTex>();
    texReadyCount: i32 = 0;
    bgDirty: bool = true;
    white: GPUTextureView? = null;
    // placeholders that complete bind groups (never rendered to): see mkBG
    fillUbo: GPUBuffer? = null;
    fill2D: GPUTextureView? = null;
    fillCube: GPUTextureView? = null;
    grey: GPUTextureView? = null;

    // samplers
    linSampler: GPUSampler? = null;
    texSampler: GPUSampler? = null;
    imgSampler: ImageSampler = ImageSampler(ImageWrap.clamp, ImageWrap.clamp, ImageFilter.bilinear);

    // environment
    srcCube: GPUTexture? = null;
    specCube: GPUTexture? = null;
    specView: GPUTextureView? = null;
    lutView: GPUTextureView? = null;
    envPipe: GPUPipeline? = null;
    envStaticPipe: GPUPipeline? = null;
    // static env cache: sky, mountains, rocks, lake, pad traced once (alpha codes what the live pass adds)
    staticPasses: Array<GPUPassDesc> = [];
    staticUbos: Array<GPUBuffer> = [];
    staticBGs: Array<GPUBindGroup> = [];
    staticDone: bool = false;
    envFrame: i32 = 0;
    staticView: GPUTextureView? = null;
    srcHalf: GPUTexture? = null;
    // sky + mountains only (no rocks, no studio), from the env eye: the backdrop's lake reflection and horizon
    // haze sample it instead of re-evaluating the mountain ranges for every lake pixel
    skyCubeView: GPUTextureView? = null;
    hmView: GPUTextureView? = null;      // baked rock heightmap (r16float, HM_SIZE^2 over HM_EXTENT m) for the backdrop marches
    hmPass: GPUPassDesc? = null;
    hmPipe: GPUPipeline? = null;
    hmBG: GPUBindGroup? = null;
    hmUbo: GPUBuffer? = null;
    hmDone: bool = false;
    rbView: GPUTextureView? = null;      // skyline bounds (RB_N x 4, r16float) for the backdrop's mountain early-out
    rbPass: GPUPassDesc? = null;
    rbPipe: GPUPipeline? = null;
    rbBG: GPUBindGroup? = null;
    rbUbo: GPUBuffer? = null;
    skyCubePipe: GPUPipeline? = null;
    skyCubePasses: Array<GPUPassDesc> = [];
    skyCubeUbos: Array<GPUBuffer> = [];
    skyCubeBGs: Array<GPUBindGroup> = [];
    reflHalf: GPUTexture? = null;
    downPipe: GPUPipeline? = null;
    prePipe: GPUPipeline? = null;
    brdfPipe: GPUPipeline? = null;
    envPasses: Array<GPUPassDesc> = [];
    envBGs: Array<GPUBindGroup> = [];
    envUbos: Array<GPUBuffer> = [];
    envKinds: Array<i32> = [];
    envFace: Array<f64> = [];
    envRough: Array<f64> = [];
    envSize: Array<f64> = [];
    lutPass: GPUPassDesc? = null;
    lutBG: GPUBindGroup? = null;
    envDirty: bool = true;
    lutDone: bool = false;
    wallI: f64 = 1.0;
    // light wall (env.wgsl WALL_*): intensity, and its centre / yaw for the floor pool
    wallLight: f64 = 1.2;   // LED wall brightness: bright enough to bloom and flood the ground
    pinFade: f64 = 0;
    // callouts: thin amber leader lines from a panel row to the car part it describes
    coPath: Path = new Path();
    coDots: Path = new Path();
    coLine: Paint = new Paint();
    coFill: Paint = new Paint();
    coT: f64 = 0;            // draw-on progress 0..1 for the current section
    coSec: i32 = -1;
    coN: i32 = 0;
    coAx: StaticArray<f64> = new StaticArray<f64>(4);
    coAy: StaticArray<f64> = new StaticArray<f64>(4);
    coBx: StaticArray<f64> = new StaticArray<f64>(4);
    coEx: StaticArray<f64> = new StaticArray<f64>(4);
    coEy: StaticArray<f64> = new StaticArray<f64>(4);
    coDx: StaticArray<f64> = new StaticArray<f64>(4);
    coDy: StaticArray<f64> = new StaticArray<f64>(4);
    coBy: StaticArray<f64> = new StaticArray<f64>(4);
    coVis: StaticArray<f64> = new StaticArray<f64>(4);
    ledInst: Artboard? = null;
    visorInst: Artboard? = null;
    // the visor (top bar + dock) is mostly still: re-render its canvas only while the artboard animates, after
    // input, a section change or a resize, and four times a second regardless (bound text such as the clock)
    visorLive: bool = true;
    visorForce: bool = true;
    visorDrawT: f64 = -1;
    visorDraws: i32 = 0;
    visorHoldT: f64 = -1;     // redraw every frame until this time: any input, VM write, section change or resize
    visorCanvas: Canvas? = null;
    visorView: GPUTextureView? = null;
    visorPipe: GPUPipeline? = null;
    visorUbo: GPUBuffer? = null;
    visorBG: GPUBindGroup? = null;
    visorCap: bool = false;
    visorHX: f64 = 0;
    visorHY: f64 = 0;
    flatX: f64 = 0;
    flatY: f64 = 0;
    ledCanvas: Canvas? = null;
    ledView: GPUTextureView? = null;
    ledClock: f64 = 0;
    logoAOn: bool = false;
    logoBOn: bool = false;
    stripI: f64 = 1.0;
    boxI: f64 = 1.0;

    // pipelines
    carPipe: GPUPipeline? = null;
    carPipeR: GPUPipeline? = null;
    glassPipe: GPUPipeline? = null;
    floorPipe: GPUPipeline? = null;
    skyPipe: GPUPipeline? = null;
    hgtPipe: GPUPipeline? = null;
    mip8Pipe: GPUPipeline? = null;
    mip16Pipe: GPUPipeline? = null;
    brightPipe: GPUPipeline? = null;
    bdownPipe: GPUPipeline? = null;
    bupPipe: GPUPipeline? = null;
    tonePipe: GPUPipeline? = null;

    // targets
    scenePass: GPUPassDesc? = null;
    hdrView: GPUTextureView? = null;
    hgtPass: GPUPassDesc? = null;
    hgtView: GPUTextureView? = null;
    hgtDirty: bool = true;
    reflPass: GPUPassDesc? = null;
    reflView: GPUTextureView? = null;
    reflMipPasses: Array<GPUPassDesc> = [];
    reflMipBGs: Array<GPUBindGroup> = [];
    bloomViews: Array<GPUTextureView> = [];
    bloomW: Array<f64> = [];
    bloomH: Array<f64> = [];
    bloomDownPasses: Array<GPUPassDesc> = [];
    bloomDownBGs: Array<GPUBindGroup> = [];
    bloomDownUbos: Array<GPUBuffer> = [];
    // frosted glass behind the UI panels: a plain 13-tap downsample chain of the HDR frame (no threshold)
    frostViews: Array<GPUTextureView> = [];
    frostW: Array<f64> = [];
    frostH: Array<f64> = [];
    frostPasses: Array<GPUPassDesc> = [];
    frostBGs: Array<GPUBindGroup> = [];
    frostUbos: Array<GPUBuffer> = [];
    bloomUpPasses: Array<GPUPassDesc> = [];
    bloomUpBGs: Array<GPUBindGroup> = [];
    bloomUpUbos: Array<GPUBuffer> = [];
    skyUbo: GPUBuffer? = null;
    skyPipeLo: GPUPipeline? = null;
    bgCompPipe: GPUPipeline? = null;
    skyBGLo: GPUBindGroup? = null;
    compUbo: GPUBuffer? = null;
    compBG: GPUBindGroup? = null;
    bgLoPass: GPUPassDesc? = null;
    bgLo: bool = true;
    // day / night (N): target and eased blend; the static env cache re-traces while the blend moves
    nightOn: bool = false;
    nightT: f64 = 0;
    nightK: f64 = 0;
    nightKDrawn: f64 = -1;
    skyBG: GPUBindGroup? = null;
    toneUbo: GPUBuffer? = null;
    toneBG: GPUBindGroup? = null;
    tonePass: GPUPassDesc? = null;

    // camera + car state
    view: Mat4 = Mat4.identity();
    proj: Mat4 = Mat4.identity();
    viewProj: Mat4 = Mat4.identity();
    viewProjR: Mat4 = Mat4.identity();
    invViewProj: Mat4 = Mat4.identity();
    mvp: Mat4 = Mat4.identity();
    carModel: Mat4 = Mat4.identity();
    wheelModels: Array<Mat4> = [Mat4.identity(), Mat4.identity(), Mat4.identity(), Mat4.identity(), Mat4.identity()];
    wheelSpin: f64 = 0;
    eyeX: f64 = 0;
    eyeY: f64 = 1;
    eyeZ: f64 = 6;
    exposure: f64 = 1.45;
    lights: f64 = 1.0;
    fov: f64 = 28;

    scratch: ArrayBuffer = new ArrayBuffer(512);
    wallCol: StaticArray<f64> = [1.0, 0.5, 0.06, 0.04, 0.18, 0.8, 0.9, 0.1, 0.05, 0.85, 0.8, 0.7, 0.3, 0.03, 0.03];
    sf: Float32Array = new Float32Array(0);

    log(s: string): void {
        let c = this.context;
        if (c != null) {
            c.log(s);
        }
    }

    v4(off: i32, a: f64, b: f64, c: f64, d: f64): void {
        let i = off >> 2;
        this.sf[i] = <f32>a;
        this.sf[i + 1] = <f32>b;
        this.sf[i + 2] = <f32>c;
        this.sf[i + 3] = <f32>d;
    }

    dbgN: i32 = 0;
    dbg(s: string): void {
        if (this.dbgN < 40) {
            this.dbgN++;
            this.log("dbg: " + s);
        }
    }

    rootVM(): ViewModel? {
        let ctx = this.context;
        if (ctx == null) {
            return null;
        }
        return ctx.rootViewModel();
    }

    propN(name: string): PropertyNumber? {
        if (this.vmN.has(name)) {
            return this.vmN.get(name);
        }
        if (this.vmMissing.has("n:" + name)) {
            return null;
        }
        let vm = this.rootVM();
        if (vm == null) {
            return null;
        }
        let q = vm.getNumber(name);
        if (q == null) {
            this.log("world: missing view-model number " + name);
            this.vmMissing.add("n:" + name);
            return null;
        }
        this.vmN.set(name, q);
        return q;
    }

    propS(name: string): PropertyString? {
        if (this.vmS.has(name)) {
            return this.vmS.get(name);
        }
        if (this.vmMissing.has("s:" + name)) {
            return null;
        }
        let vm = this.rootVM();
        if (vm == null) {
            return null;
        }
        let q = vm.getString(name);
        if (q == null) {
            this.log("world: missing view-model string " + name);
            this.vmMissing.add("s:" + name);
            return null;
        }
        this.vmS.set(name, q);
        return q;
    }

    getN(name: string, dflt: f64): f64 {
        let p = this.propN(name);
        return p != null ? p.value : dflt;
    }

    setN(name: string, v: f64): void {
        let p = this.propN(name);
        if (p != null && Math.abs(p.value - v) > 1e-6) {
            p.value = v;
        }
    }

    setS(name: string, v: string): void {
        let p = this.propS(name);
        if (p != null && p.value != v) {
            p.value = v;
        }
    }

    // Keep the visor canvas redrawing every frame for a moment after any interaction (pointer anywhere, keys,
    // section change, resize): it then behaves exactly like the always-redraw version while the user is
    // using it, and only drops to its idle rate (animating / 4 Hz) when nobody is touching anything.
    // (Not on VM writes: pins and the song progress change every frame and would hold it open forever.)
    visorPoke(): void {
        this.visorHoldT = this.time + 1.5;
    }

    wallInput(k: i32): Artboard? {
        if (k == 0) return this.wall0;
        if (k == 1) return this.wall1;
        if (k == 2) return this.wall2;
        if (k == 3) return this.wall3;
        return this.wall4;
    }

    makeWalls(): void {
        let ctx = this.context!;
        // around the car: STATUS back-left, TUNES back-right, CLIMATE left, NAVIGATE right, GADGETS ahead
        let angs: StaticArray<f64> = [-2.55, 2.55, -1.45, 1.45, 0.0];
        for (let k = 0; k < WALLS; k++) {
            let w = new Wall();
            w.ang = angs[k];
            w.yaw = w.ang + PI;
            w.cx = Math.sin(w.ang) * WALL_R;
            w.cz = Math.cos(w.ang) * WALL_R;
            let m = Mat4.fromTranslation(<f32>w.cx, <f32>w.cy, <f32>w.cz);
            Mat4.multiply(m, m, Mat4.fromRotationY(<f32>w.yaw));
            Mat4.multiply(m, m, Mat4.fromScale(<f32>WALL_W, <f32>WALL_H, 1));
            w.model = m;
            let input = this.wallInput(k);
            if (input != null) {
                let inst = input.instance(this.rootVM());
                inst.frameOrigin = true;
                w.inst = inst;
            }
            let c = ctx.canvas(<u32>(WALL_ART_W * WALL_SCALE), <u32>(WALL_ART_H * WALL_SCALE));
            w.canvas = c;
            if (c != null) {
                w.view = c.image.view();
            }
            w.ubo = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
            w.uboR = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
            w.uboU = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
            this.walls.push(w);
        }
        // LED wall: its own canvas at the artboard's native size (1860 x 360 = 18 x 3.5 m)
        let li = this.led;
        if (li != null) {
            let inst = li.instance(this.rootVM());
            inst.frameOrigin = true;
            this.ledInst = inst;
            let lc = ctx.canvas(LED_W, LED_H);
            this.ledCanvas = lc;
            if (lc != null) {
                this.ledView = lc.image.view();
            }
        }
        let vi = this.visor;
        if (vi != null) {
            let inst = vi.instance(this.rootVM());
            inst.frameOrigin = true;
            this.visorInst = inst;
            this.visorUbo = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
        }
        // unit quad, uv origin top-left, facing +Z
        // UI panel mesh: a strip of PANEL_COLS columns bent into a shallow cylinder (edges forward, toward the
        // viewer) so the cards echo the curved LED wall. Local x, y in -0.5..0.5; z = PANEL_SAG * (2x)^2, and the
        // model scales z by the panel width, so the sag is a fixed fraction of the card's width.
        let cols = PANEL_COLS;
        let fv = new Float32Array((cols + 1) * 2 * 8);
        for (let c = 0; c <= cols; c++) {
            let x = <f32>(<f64>c / <f64>cols - 0.5);
            let z = <f32>(PANEL_SAG * 4.0 * <f64>x * <f64>x);
            for (let r = 0; r < 2; r++) {
                let y: f32 = r == 0 ? 0.5 : -0.5;
                let o = (c * 2 + r) * 8;
                fv[o] = x;
                fv[o + 1] = y;
                fv[o + 2] = z;
                // normal of the bent card (z = sag*4x^2 scaled uniformly in x/z by the width): (-8 sag x, 0, 1)
                let nx = <f32>(-8.0 * PANEL_SAG * <f64>x);
                let nl = <f32>Math.sqrt(<f64>(nx * nx + 1));
                fv[o + 3] = nx / nl;
                fv[o + 4] = 0;
                fv[o + 5] = 1 / nl;
                fv[o + 6] = x + 0.5;
                fv[o + 7] = 0.5 - y;
            }
        }
        let fi = new Uint32Array(cols * 6);
        for (let c = 0; c < cols; c++) {
            let i0 = <u32>(c * 2);
            let o = c * 6;
            fi[o] = i0; fi[o + 1] = i0 + 2; fi[o + 2] = i0 + 3;
            fi[o + 3] = i0; fi[o + 4] = i0 + 3; fi[o + 5] = i0 + 1;
        }
        this.wallIdx = <u32>(cols * 6);
        this.wallVB = new GPUBuffer(BufferUsage.vertex, <u32>fv.byteLength, fv.buffer, true);
        this.wallIB = new GPUBuffer(BufferUsage.index, <u32>fi.byteLength, fi.buffer, true);
    }

    setLogo(name: string, on: bool): void {
        let ctx = this.context;
        if (ctx == null) {
            return;
        }
        let vm = ctx.rootViewModel();
        if (vm == null) {
            return;
        }
        let lp = vm.getViewModel(name);
        if (lp == null) {
            return;
        }
        let b = lp.value.getBoolean("showLogo");
        if (b != null) {
            b.value = on;
        }
    }

    ledViewOr(): GPUTextureView {
        let v = this.ledView;
        return v != null ? v : this.white!;
    }

    wallView(k: i32): GPUTextureView {
        if (k < this.walls.length) {
            let v = this.walls[k].view;
            if (v != null) {
                return v;
            }
        }
        return this.white!;
    }

    override init(context: Context): bool {
        this.context = context;
        this.sf = Float32Array.wrap(this.scratch);
        let b = context.blob("car");
        if (b != null) {
            let rd = openCar(b);
            if (rd != null) {
                this.carReader = rd;
                this.car = rd.pack;
                this.log("car: " + rd.count.toString() + " meshes (streaming)");
            } else {
                this.log("car: bad pack");
            }
        } else {
            this.log("car: blob missing (assets/car.bin)");
        }

        for (let i = 0; i < this.texNames.length; i++) {
            let t = new MipTex(this.texNames[i]);
            t.start(context);
            this.texs.set(this.texNames[i], t);
        }
        return true;
    }

    // Parse a few meshes of the car pack per frame (see CarReader). Meshes parsed after the GPU exists
    // are uploaded and given their uniform buffers here; earlier ones are handled by createGPU.
    streamCar(budget: i32): void {
        let rd = this.carReader;
        if (rd == null || rd.done()) {
            return;
        }
        for (let n = 0; n < budget && !rd.done(); n++) {
            let m = rd.read();
            let d = new Draw(m, matFor(m.name));
            if (d.mat.glass) {
                this.glassDraws.push(d);
            } else {
                this.draws.push(d);
            }
            if (this.gpu != null) {
                m.upload();
                d.ubo = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
                d.uboR = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
                d.uboH = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
                this.bgDirty = true;
                // the contact-shadow height map is cached: re-render it with every streamed mesh, otherwise a
                // live session (which draws before the car finishes streaming) keeps an empty map forever
                this.hgtDirty = true;
            }
        }
        if (rd.done()) {
            this.hgtDirty = true;
            this.log("car: loaded " + rd.pack.meshes.length.toString() + " meshes");
        }
    }

    // ------------------------------------------------------------ setup
    createGPU(): bool {
        let ctx = this.context!;
        let gpu = ctx.gpuCanvas();
        if (gpu == null) {
            return false;
        }
        this.gpu = gpu;
        this.linSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge,
            WrapMode.clampToEdge);
        this.texSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.repeat,
            WrapMode.repeat, <CompareFunction>0xFFFFFFFF, 8);
        let car = this.car;
        if (car != null) {
            for (let i = 0; i < car.meshes.length; i++) {
                car.meshes[i].upload();
            }
        }
        let all = this.allDraws();
        for (let i = 0; i < all.length; i++) {
            all[i].ubo = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
            all[i].uboR = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
            all[i].uboH = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
        }
        this.floorUbo = new GPUBuffer(BufferUsage.uniform, UBO_SIZE);
        this.skyUbo = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
        this.compUbo = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
        this.toneUbo = new GPUBuffer(BufferUsage.uniform, 48);
        // floor quad
        let fv = new Float32Array(32);
        let xs: StaticArray<f32> = [-1, 1, 1, -1];
        let zs: StaticArray<f32> = [-1, -1, 1, 1];
        for (let i = 0; i < 4; i++) {
            let o = i * 8;
            fv[o] = xs[i] * 60;
            fv[o + 1] = 0;
            fv[o + 2] = zs[i] * 60;
            fv[o + 3] = 0;
            fv[o + 4] = 1;
            fv[o + 5] = 0;
            fv[o + 6] = xs[i] * 0.5 + 0.5;
            fv[o + 7] = zs[i] * 0.5 + 0.5;
        }
        let fi = new Uint32Array(6);
        fi[0] = 0; fi[1] = 2; fi[2] = 1; fi[3] = 0; fi[4] = 3; fi[5] = 2;
        this.floor.vbuf = new GPUBuffer(BufferUsage.vertex, <u32>fv.byteLength, fv.buffer, true);
        this.floor.ibuf = new GPUBuffer(BufferUsage.index, <u32>fi.byteLength, fi.buffer, true);
        // fallback textures
        this.white = tex2d(1, 1, TextureFormat.rgba8unorm, 1).view();
        this.fillUbo = new GPUBuffer(BufferUsage.uniform, 1024);
        this.fill2D = tex2d(1, 1, TextureFormat.rgba16float, 1).view();
        this.fillCube = cubeView(cubeTex(1, 1), 0, 1);
        this.grey = this.white;
        this.makeWalls();
        return true;
    }

    allDraws(): Array<Draw> {
        let a: Array<Draw> = [];
        for (let i = 0; i < this.draws.length; i++) {
            a.push(this.draws[i]);
        }
        for (let i = 0; i < this.glassDraws.length; i++) {
            a.push(this.glassDraws[i]);
        }
        return a;
    }

    fullPipe(module: GPUShaderModule, vs: string, fs: string, fmt: TextureFormat): GPUPipeline {
        let d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.vertexEntryPoint = vs;
        d.fragmentModule = module;
        d.fragmentEntryPoint = fs;
        d.colorTargets = [colorTarget(fmt)];
        return new GPUPipeline(d);
    }

    carLayout(): GPUVertexBufferLayout {
        let l = new GPUVertexBufferLayout();
        l.stride = 20;
        l.attributes = [
            new GPUVertexAttribute(VertexFormat.sint16x4, 0, 0),
            new GPUVertexAttribute(VertexFormat.snorm16x2, 1, 8),
            new GPUVertexAttribute(VertexFormat.unorm16x2, 2, 12),
            new GPUVertexAttribute(VertexFormat.unorm8x4, 3, 16),
        ];
        return l;
    }

    depth(write: bool): GPUDepthStencilDesc {
        let ds = new GPUDepthStencilDesc();
        ds.format = TextureFormat.depth32float;
        ds.compare = CompareFunction.lessEqual;
        ds.write = write;
        return ds;
    }

    // Bind group with every slot of its shader MODULE filled. CLI 1.7 (strict WebGPU validation) derives a
    // pipeline's layout from all the bindings the module declares and rejects a group that leaves any empty
    // ("the bind group leaves this texture empty"); WebGL silently drops a draw whose shader references an
    // unbound texture. Gaps get 1x1 placeholders. mod: 0 env.wgsl (cube 1, 2D 3-7), 1 car.wgsl (cube 1,
    // 2D 3-6), 2 post.wgsl (2D 1, 3). Every module has its UBO at 0 and its sampler at 2.
    mkBG(layout: GPUBindGroupLayout, ubos: Array<GPUBindGroupUBO>, texs: Array<GPUBindGroupTexture>,
        samps: Array<GPUBindGroupSampler>, mod: i32): GPUBindGroup {
        let u = ubos.length > 0 ? ubos : [new GPUBindGroupUBO(0, this.fillUbo!)];
        let s = samps.length > 0 ? samps : [new GPUBindGroupSampler(2, this.linSampler!)];
        let t: Array<GPUBindGroupTexture> = [];
        for (let i = 0; i < texs.length; i++) {
            t.push(texs[i]);
        }
        let hi: u32 = mod == 0 ? 7 : (mod == 1 ? 6 : 3);
        for (let slot: u32 = 1; slot <= hi; slot++) {
            if (slot == 2) {
                continue;
            }
            let have = false;
            for (let i = 0; i < t.length; i++) {
                if (t[i].slot == slot) {
                    have = true;
                }
            }
            if (have) {
                continue;
            }
            let cube = slot == 1 && mod != 2;
            t.push(new GPUBindGroupTexture(slot, cube ? this.fillCube! : this.fill2D!));
        }
        return new GPUBindGroup(layout, u, t, s);
    }

    makePipelines(): bool {
        let ctx = this.context!;
        let envS = ctx.shader("env");
        let carS = ctx.shader("car");
        let postS = ctx.shader("post");
        if (envS == null || carS == null || postS == null) {
            this.log("showroom: shader missing");
            return false;
        }
        let hf = TextureFormat.rgba16float;
        this.envPipe = this.fullPipe(envS, "vs_full", "fs_env", hf);
        this.envStaticPipe = this.fullPipe(envS, "vs_full", "fs_env_static", hf);
        this.skyCubePipe = this.fullPipe(envS, "vs_full", "fs_skycube", hf);
        this.hmPipe = this.fullPipe(envS, "vs_full", "fs_rockhm", TextureFormat.r16float);
        this.rbPipe = this.fullPipe(envS, "vs_full", "fs_ridgeb", TextureFormat.r16float);
        this.downPipe = this.fullPipe(envS, "vs_full", "fs_down", hf);
        this.prePipe = this.fullPipe(envS, "vs_full", "fs_prefilter", hf);
        this.brdfPipe = this.fullPipe(envS, "vs_full", "fs_brdf", hf);
        this.mip8Pipe = this.fullPipe(postS, "vs_full", "fs_down2d", TextureFormat.rgba8unorm);
        this.mip16Pipe = this.fullPipe(postS, "vs_full", "fs_down2d", hf);
        this.brightPipe = this.fullPipe(postS, "vs_full", "fs_bright", hf);
        this.bdownPipe = this.fullPipe(postS, "vs_full", "fs_down", hf);
        let up = new GPUPipelineDesc();
        up.vertexModule = postS;
        up.vertexEntryPoint = "vs_full";
        up.fragmentModule = postS;
        up.fragmentEntryPoint = "fs_up";
        up.colorTargets = [blendTarget(hf, BlendFactor.one, BlendFactor.one)];
        this.bupPipe = new GPUPipeline(up);
        let gpu = this.gpu!;
        this.tonePipe = this.fullPipe(postS, "vs_full", "fs_tone", <TextureFormat>gpu.format);

        // car (MSAA main pass, and 1x reflection pass)
        let cd = new GPUPipelineDesc();
        cd.vertexModule = carS;
        cd.vertexEntryPoint = "vs_car";
        cd.fragmentModule = carS;
        cd.fragmentEntryPoint = "fs_car";
        cd.vertexBuffers = [this.carLayout()];
        cd.colorTargets = [colorTarget(hf)];
        cd.depthStencil = this.depth(true);
        cd.cullMode = CullMode.none;
        cd.sampleCount = MSAA;
        this.carPipe = new GPUPipeline(cd);
        let cr = new GPUPipelineDesc();
        cr.vertexModule = carS;
        cr.vertexEntryPoint = "vs_car";
        cr.fragmentModule = carS;
        cr.fragmentEntryPoint = "fs_car";
        cr.vertexBuffers = [this.carLayout()];
        cr.colorTargets = [colorTarget(hf)];
        cr.depthStencil = this.depth(true);
        cr.cullMode = CullMode.none;
        cr.sampleCount = 1;
        this.carPipeR = new GPUPipeline(cr);
        // glass (premultiplied over)
        let gd = new GPUPipelineDesc();
        gd.vertexModule = carS;
        gd.vertexEntryPoint = "vs_car";
        gd.fragmentModule = carS;
        gd.fragmentEntryPoint = "fs_glass";
        gd.vertexBuffers = [this.carLayout()];
        gd.colorTargets = [blendTarget(hf, BlendFactor.one, BlendFactor.oneMinusSrcAlpha)];
        gd.depthStencil = this.depth(false);
        gd.cullMode = CullMode.none;
        gd.sampleCount = MSAA;
        this.glassPipe = new GPUPipeline(gd);
        // height (contact shadow) pass
        let hd = new GPUPipelineDesc();
        hd.vertexModule = carS;
        hd.vertexEntryPoint = "vs_hgt";
        hd.fragmentModule = carS;
        hd.fragmentEntryPoint = "fs_hgt";
        hd.vertexBuffers = [this.carLayout()];
        hd.colorTargets = [colorTarget(hf)];
        hd.depthStencil = this.depth(true);
        hd.cullMode = CullMode.none;
        this.hgtPipe = new GPUPipeline(hd);
        // floor
        let fl = new GPUVertexBufferLayout();
        fl.stride = 32;
        fl.attributes = [
            new GPUVertexAttribute(VertexFormat.float3, 0, 0),
            new GPUVertexAttribute(VertexFormat.float3, 1, 12),
            new GPUVertexAttribute(VertexFormat.float2, 2, 24),
        ];
        let fd = new GPUPipelineDesc();
        fd.vertexModule = carS;
        fd.vertexEntryPoint = "vs_floor";
        fd.fragmentModule = carS;
        fd.fragmentEntryPoint = "fs_floor";
        fd.vertexBuffers = [fl];
        fd.colorTargets = [colorTarget(hf)];
        fd.depthStencil = this.depth(true);
        fd.cullMode = CullMode.none;
        fd.sampleCount = MSAA;
        this.floorPipe = new GPUPipeline(fd);
        // comic walls (lightboxes): main MSAA + reflection
        for (let r = 0; r < 2; r++) {
            let wd = new GPUPipelineDesc();
            wd.vertexModule = carS;
            wd.vertexEntryPoint = "vs_floor";
            wd.fragmentModule = carS;
            wd.fragmentEntryPoint = "fs_wall";
            wd.vertexBuffers = [fl];
            wd.colorTargets = [colorTarget(hf)];
            wd.depthStencil = this.depth(true);
            wd.cullMode = CullMode.none;
            wd.sampleCount = r == 0 ? MSAA : 1;
            if (r == 0) {
                this.wallPipe = new GPUPipeline(wd);
            } else {
                this.wallPipeR = new GPUPipeline(wd);
            }
        }
        // UI panels composited over the graded frame (premultiplied)
        let ud = new GPUPipelineDesc();
        ud.vertexModule = carS;
        ud.vertexEntryPoint = "vs_ui";
        ud.fragmentModule = carS;
        ud.fragmentEntryPoint = "fs_ui";
        ud.vertexBuffers = [fl];
        ud.colorTargets = [blendTarget(<TextureFormat>gpu.format, BlendFactor.one, BlendFactor.oneMinusSrcAlpha)];
        ud.cullMode = CullMode.none;
        this.uiPipe = new GPUPipeline(ud);
        // visor: full-screen pass that wraps the top bar + dock canvas onto a cylinder around the camera
        let vd = new GPUPipelineDesc();
        vd.vertexModule = carS;
        vd.vertexEntryPoint = "vs_sky";
        vd.fragmentModule = carS;
        vd.fragmentEntryPoint = "fs_visor";
        vd.colorTargets = [blendTarget(<TextureFormat>gpu.format, BlendFactor.one, BlendFactor.oneMinusSrcAlpha)];
        vd.cullMode = CullMode.none;
        this.visorPipe = new GPUPipeline(vd);
        // backdrop
        let sd = new GPUPipelineDesc();
        sd.vertexModule = envS;
        sd.vertexEntryPoint = "vs_sky";
        sd.fragmentModule = envS;
        sd.fragmentEntryPoint = "fs_sky";
        sd.colorTargets = [colorTarget(hf)];
        sd.depthStencil = this.depth(false);
        sd.sampleCount = MSAA;
        this.skyPipe = new GPUPipeline(sd);
        // reduced-resolution backdrop: traced into its own target, then composited behind the depth-tested scene
        let sl = new GPUPipelineDesc();
        sl.vertexModule = envS;
        sl.vertexEntryPoint = "vs_sky";
        sl.fragmentModule = envS;
        sl.fragmentEntryPoint = "fs_sky";
        sl.colorTargets = [colorTarget(hf)];
        this.skyPipeLo = new GPUPipeline(sl);
        let bcd = new GPUPipelineDesc();
        bcd.vertexModule = envS;
        bcd.vertexEntryPoint = "vs_sky";
        bcd.fragmentModule = envS;
        bcd.fragmentEntryPoint = "fs_bgcomp";
        bcd.colorTargets = [colorTarget(hf)];
        bcd.depthStencil = this.depth(false);
        bcd.sampleCount = MSAA;
        this.bgCompPipe = new GPUPipeline(bcd);
        return true;
    }

    makeEnv(): void {
        let src = cubeTex(ENV_SIZE, ENV_MIPS);
        let spec = cubeTex(ENV_SIZE, ENV_MIPS);
        this.srcCube = src;
        this.specCube = spec;
        this.specView = cubeView(spec, 0, ENV_MIPS);
        let lut = tex2d(LUT_SIZE, LUT_SIZE, TextureFormat.rgba16float, 1);
        this.lutView = lut.view();
        let samp = this.linSampler!;
        let srcAll = cubeView(src, 0, ENV_MIPS);
        let hmT = tex2d(HM_SIZE, HM_SIZE, TextureFormat.r16float, 1);
        this.hmView = hmT.view();
        let hp = new GPUPassDesc();
        hp.color = [attachment(this.hmView!, null, LoadOp.clear, 0, 0, 0, 1)];
        this.hmPass = hp;
        this.hmUbo = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
        this.hmBG = this.mkBG(this.hmPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.hmUbo!)], [], [], 0);
        let rbT = tex2d(RB_N, 4, TextureFormat.r16float, 1);
        this.rbView = rbT.view();
        let rp0 = new GPUPassDesc();
        rp0.color = [attachment(this.rbView!, null, LoadOp.clear, 0, 0, 0, 1)];
        this.rbPass = rp0;
        this.rbUbo = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
        this.rbBG = this.mkBG(this.rbPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.rbUbo!)], [], [], 0);
        let stat = cubeTex(ENV_SIZE, 1);
        this.staticView = cubeView(stat, 0, 1);
        for (let f: u32 = 0; f < 6; f++) {
            let sp = new GPUPassDesc();
            sp.color = [attachment(faceView(stat, f, 0), null, LoadOp.clear, 0, 0, 0, 0)];
            this.staticPasses.push(sp);
            let su = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
            this.staticUbos.push(su);
            // studioStatic reaches rockHM (binding 3) and the skyline bound (binding 4): WebGL drops a draw whose
            // shader references an unbound texture, which left the static cube (car reflections) and the sky
            // cube (lake) black on the web while Metal tolerated it
            this.staticBGs.push(this.mkBG(this.envStaticPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, su)],
                [new GPUBindGroupTexture(3, this.hmView!), new GPUBindGroupTexture(4, this.rbView!)], [new GPUBindGroupSampler(2, samp)], 0));
        }
        let skyT = cubeTex(SKY_CUBE, 1);
        this.skyCubeView = cubeView(skyT, 0, 1);
        for (let f: u32 = 0; f < 6; f++) {
            let kp = new GPUPassDesc();
            kp.color = [attachment(faceView(skyT, f, 0), null, LoadOp.clear, 0, 0, 0, 1)];
            this.skyCubePasses.push(kp);
            let ku = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
            this.skyCubeUbos.push(ku);
            this.skyCubeBGs.push(this.mkBG(this.skyCubePipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ku)],
                [new GPUBindGroupTexture(4, this.rbView!)], [new GPUBindGroupSampler(2, samp)], 0));
        }
        for (let f: u32 = 0; f < 6; f++) {
            this.addEnvPass(0, faceView(src, f, 0), f, 0, ENV_SIZE, null, samp);
        }
        // Mip chain without reading and writing one texture in the same pass (a feedback loop WebGL2 rejects,
        // which left every rough mip black on the web): downsample mip m-1 into a half-size scratch cube, then
        // copy that back into mip m (fs_down with a huge size = four taps on one point = an exact copy).
        let half = cubeTex(ENV_SIZE >> 1, ENV_MIPS - 1);
        this.srcHalf = half;
        for (let m: u32 = 1; m < ENV_MIPS; m++) {
            let prev = cubeView(src, m - 1, 1);
            let tmp = cubeView(half, m - 1, 1);
            for (let f: u32 = 0; f < 6; f++) {
                this.addEnvPass(1, faceView(half, f, m - 1), f, 0, ENV_SIZE >> m, prev, samp);
            }
            for (let f: u32 = 0; f < 6; f++) {
                this.addEnvPass(1, faceView(src, f, m), f, 0, <u32>1000000, tmp, samp);
            }
        }
        for (let m: u32 = 0; m < ENV_MIPS; m++) {
            let rough = <f64>m / <f64>(ENV_MIPS - 1);
            for (let f: u32 = 0; f < 6; f++) {
                this.addEnvPass(2, faceView(spec, f, m), f, rough, ENV_SIZE, srcAll, samp);
            }
        }
        let lp = new GPUPassDesc();
        lp.color = [attachment(this.lutView, null, LoadOp.clear, 0, 0, 0, 1)];
        this.lutPass = lp;
        let lubo = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
        this.lutBG = this.mkBG(this.brdfPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, lubo)], [], [], 0);
    }

    addEnvPass(kind: i32, target: GPUTextureView, face: u32, rough: f64, size: u32, srcView: GPUTextureView?,
        samp: GPUSampler): void {
        let p = new GPUPassDesc();
        p.color = [attachment(target, null, LoadOp.clear, 0, 0, 0, 1)];
        this.envPasses.push(p);
        let ubo = new GPUBuffer(BufferUsage.uniform, ENV_UBO);
        this.envUbos.push(ubo);
        this.envKinds.push(kind);
        this.envFace.push(<f64>face);
        this.envRough.push(rough);
        this.envSize.push(<f64>size);
        let pipe = kind == 0 ? this.envPipe! : (kind == 1 ? this.downPipe! : this.prePipe!);
        let bg: GPUBindGroup;
        if (kind == 0) {
            bg = this.mkBG(pipe.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)], [
                new GPUBindGroupTexture(1, this.staticView!),
                new GPUBindGroupTexture(3, this.wallView(0)),
                new GPUBindGroupTexture(4, this.wallView(1)),
                new GPUBindGroupTexture(5, this.wallView(2)),
                new GPUBindGroupTexture(6, this.wallView(3)),
                new GPUBindGroupTexture(7, this.ledViewOr()),
            ], [new GPUBindGroupSampler(2, samp)], 0);
        } else if (srcView == null) {
            bg = this.mkBG(pipe.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)], [], [], 0);
        } else {
            let sv: GPUTextureView = srcView;
            bg = this.mkBG(pipe.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
                [new GPUBindGroupTexture(1, sv)], [new GPUBindGroupSampler(2, samp)], 0);
        }
        this.envBGs.push(bg);
    }

    texView(name: string, fallback: GPUTextureView): GPUTextureView {
        if (name.length == 0 || !this.texs.has(name)) {
            return fallback;
        }
        let t = this.texs.get(name);
        let v = t.view;
        if (t.ready && v != null) {
            return v;
        }
        return fallback;
    }

    rebuildDrawBGs(): void {
        let carPipe = this.carPipe;
        if (carPipe == null || this.specView == null || this.hgtView == null) {
            return;
        }
        let spec = this.specView!;
        let lutV = this.lutView!;
        let white = this.white!;
        let layout = carPipe.getBindGroupLayout(0);
        let layoutR = this.carPipeR!.getBindGroupLayout(0);
        let layoutG = this.glassPipe!.getBindGroupLayout(0);
        let layoutH = this.hgtPipe!.getBindGroupLayout(0);
        let all = this.allDraws();
        for (let i = 0; i < all.length; i++) {
            let d = all[i];
            let a = this.texView(d.mat.tex, white);
            let b = this.texView(d.mat.bump, white);
            if (d.mat.glass) {
                d.bg = this.mkBG(layoutG, [new GPUBindGroupUBO(0, d.ubo!)], [
                    new GPUBindGroupTexture(1, spec),
                    new GPUBindGroupTexture(3, lutV),
                ], [new GPUBindGroupSampler(2, this.texSampler!)], 1);
            } else {
                d.bg = this.drawBG(layout, d.ubo!, spec, lutV, a, b);
            }
            d.bgR = this.drawBG(layoutR, d.uboR!, spec, lutV, a, b);
            d.bgH = this.mkBG(layoutH, [new GPUBindGroupUBO(0, d.uboH!)], [], [], 1);
        }
        // the floor also samples the LED wall (binding 6): its mirror image and coloured light pools
        this.floorBG = this.mkBG(this.floorPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.floorUbo!)], [
            new GPUBindGroupTexture(1, spec),
            new GPUBindGroupTexture(3, lutV),
            new GPUBindGroupTexture(4, this.reflView!),
            new GPUBindGroupTexture(5, this.hgtView!),
            new GPUBindGroupTexture(6, this.ledViewOr()),
        ], [new GPUBindGroupSampler(2, this.texSampler!)], 1);
        for (let k = 0; k < this.walls.length; k++) {
            let w = this.walls[k];
            let wv = this.wallView(k);
            w.bg = this.mkBG(this.wallPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, w.ubo!)],
                [new GPUBindGroupTexture(4, wv)], [new GPUBindGroupSampler(2, this.linSampler!)], 1);
            w.bgR = this.mkBG(this.wallPipeR!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, w.uboR!)],
                [new GPUBindGroupTexture(4, wv)], [new GPUBindGroupSampler(2, this.linSampler!)], 1);
            let frost = this.frostViews.length > 3 ? this.frostViews[3] : this.white!;   // 1/16: a deeper frost
            w.bgU = this.mkBG(this.uiPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, w.uboU!)],
                [new GPUBindGroupTexture(1, spec), new GPUBindGroupTexture(4, wv), new GPUBindGroupTexture(5, frost)],
                [new GPUBindGroupSampler(2, this.linSampler!)], 1);
        }
        let vv = this.visorView;
        if (vv != null && this.visorPipe != null && this.visorUbo != null) {
            let vfrost = this.frostViews.length > 3 ? this.frostViews[3] : this.white!;
            this.visorBG = this.mkBG(this.visorPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.visorUbo!)],
                [new GPUBindGroupTexture(1, spec), new GPUBindGroupTexture(4, vv), new GPUBindGroupTexture(5, vfrost)],
                [new GPUBindGroupSampler(2, this.linSampler!)], 1);
        }
        this.skyBG = this.mkBG(this.skyPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.skyUbo!)], [
            new GPUBindGroupTexture(1, this.skyCubeView!),
            new GPUBindGroupTexture(3, this.hmView!),
            new GPUBindGroupTexture(4, this.rbView!),
            new GPUBindGroupTexture(5, this.wallView(2)),
            new GPUBindGroupTexture(6, this.wallView(3)),
            new GPUBindGroupTexture(7, this.ledViewOr()),
        ], [new GPUBindGroupSampler(2, this.linSampler!)], 0);
        this.skyBGLo = this.mkBG(this.skyPipeLo!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.skyUbo!)], [
            new GPUBindGroupTexture(1, this.skyCubeView!),
            new GPUBindGroupTexture(3, this.hmView!),
            new GPUBindGroupTexture(4, this.rbView!),
            new GPUBindGroupTexture(5, this.wallView(2)),
            new GPUBindGroupTexture(6, this.wallView(3)),
            new GPUBindGroupTexture(7, this.ledViewOr()),
        ], [new GPUBindGroupSampler(2, this.linSampler!)], 0);
        this.bgDirty = false;
    }

    drawBG(layout: GPUBindGroupLayout, ubo: GPUBuffer, spec: GPUTextureView, lutV: GPUTextureView,
        a: GPUTextureView, b: GPUTextureView): GPUBindGroup {
        return this.mkBG(layout, [new GPUBindGroupUBO(0, ubo)], [
            new GPUBindGroupTexture(1, spec),
            new GPUBindGroupTexture(3, lutV),
            new GPUBindGroupTexture(4, a),
            new GPUBindGroupTexture(5, b),
        ], [new GPUBindGroupSampler(2, this.texSampler!)], 1);
    }

    rebuildTargets(): void {
        let gpu = this.gpu!;
        // High: full device resolution (up to 2x). Balanced: 3/4. Fast: half (never under 0.6 px per point).
        let hs = Math.min(this.hostScale, 2.0);
        this.renderScale = this.gfxQ == 0 ? hs : (this.gfxQ == 1 ? hs * 0.75 : Math.max(hs * 0.5, Math.min(hs, 0.6)));
        let w = <u32>Math.max(1, Math.floor(this.sizeX * this.renderScale));
        let h = <u32>Math.max(1, Math.floor(this.sizeY * this.renderScale));
        this.tw = w;
        this.th = h;
        // Only the 3D (scene, backdrop, reflections, bloom, frost) renders at renderScale. The output canvas
        // stays at full device resolution: the resolve pass upsamples the 3D frame into it, then the glass
        // panels and the visor (vector UI) are composited at full res, so Balanced / Fast keep a crisp UI.
        this.outScale = hs;
        this.ow = <u32>Math.max(1, Math.floor(this.sizeX * hs));
        this.oh = <u32>Math.max(1, Math.floor(this.sizeY * hs));
        gpu.resize(this.ow, this.oh);
        let hf = TextureFormat.rgba16float;
        let msaa = tex2d(w, h, hf, MSAA).view();
        let hdr = tex2d(w, h, hf, 1).view();
        let dv = new GPUTextureViewDesc();
        dv.aspect = TextureAspect.depthOnly;
        let depth = tex2d(w, h, TextureFormat.depth32float, MSAA).view(dv);
        this.hdrView = hdr;
        let sp = new GPUPassDesc();
        sp.color = [attachment(msaa, hdr, LoadOp.clear, 0, 0, 0, 1)];
        sp.depthView = depth;
        sp.depthLoadOp = LoadOp.clear;
        sp.depthStoreOp = StoreOp.discard;
        sp.depthClearValue = 1;
        this.scenePass = sp;
        // reduced-resolution backdrop target (BG_RES device px per point, never above the main render)
        let bgs = Math.min(1.0, (this.gfxQ == 0 ? BG_RES : (this.gfxQ == 1 ? 1.0 : 0.7)) / this.renderScale);
        let bgW = <u32>Math.max(1, Math.floor(<f64>w * bgs));
        let bgH = <u32>Math.max(1, Math.floor(<f64>h * bgs));
        let bgt = tex2d(bgW, bgH, hf, 1).view();
        let bp = new GPUPassDesc();
        bp.color = [attachment(bgt, null, LoadOp.clear, 0, 0, 0, 1)];
        this.bgLoPass = bp;
        this.compBG = this.mkBG(this.bgCompPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.compUbo!)],
            [new GPUBindGroupTexture(3, bgt)], [new GPUBindGroupSampler(2, this.linSampler!)], 0);

        // contact-shadow height map (once)
        if (this.hgtView == null) {
            let ht = tex2d(HGT_SIZE, HGT_SIZE, hf, 1);
            this.hgtView = ht.view();
            let hdep = tex2d(HGT_SIZE, HGT_SIZE, TextureFormat.depth32float, 1).view(dv);
            let hp = new GPUPassDesc();
            hp.color = [attachment(this.hgtView, null, LoadOp.clear, 99, 0, 0, 1)];
            hp.depthView = hdep;
            hp.depthLoadOp = LoadOp.clear;
            hp.depthStoreOp = StoreOp.discard;
            hp.depthClearValue = 1;
            this.hgtPass = hp;
        }

        // planar reflection: half resolution with a blur mip chain
        let rw = <u32>Math.max(1, w / 2);
        let rh = <u32>Math.max(1, h / 2);
        let rt = tex2d(rw, rh, hf, 1, REFL_MIPS);
        this.reflView = mipView(rt, 0, REFL_MIPS);
        let rdep = tex2d(rw, rh, TextureFormat.depth32float, 1).view(dv);
        let rp = new GPUPassDesc();
        rp.color = [attachment(mipView(rt, 0, 1), null, LoadOp.clear, 0, 0, 0, 0)];
        rp.depthView = rdep;
        rp.depthLoadOp = LoadOp.clear;
        rp.depthStoreOp = StoreOp.discard;
        rp.depthClearValue = 1;
        this.reflPass = rp;
        this.reflMipPasses = [];
        this.reflMipBGs = [];
        // blur chain via a half-size scratch (never sample the texture being rendered: WebGL2 feedback loop):
        // mip m-1 -> scratch level m-1 (2x box), then scratch -> mip m (same size: an exact bilinear copy)
        let rtH = tex2d(<u32>Math.max(1, rw / 2), <u32>Math.max(1, rh / 2), hf, 1, REFL_MIPS - 1);
        this.reflHalf = rtH;
        for (let m: u32 = 1; m < REFL_MIPS; m++) {
            let pd = new GPUPassDesc();
            pd.color = [attachment(mipView(rtH, m - 1, 1), null, LoadOp.clear, 0, 0, 0, 0)];
            this.reflMipPasses.push(pd);
            this.reflMipBGs.push(this.mkBG(this.mip16Pipe!.getBindGroupLayout(0), [],
                [new GPUBindGroupTexture(1, mipView(rt, m - 1, 1))], [new GPUBindGroupSampler(2, this.linSampler!)], 2));
            let pc = new GPUPassDesc();
            pc.color = [attachment(mipView(rt, m, 1), null, LoadOp.clear, 0, 0, 0, 0)];
            this.reflMipPasses.push(pc);
            this.reflMipBGs.push(this.mkBG(this.mip16Pipe!.getBindGroupLayout(0), [],
                [new GPUBindGroupTexture(1, mipView(rtH, m - 1, 1))], [new GPUBindGroupSampler(2, this.linSampler!)], 2));
        }

        // bloom chain
        this.bloomViews = [];
        this.bloomW = [];
        this.bloomH = [];
        let bw = w;
        let bh = h;
        for (let k = 0; k < BLOOM_LEVELS; k++) {
            bw = <u32>Math.max(1, bw / 2);
            bh = <u32>Math.max(1, bh / 2);
            this.bloomViews.push(tex2d(bw, bh, hf, 1).view());
            this.bloomW.push(<f64>bw);
            this.bloomH.push(<f64>bh);
        }
        this.bloomDownPasses = [];
        this.bloomDownBGs = [];
        this.bloomDownUbos = [];
        for (let k = 0; k < BLOOM_LEVELS; k++) {
            let p = new GPUPassDesc();
            p.color = [attachment(this.bloomViews[k], null, LoadOp.clear, 0, 0, 0, 1)];
            this.bloomDownPasses.push(p);
            let ubo = new GPUBuffer(BufferUsage.uniform, 48);
            this.bloomDownUbos.push(ubo);
            let srcV = k == 0 ? hdr : this.bloomViews[k - 1];
            let pipe = k == 0 ? this.brightPipe! : this.bdownPipe!;
            this.bloomDownBGs.push(this.mkBG(pipe.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
                [new GPUBindGroupTexture(1, srcV)], [new GPUBindGroupSampler(2, this.linSampler!)], 2));
        }
        this.bloomUpPasses = [];
        this.bloomUpBGs = [];
        this.bloomUpUbos = [];
        for (let k = BLOOM_LEVELS - 1; k > 0; k--) {
            let p = new GPUPassDesc();
            p.color = [attachment(this.bloomViews[k - 1], null, LoadOp.load, 0, 0, 0, 1)];
            this.bloomUpPasses.push(p);
            let ubo = new GPUBuffer(BufferUsage.uniform, 48);
            this.bloomUpUbos.push(ubo);
            this.bloomUpBGs.push(this.mkBG(this.bupPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
                [new GPUBindGroupTexture(1, this.bloomViews[k])], [new GPUBindGroupSampler(2, this.linSampler!)], 2));
        }

        // frost chain: 1/2 .. 1/16 of the frame, sampled at 1/8 behind the panels
        this.frostViews = [];
        this.frostW = [];
        this.frostH = [];
        this.frostPasses = [];
        this.frostBGs = [];
        this.frostUbos = [];
        let fw = w;
        let fh = h;
        for (let k = 0; k < FROST_LEVELS; k++) {
            fw = <u32>Math.max(1, fw / 2);
            fh = <u32>Math.max(1, fh / 2);
            this.frostViews.push(tex2d(fw, fh, hf, 1).view());
            this.frostW.push(<f64>fw);
            this.frostH.push(<f64>fh);
            let p = new GPUPassDesc();
            p.color = [attachment(this.frostViews[k], null, LoadOp.clear, 0, 0, 0, 1)];
            this.frostPasses.push(p);
            let ubo = new GPUBuffer(BufferUsage.uniform, 48);
            this.frostUbos.push(ubo);
            let srcV = k == 0 ? hdr : this.frostViews[k - 1];
            this.frostBGs.push(this.mkBG(this.bdownPipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
                [new GPUBindGroupTexture(1, srcV)], [new GPUBindGroupSampler(2, this.linSampler!)], 2));
        }

        let tp = new GPUPassDesc();
        tp.color = [attachment(null, null, LoadOp.clear, 0, 0, 0, 1)];
        this.tonePass = tp;
        this.toneBG = this.mkBG(this.tonePipe!.getBindGroupLayout(0), [new GPUBindGroupUBO(0, this.toneUbo!)],
            [new GPUBindGroupTexture(1, hdr), new GPUBindGroupTexture(3, this.bloomViews[0])],
            [new GPUBindGroupSampler(2, this.linSampler!)], 2);
        // visor canvas at output (full) resolution; the artboard is laid out at the stage's point size
        let vinst = this.visorInst;
        let vctx = this.context;
        if (vinst != null && vctx != null) {
            vinst.width = this.sizeX;
            vinst.height = this.sizeY;
            let vc = vctx.canvas(this.ow, this.oh);
            this.visorCanvas = vc;
            this.visorForce = true;
            this.visorPoke();
            this.visorView = vc != null ? vc.image.view() : null;
        }
        this.bgDirty = true;
    }

    trySetup(): void {
        if (this.context == null || this.sizeX <= 0) {
            return;
        }
        if (!this.ready) {
            if (!this.createGPU()) {
                if (!this.printed) {
                    this.log("showroom: waiting for GPU");
                    this.printed = true;
                }
                return;
            }
            if (!this.makePipelines()) {
                return;
            }
            this.makeEnv();
            this.ready = true;
        }
        this.rebuildTargets();
    }

    override resize(width: f64, height: f64, scale: f64): void {
        this.sizeX = width;
        this.sizeY = height;
        this.hostScale = scale;
        this.trySetup();
    }

    // ------------------------------------------------------------ director
    // Shot for a section: the camera stands on the far side of the car from that section's wall, so
    // the car sits in the foreground and the comic panel hangs behind it (the Eletre composition).
    // Shots: car as hero in the 2/3 opposite the panel. out = eye xyz, target xyz, fov, lens.
    shotEye(k: i32, t: f64, out: StaticArray<f64>): void {
        let drift = Math.sin(t * 0.13) * 0.06;
        if (k < 0 || k >= 5) {
            let a = 0.4 + t * 0.07;
            out[0] = Math.sin(a) * 9.5;
            out[1] = 4.2;
            out[2] = Math.cos(a) * 9.5;
            out[3] = 0;
            out[4] = 0.4;
            out[5] = 0;
            out[6] = 36;
            out[7] = 0;
            return;
        }
        // angle round the car (0 = straight ahead of the nose, +X = car's left), distance, height, target y, fov
        // every shot keeps the light wall (behind the car's rear-left, ~2.59 rad) in the background:
        // camera angles stay within about +-60 deg of the opposite direction (-0.55 rad)
        // The curved LED wall stands off the car's right/rear-right (env.wgsl WALL_AZ = -1.37, arc -2.19..-0.55),
        // so every camera works the car's left side (az 0.6..2.0) and never ends up behind the wall.
        // Opening shot (0): low front-left 3/4, nose to the left; the wall fills the left of frame and its
        // end cuts just behind the nose, the roof and tail sit against open sky under the Status panel.
        let ang: StaticArray<f64> = [0.6, 1.5, NAV_ANG, 1.05, 2.0];
        let dist: StaticArray<f64> = [9.6, 9.8, NAV_DIST, MEDIA_DIST, 9.4];   // stay well inside the island (shore >= 12.5 m)
        let hgt: StaticArray<f64> = [1.05, 1.25, NAV_HGT, 1.0, 0.85];
        let ty: StaticArray<f64> = [0.8, 0.7, NAV_TY, 0.75, 0.75];
        let fov: StaticArray<f64> = [33, 35, NAV_FOV, 32, 34];
        let a = ang[k] + drift;
        out[0] = Math.sin(a) * dist[k];
        out[1] = hgt[k] + Math.sin(t * 0.17) * 0.06;
        out[2] = Math.cos(a) * dist[k];
        out[3] = 0;
        out[4] = ty[k];
        out[5] = 0;
        out[6] = fov[k];
        // opening: car centre-left, the wall's end cutting behind the nose; Media pans further so the car
        // sits right of the panel and the LED wall's visualizer shows between them
        out[7] = k == 0 ? 0.0 : (k == 3 ? MEDIA_LENS : 0.36);
    }

    goSection(k: i32): void {
        if (k == this.section) {
            return;
        }
        this.flyGlide = false;   // the intro sets its own long-glide flight after this call
        this.flyDur = 1.5;
        this.fromEx = this.eyeX;
        this.fromEy = this.eyeY;
        this.fromEz = this.eyeZ;
        this.fromTx = this.tx;
        this.fromTy = this.ty;
        this.fromTz = this.tz;
        this.fromFov = this.fov;
        this.lensFrom = this.lens;
        // The from-pose above already includes the user's orbit / zoom / pitch (eyeX.. are the final camera).
        // Clear the orbit so it isn't applied a second time on top of the flight: that double rotation made
        // the camera snap at the start of a move whenever the user had orbited away from the shot.
        this.orbitYaw = 0;
        this.orbitZoom = 1;
        this.orbitPitch = 0;
        this.yawFrom = 0;
        this.zoomFrom = 1;
        this.yawVel = 0;
        this.flyT = 0;
        this.section = k;
        this.visorForce = true;
        this.visorPoke();
        this.setN("section", <f64>k);
        this.updateReadout();
    }

    updateReadout(): void {
        let names: StaticArray<string> = ["Status", "Vehicle", "Navigate", "Media", "Climate"];
        let k = this.section;
        let s = (k >= 0 && k < 5 ? names[k] : "Intro") + "  ·  Lights " + (this.lightsOn ? "on" : "off");
        if (this.boostOn) {
            s += "  ·  Boost";
        }
        if (this.discoOn) {
            s += "  ·  Welcome light";
        }
        if (this.gfxQ > 0) {
            s += this.gfxQ == 1 ? "  ·  Balanced graphics" : "  ·  Fast graphics";
        }
        this.setS("readout", s);
    }

    // Hotspot pins: project anchor points on the car to HUD coordinates (pin{k}x/y) and fade each pin
    // (pin{k}a) by how squarely its surface faces the camera, so pins on the far side never float
    // over the body. Anchors are in the car pack's frame: +x = car's left, +y up, +z forward.
    updatePins(): void {
        if (this.sizeX <= 0 || this.sizeY <= 0) {
            return;
        }
        this.pinFade += ((this.flyT >= 1 ? 1.0 : 0.0) - this.pinFade) * 0.12;
        // headlight, front wheel, charge flap (rear wing), cabin roof
        // all on the car's left (+x) side, which the cameras see
        let ax: StaticArray<f64> = [0.73, 1.19, 1.19, 0.0];
        let ay: StaticArray<f64> = [0.71, 0.42, 0.84, 1.25];
        let az: StaticArray<f64> = [2.13, 1.35, -1.24, -0.32];
        let nx: StaticArray<f64> = [0.4, 1.0, 1.0, 0.0];
        let ny: StaticArray<f64> = [0.1, 0.0, 0.1, 1.0];
        let nz: StaticArray<f64> = [0.9, 0.0, -0.2, 0.0];
        for (let k = 0; k < 4; k++) {
            let p = this.viewProj.transformPoint(<f32>ax[k], <f32>ay[k], <f32>az[k]);
            let sx = (<f64>p.x * 0.5 + 0.5) * this.sizeX;
            let sy = (0.5 - <f64>p.y * 0.5) * this.sizeY;
            let vx = this.eyeX - ax[k];
            let vy = this.eyeY - ay[k];
            let vz = this.eyeZ - az[k];
            let vl = Math.sqrt(vx * vx + vy * vy + vz * vz);
            let facing = (nx[k] * vx + ny[k] * vy + nz[k] * vz) / vl;
            let a = smooth(clamp((facing - 0.05) / 0.3, 0, 1));
            // hide pins that would sit under the side panel or off screen
            if (sx < 40 || sx > this.sizeX - 40 || sy < 70 || sy > this.sizeY - 110) {
                a = 0;
            }
            this.setN("pin" + k.toString() + "x", sx);
            this.setN("pin" + k.toString() + "y", sy);
            this.setN("pin" + k.toString() + "a", a * this.pinFade);
        }
    }

    // Callouts (panel row -> car part). Anchors are in panel-artboard px (tools/callouts.json); car points in
    // the car pack's frame (+x = car's left, +y up, +z forward). Computed in advance; drawn after the frame.
    updateCallouts(dt: f64): void {
        this.coN = 0;
        let k = this.section;
        if (k != this.coSec) {
            this.coSec = k;
            this.coT = 0;
        }
        if (k < 0 || k >= this.walls.length || this.sizeX <= 0) {
            return;
        }
        let w = this.walls[k];
        let ready = w.p > 0.97 && this.flyT >= 1;
        // the Vehicle panel's scroll offset (two-way bound ScrollConstraint.scrollOffsetY, <= 0 when scrolled down)
        let scrollY = k == 1 ? this.getN("vehScroll", 0) : 0.0;
        this.coT = ready ? Math.min(1, this.coT + dt / 0.9) : Math.max(0, this.coT - dt / 0.25);
        if (this.coT <= 0) {
            return;
        }
        let n = 0;
        for (let i = 0; i < CO_PANEL.length; i++) {
            if (CO_PANEL[i] != k || n >= 4) {
                continue;
            }
            // panel anchor on the curved card
            let ay = CO_AY[i] + scrollY;
            let lx = CO_AX[i] / WALL_ART_W - 0.5;
            let ly = 0.5 - ay / WALL_ART_H;
            let lz = PANEL_SAG * 4.0 * lx * lx;
            let pw = w.model.transformPoint(<f32>lx, <f32>ly, <f32>lz);
            let pa = this.viewProj.transformPoint(pw.x, pw.y, pw.z);
            let pb = this.viewProj.transformPoint(<f32>CO_CX[i], <f32>CO_CY[i], <f32>CO_CZ[i]);
            this.coAx[n] = (this.warpX(<f64>pa.x) * 0.5 + 0.5) * this.sizeX;
            this.coAy[n] = (0.5 - this.warpY(<f64>pa.x, <f64>pa.y) * 0.5) * this.sizeY;
            // optional drop below the drawing, then along that row to the card's edge that faces the car
            let ly2 = 0.5 - (ay + CO_DY[i]) / WALL_ART_H;
            let pd = w.model.transformPoint(<f32>lx, <f32>ly2, <f32>lz);
            let pdd = this.viewProj.transformPoint(pd.x, pd.y, pd.z);
            this.coDx[n] = (this.warpX(<f64>pdd.x) * 0.5 + 0.5) * this.sizeX;
            this.coDy[n] = (0.5 - this.warpY(<f64>pdd.x, <f64>pdd.y) * 0.5) * this.sizeY;
            let ex = (k == 0 ? 0.0 : WALL_ART_W) / WALL_ART_W - 0.5;
            let ez = PANEL_SAG * 4.0 * ex * ex;
            let pe = w.model.transformPoint(<f32>ex, <f32>ly2, <f32>ez);
            let pq = this.viewProj.transformPoint(pe.x, pe.y, pe.z);
            this.coEx[n] = (this.warpX(<f64>pq.x) * 0.5 + 0.5) * this.sizeX;
            this.coEy[n] = (0.5 - this.warpY(<f64>pq.x, <f64>pq.y) * 0.5) * this.sizeY;
            this.coBx[n] = (<f64>pb.x * 0.5 + 0.5) * this.sizeX;
            this.coBy[n] = (0.5 - <f64>pb.y * 0.5) * this.sizeY;
            // facing test: hide a callout whose part is on the far side of the car
            let vx = this.eyeX - CO_CX[i];
            let vz = this.eyeZ - CO_CZ[i];
            let face = (CO_NX[i] * vx + CO_NZ[i] * vz) / Math.max(1e-3, Math.sqrt(vx * vx + vz * vz));
            // and fade it out as its row scrolls under the header or off the bottom of the card
            let inBody = clamp((ay - 112.0) / 24.0, 0, 1) * clamp((760.0 - ay) / 24.0, 0, 1);
            this.coVis[n] = smooth(clamp((face - 0.1) / 0.3, 0, 1)) * inBody;
            n++;
        }
        this.coN = n;
    }

    drawCallouts(renderer: Renderer): void {
        if (this.coN == 0 || this.coT <= 0) {
            return;
        }
        let line = this.coLine;
        line.style = PaintStyle.stroke;
        line.thickness = 1.4;
        line.cap = StrokeCap.round;
        line.join = StrokeJoin.round;
        let fill = this.coFill;
        fill.style = PaintStyle.fill;
        for (let i = 0; i < this.coN; i++) {
            let vis = this.coVis[i];
            if (vis <= 0.01) {
                continue;
            }
            // staggered draw-on: each line grows from the panel to the car, then the end dot pops and pulses
            let t = clamp(this.coT * 1.6 - <f64>i * 0.22, 0, 1);
            if (t <= 0) {
                continue;
            }
            let e = 1 - Math.pow(1 - t, 3);
            let ax = this.coAx[i];
            let ay = this.coAy[i];
            let bx = this.coBx[i];
            let by = this.coBy[i];
            // polyline: anchor -> (drop) -> card edge -> part, drawn on to length L
            let px: StaticArray<f64> = [ax, this.coDx[i], this.coEx[i], bx];
            let py: StaticArray<f64> = [ay, this.coDy[i], this.coEy[i], by];
            let total = 0.0;
            for (let s = 0; s < 3; s++) {
                total += Math.sqrt((px[s + 1] - px[s]) * (px[s + 1] - px[s]) + (py[s + 1] - py[s]) * (py[s + 1] - py[s]));
            }
            let L = total * e;
            let path = this.coPath;
            path.reset();
            path.moveTo(Vector.xy(<f32>ax, <f32>ay));
            let acc = 0.0;
            for (let s = 0; s < 3; s++) {
                let sl = Math.sqrt((px[s + 1] - px[s]) * (px[s + 1] - px[s]) + (py[s + 1] - py[s]) * (py[s + 1] - py[s]));
                if (acc + sl <= L) {
                    path.lineTo(Vector.xy(<f32>px[s + 1], <f32>py[s + 1]));
                    acc += sl;
                } else {
                    let f = (L - acc) / Math.max(sl, 1e-3);
                    path.lineTo(Vector.xy(<f32>(px[s] + (px[s + 1] - px[s]) * f), <f32>(py[s] + (py[s + 1] - py[s]) * f)));
                    break;
                }
            }
            let alpha = <u8>Math.round(clamp(vis, 0, 1) * 230);
            line.color = Color.rgba(255, 164, 28, alpha);
            renderer.drawPath(path, line);
            // anchor dot on the panel edge
            let dots = this.coDots;
            dots.reset();
            this.circle(dots, ax, ay, 3.0);
            fill.color = Color.rgba(255, 164, 28, alpha);
            renderer.drawPath(dots, fill);
            if (t >= 1) {
                // end: solid dot + a slow pulse ring
                dots.reset();
                this.circle(dots, bx, by, 4.5);
                renderer.drawPath(dots, fill);
                let ph = (this.time * 0.6 + <f64>i * 0.33) % 1.0;
                dots.reset();
                this.circle(dots, bx, by, 6.0 + ph * 16.0);
                line.color = Color.rgba(255, 164, 28, <u8>Math.round((1 - ph) * 160 * vis));
                renderer.drawPath(dots, line);
            }
        }
    }

    circle(p: Path, cx: f64, cy: f64, r: f64): void {
        let k = 0.5523 * r;
        p.moveTo(Vector.xy(<f32>(cx + r), <f32>cy));
        p.cubicTo(Vector.xy(<f32>(cx + r), <f32>(cy + k)), Vector.xy(<f32>(cx + k), <f32>(cy + r)), Vector.xy(<f32>cx, <f32>(cy + r)));
        p.cubicTo(Vector.xy(<f32>(cx - k), <f32>(cy + r)), Vector.xy(<f32>(cx - r), <f32>(cy + k)), Vector.xy(<f32>(cx - r), <f32>cy));
        p.cubicTo(Vector.xy(<f32>(cx - r), <f32>(cy - k)), Vector.xy(<f32>(cx - k), <f32>(cy - r)), Vector.xy(<f32>cx, <f32>(cy - r)));
        p.cubicTo(Vector.xy(<f32>(cx + k), <f32>(cy - r)), Vector.xy(<f32>(cx + r), <f32>(cy - k)), Vector.xy(<f32>(cx + r), <f32>cy));
        p.close();
    }

    // camera-attached panels: springs, swing transitions, world matrices
    updatePanels(dt: f64, aspect: f64): void {
        let halfH = PANEL_D * Math.tan(this.fov * PI / 360);
        // touch-sized: the near (outer) edge spans ~78% of the screen height, top bar to dock
        let ph = 1.56 * PANEL_SCALE * halfH;
        let pw = ph * WALL_ART_W / WALL_ART_H;
        let k = 140.0;
        let c = 2 * Math.sqrt(k) * 0.62;
        let h = Math.min(dt, 1.0 / 30.0);
        for (let i = 0; i < this.walls.length; i++) {
            let w = this.walls[i];
            let target = (i == this.section && this.introT > 2.9) ? 1.0 : 0.0;
            // integrate in two half steps for stability
            for (let s = 0; s < 2; s++) {
                let acc = k * (target - w.p) - c * w.pv;
                w.pv += acc * h * 0.5;
                w.p += w.pv * h * 0.5;
            }
            if (target == 0 && w.p < 0.002) {
                w.p = 0;
                w.pv = 0;
            }
            w.ww = pw;
            w.wh = ph;
            let side: f64 = i == 0 ? 1 : -1;
            let hwNdc = (pw * 0.5) / (halfH * aspect);
            let ndcX = side * (1 - 0.03 - hwNdc) - this.lens;
            let x = ndcX * halfH * aspect;
            let y = 0.06 * halfH; // centred between the top bar and the dock
            let q = clamp(1 - w.p, -0.3, 1.2);
            // A solid object moving through space, never a fade: hidden, the card waits fully off screen past
            // its own edge, turned further edge-on and a little deeper. The (slightly underdamped) spring flies
            // it in, swinging round to rest at ~41 deg toward the car with a small settle; the exit is the same
            // flight in reverse. qq eases the travel so the swing leads the slide.
            let qq = q * q * (3 - 2 * clamp(q, 0, 1));
            // at rest the card faces the camera and lies on the visor (vs_ui bends it with the bars); the
            // swing in / out still turns it toward the car
            let yaw = -side * (PANEL_REST_YAW + q * 1.1);
            let px = x + side * qq * pw * 1.75;
            let local = Mat4.fromTranslation(<f32>(px + side * pw * 0.5), <f32>(y - qq * 0.06 * ph), <f32>(-PANEL_D - qq * 0.5));
            Mat4.multiply(local, local, Mat4.fromRotationY(<f32>yaw));
            Mat4.multiply(local, local, Mat4.fromTranslation(<f32>(-side * pw * 0.5), 0, 0));
            Mat4.multiply(local, local, Mat4.fromScale(<f32>pw, <f32>ph, <f32>pw));
            Mat4.multiply(w.model, this.invView, local);
            Mat4.invert(w.invModel, w.model);
            let cp = w.model.transformPoint(0, 0, 0);
            let np = w.model.transformPoint(0, 0, 1);
            w.cx = <f64>cp.x;
            w.cy = <f64>cp.y;
            w.cz = <f64>cp.z;
            w.yaw = Math.atan2(<f64>(np.x - cp.x), <f64>(np.z - cp.z));
        }
    }

    shotTmp: StaticArray<f64> = new StaticArray<f64>(8);
    shotFrom: StaticArray<f64> = new StaticArray<f64>(8);
    prevVP: Mat4 = Mat4.identity();
    havePrev: bool = false;
    mbX: f64 = 0;
    mbY: f64 = 0;

    // screen-space sweep of the background since last frame -> motion blur vector
    motionBlur(dt: f64): void {
        let fx = this.tx - this.eyeX;
        let fy = this.ty - this.eyeY;
        let fz = this.tz - this.eyeZ;
        let fl = Math.sqrt(fx * fx + fy * fy + fz * fz);
        let px = <f32>(this.eyeX + fx / fl * 14);
        let py = <f32>(this.eyeY + fy / fl * 14);
        let pz = <f32>(this.eyeZ + fz / fl * 14);
        if (this.havePrev && dt > 0) {
            let q = this.prevVP.transformPoint(px, py, pz);
            let cur = Mat4.identity();
            Mat4.multiply(cur, this.proj, this.view);
            let qn = cur.transformPoint(px, py, pz);
            // shutter 0.75 of a 60 fps frame
            let k = 0.75 * (1.0 / 60.0) / dt;
            let mx = <f64>(qn.x - q.x) * 0.5 * k;
            let my = <f64>(q.y - qn.y) * 0.5 * k;
            let len = Math.sqrt(mx * mx + my * my);
            let cap = 0.07;
            if (len > cap) {
                mx *= cap / len;
                my *= cap / len;
            }
            if (len < 0.0015) {
                mx = 0;
                my = 0;
            }
            this.mbX = mx;
            this.mbY = my;
        }
        Mat4.multiply(this.prevVP, this.proj, this.view);
        this.havePrev = true;
    }

    camera(dt: f64): void {
        let o = this.shotTmp;
        this.shotEye(this.section, this.time, o);
        let ex = o[0];
        let ey = o[1];
        let ez = o[2];
        let tx = o[3];
        let ty = o[4];
        let tz = o[5];
        let fov = o[6];
        let lens = o[7];
        if (this.flyT < 1) {
            this.flyT = Math.min(1, this.flyT + dt / this.flyDur);
            let u = this.flyGlide ? easeGlide(this.flyT) : easeInOut(this.flyT);
            lens = this.lensFrom + (lens - this.lensFrom) * u;
            // bell for the mid-flight bumps (crane lift, pull-back, fov breathe): sin(pi*u) of the EASED
            // progress, so every bump has zero slope at both ends. sin(pi*flyT) on the raw clock still had full
            // speed at the end of the move, which made the camera stop dead when it arrived.
            let bell = Math.sin(u * PI);
            // fly round the car on a cylinder (angle, radius, height) with a crane lift mid-flight
            let a0 = Math.atan2(this.fromEx, this.fromEz);
            let a1 = Math.atan2(ex, ez);
            let da = a1 - a0;
            while (da > PI) da -= 2 * PI;
            while (da < -PI) da += 2 * PI;
            let r0 = Math.sqrt(this.fromEx * this.fromEx + this.fromEz * this.fromEz);
            let r1 = Math.sqrt(ex * ex + ez * ez);
            let lift = bell * Math.min(1.6, Math.abs(da) * 0.9);
            let a = a0 + da * u;
            let r = r0 + (r1 - r0) * u + bell * 1.2;
            ex = Math.sin(a) * r;
            ez = Math.cos(a) * r;
            ey = this.fromEy + (ey - this.fromEy) * u + lift;
            tx = this.fromTx + (tx - this.fromTx) * u;
            ty = this.fromTy + (ty - this.fromTy) * u;
            tz = this.fromTz + (tz - this.fromTz) * u;
            fov = this.fromFov + (fov - this.fromFov) * u + bell * 4;
        }
        // user orbit: yaw round the target, pitch (eased back to level), wheel zoom
        if (this.flyT < 1) {
            let u = this.flyGlide ? easeGlide(this.flyT) : easeInOut(this.flyT);
            this.orbitYaw = this.yawFrom * (1 - u);
            this.orbitZoom = this.zoomFrom + (1 - this.zoomFrom) * u;
        } else if (this.orbitMode != 2) {
            this.orbitYaw += this.yawVel * dt;
            this.yawVel *= Math.exp(-3.2 * dt);
        }
        if (this.orbitMode != 2) {
            this.orbitPitch *= Math.exp(-1.6 * dt);
        }
        if (Math.abs(this.orbitYaw) > 1e-5 || Math.abs(this.orbitPitch) > 1e-5 || Math.abs(this.orbitZoom - 1) > 1e-5) {
            let ox = ex - tx;
            let oy = ey - ty;
            let oz = ez - tz;
            let cy = Math.cos(this.orbitYaw);
            let sy = Math.sin(this.orbitYaw);
            let rx = ox * cy + oz * sy;
            let rz = -ox * sy + oz * cy;
            let hd = Math.max(1e-4, Math.sqrt(rx * rx + rz * rz));
            let el = clamp(Math.atan2(oy, hd) + this.orbitPitch, -0.02, 1.3);
            let L = Math.sqrt(hd * hd + oy * oy) * this.orbitZoom;
            ex = tx + rx / hd * Math.cos(el) * L;
            ez = tz + rz / hd * Math.cos(el) * L;
            ey = Math.max(0.25, ty + Math.sin(el) * L);
        }
        if (this.shake > 0) {
            let s = this.shake * 0.04;
            ex += Math.sin(this.time * 71) * s;
            ey += Math.sin(this.time * 53 + 1) * s;
            this.shake = Math.max(0, this.shake - dt * 1.5);
        }
        this.eyeX = ex;
        this.eyeY = ey;
        this.eyeZ = ez;
        this.tx = tx;
        this.ty = ty;
        this.tz = tz;
        this.fov = fov;
        this.lens = lens;
        this.view = Mat4.lookAtVector(v3(ex, ey, ez), v3(tx, ty, tz), v3(0, 1, 0));
    }

    director(dt: f64): void {
        this.introT += dt;
        let t = this.introT;
        // exposure ramp and wall power-on: each panel flickers on in turn like a neon sign
        this.up = smooth(clamp((t - 0.2) / 1.8, 0, 1));
        for (let k = 0; k < this.walls.length; k++) {
            this.walls[k].power = 1;
        }
        this.lights = this.lightsOn ? (t < 2.0 ? 0.0 : (t < 2.12 ? 1.0 : (t < 2.22 ? 0.1 : 1.0))) : 0.0;
        if (t > 2.7 && this.section < 0) {
            this.flyDur = 3.6;
            let pre = <i32>Math.round(this.getN("section", -1));
            this.goSection(pre >= 0 && pre < 5 ? pre : 0);
            this.flyGlide = true;
            this.flyDur = 4.2;
        }
        this.setN("hud", t > 3.4 ? 1.0 : 0.0);
        // requests from the UI (dock steppers, gadget tiles)
        let req = <i32>this.getN("req", 0);
        if (req != 0) {
            this.setN("req", 0);
            this.handleReq(req);
        }
        this.updateGfx(dt);
        // section picked from the dock
        let vs = <i32>Math.round(this.getN("section", -1));
        if (vs != this.section && vs >= 0 && vs < 5 && t > 2.7) {
            this.goSection(vs);
        }
        // boost: wheels spin up, camera shudders
        let target = this.boostOn ? 38.0 : 0.0;
        this.boostT += (target - this.boostT) * Math.min(1, dt * 1.6);
        this.wheelSpin += this.boostT * dt;
        if (this.discoOn) {
            this.discoHue += dt * 0.35;
        }
        // drive mode TURBO also lights the turbine
        let dm = <i32>Math.round(this.getN("driveMode", 0));
        if (dm != this.driveMode) {
            this.driveMode = dm;
            if ((dm == 2) != this.boostOn) {
                this.toggleBoost();
            }
        }
        // media clock
        if (this.getN("playing", 1) > 0.5) {
            this.songT += dt;
            if (this.songT > 192) {
                this.songT = 0;
            }
        }
        let st = <i32>Math.floor(this.songT);
        let mm = st / 60;
        let ss = st % 60;
        this.setS("elapsed", mm.toString() + ":" + (ss < 10 ? "0" : "") + ss.toString());
        this.setN("songPx", 532 * this.songT / 192);

        // playlist on the TUNES panel drifts slowly through the queue (ScrollConstraint offset)

    }

    carDone(): bool {
        let rd = this.carReader;
        return rd == null ? this.time > 8 : rd.done();
    }

    // Graphics settings from the Vehicle panel, plus an automatic step down on slow machines: after the intro,
    // if frames stay slower than ~30 fps for 2.5 s, drop one quality level (High -> Balanced -> Fast). It never
    // steps up and never overrides a level the user picked.
    updateGfx(dt: f64): void {
        let q = <i32>Math.round(this.getN("gfxQ", 0));
        if (q != this.gfxQ) {
            this.gfxQ = q < 0 ? 0 : (q > 2 ? 2 : q);
            this.updateReadout();
            if (this.perfHold <= 0) {
                this.gfxUser = true;   // a change we did not make ourselves
            }
            if (this.ready) {
                this.rebuildTargets();
            }
        }
        this.gfxBlur = this.getN("gfxBlur", 1) > 0.5;
        this.gfxRefl = this.getN("gfxRefl", 1) > 0.5;
        this.gfxBloom = this.getN("gfxBloom", 1) > 0.5;
        // profiling: 1 env cube, 2 backdrop, 4 rocks, 8 mountains, 16 panel canvases, 32 LED canvas, 64 visor,
        // 128 car, 256 floor, 512 bloom + frost, 1024 panel cards
        this.dbgOff = <i32>this.getN("dbgOff", 0);
        if (dt <= 0 || dt > 0.25) {
            return;   // a paused / hidden tab, not a slow frame
        }
        this.perfAvg = this.perfAvg <= 0 ? dt : this.perfAvg + (dt - this.perfAvg) * 0.05;
        if (this.perfHold > 0) {
            this.perfHold -= dt;
            this.perfSlow = 0;
            return;
        }
        if (this.gfxUser || this.autoLocked || this.introT < 6 || !this.carDone()) {
            this.perfSlow = 0;
            this.perfFast = 0;
            return;
        }
        // Down one level after 4 s under ~30 fps. Up again (only levels auto took away) after 4 s above ~55 fps:
        // a throttled or hidden window, or a hitch while something loaded, no longer leaves a fast machine stuck
        // on a lower level. Stepping up and getting slow again within 15 s settles on the lower level for good.
        this.perfSlow = this.perfAvg > 1.0 / 30.0 ? this.perfSlow + dt : 0;
        this.perfFast = this.perfAvg < 1.0 / 55.0 ? this.perfFast + dt : 0;
        if (this.perfSlow > 4.0 && this.gfxQ < 2) {
            if (this.time - this.autoUpAt < 15.0) {
                this.autoLocked = true;
            }
            this.autoStep(1);
        } else if (this.perfFast > 4.0 && this.autoDown > 0) {
            this.autoUpAt = this.time;
            this.autoStep(-1);
        }
    }

    autoStep(dir: i32): void {
        this.perfHold = 3.0;
        this.perfSlow = 0;
        this.perfFast = 0;
        this.autoDown += dir;
        this.setN("gfxQ", <f64>(this.gfxQ + dir));
        this.log("showroom: frames " + (<i32>(this.perfAvg * 1000)).toString() + " ms, quality -> " + (this.gfxQ + dir).toString());
    }

    handleReq(req: i32): void {
        if (req >= 60 && req <= 62) {
            let names: StaticArray<string> = ["gfxBlur", "gfxRefl", "gfxBloom"];
            let n = names[req - 60];
            this.setN(n, this.getN(n, 1) > 0.5 ? 0 : 1);
            return;
        }
        if (req == 50) {
            // shortcuts pill (hidden by default so it never cuts into the sky)
            this.setN("keys", this.getN("keys", 0) > 0.5 ? 0.0 : 1.0);
            return;
        }
        if (req == 10 || req == 11) {
            this.tempL = clamp(this.tempL + (req == 11 ? 0.5 : -0.5), 16, 28);
            this.setS("tempL", celsius(this.tempL));
        } else if (req == 12 || req == 13) {
            this.tempR = clamp(this.tempR + (req == 13 ? 0.5 : -0.5), 16, 28);
            this.setS("tempR", celsius(this.tempR));
        } else if (req == 20) {
            this.toggleLights();
        } else if (req == 21) {
            this.toggleBoost();
        } else if (req == 22) {
            this.beaconOn = !this.beaconOn;
            this.setN("beacon", this.beaconOn ? 1 : 0);
        } else if (req == 23) {
            this.discoOn = !this.discoOn;
            this.setN("glow", this.discoOn ? 1 : 0);
        } else if (req == 14 || req == 15) {
            this.fan = clamp(this.getN("fan", 3) + (req == 15 ? 1 : -1), 0, 6);
            this.setN("fan", this.fan);
        } else if (req >= 30 && req <= 35) {
            let names: StaticArray<string> = ["ac", "auto", "recirc", "defrost", "seat", "sync"];
            let n = names[req - 30];
            this.setN(n, this.getN(n, 0) > 0.5 ? 0 : 1);
        } else if (req == 40) {
            this.setN("playing", this.getN("playing", 1) > 0.5 ? 0 : 1);
        }
        this.updateReadout();
    }

    toggleLights(): void {
        this.lightsOn = !this.lightsOn;
        this.setN("lights", this.lightsOn ? 1 : 0);
        this.updateReadout();
    }

    toggleBoost(): void {
        this.boostOn = !this.boostOn;
        this.setN("boost", this.boostOn ? 1 : 0);
        if (this.boostOn != (this.driveMode == 2)) {
            this.driveMode = this.boostOn ? 2 : 0;
            this.setN("driveMode", <f64>this.driveMode);
        }
        if (this.boostOn) {
            this.shake = 1;
        }
        this.updateReadout();
    }

    replay(): void {
        this.orbitYaw = 0;
        this.orbitPitch = 0;
        this.orbitZoom = 1;
        this.yawVel = 0;
        this.introT = 0;
        this.section = -1;
        this.setN("section", -1);
        this.setN("hud", 0);
        this.fromEx = this.eyeX;
        this.fromEy = this.eyeY;
        this.fromEz = this.eyeZ;
        this.flyT = 1;
    }

    // pointer ray -> wall uv (artboard units); returns the wall index or -1
    hitX: f64 = 0;
    hitY: f64 = 0;
    // uv on panel k for a screen point, unbounded (a captured drag keeps scrolling off the panel)
    panelUV(k: i32, px: f64, py: f64): bool {
        // undo the visor lens: screen -> flat HUD ndc, then the usual 3D ray
        this.visorFlat(px, py);
        let nx = <f32>this.flatX;
        let ny = <f32>this.flatY;
        let p0 = this.invViewProj.transformPoint(nx, ny, 0);
        let p1 = this.invViewProj.transformPoint(nx, ny, 1);
        let w = this.walls[k];
        let a = w.invModel.transformPoint(p0.x, p0.y, p0.z);
        let c = w.invModel.transformPoint(p1.x, p1.y, p1.z);
        let dz = <f64>(c.z - a.z);
        if (Math.abs(dz) < 1e-9) {
            return false;
        }
        let t = curveHitT(a, c);
        this.hitX = (<f64>a.x + <f64>(c.x - a.x) * t + 0.5) * WALL_ART_W;
        this.hitY = (0.5 - (<f64>a.y + <f64>(c.y - a.y) * t)) * WALL_ART_H;
        return true;
    }

    pickWall(px: f64, py: f64): i32 {
        if (this.sizeX <= 0) {
            return -1;
        }
        // undo the visor lens: screen -> flat HUD ndc, then the usual 3D ray
        this.visorFlat(px, py);
        let nx = <f32>this.flatX;
        let ny = <f32>this.flatY;
        let p0 = this.invViewProj.transformPoint(nx, ny, 0);
        let p1 = this.invViewProj.transformPoint(nx, ny, 1);
        for (let k = 0; k < this.walls.length; k++) {
            let w = this.walls[k];
            if (w.p < 0.5) {
                continue;
            }
            // ray into the panel's local space (unit quad on z = 0)
            let a = w.invModel.transformPoint(p0.x, p0.y, p0.z);
            let c = w.invModel.transformPoint(p1.x, p1.y, p1.z);
            let dz = <f64>(c.z - a.z);
            if (Math.abs(dz) < 1e-9) {
                continue;
            }
            let t = curveHitT(a, c);
            if (t < 0) {
                continue;
            }
            let lx = <f64>a.x + <f64>(c.x - a.x) * t;
            let ly = <f64>a.y + <f64>(c.y - a.y) * t;
            let u = lx + 0.5;
            let v = 0.5 - ly;
            if (u < 0 || u > 1 || v < 0 || v > 1) {
                continue;
            }
            this.hitX = u * WALL_ART_W;
            this.hitY = v * WALL_ART_H;
            return k;
        }
        return -1;
    }

    panelEvent(k: i32, id: f64, kind: i32): void {
        let inst = this.walls[k].inst;
        if (inst == null) {
            return;
        }
        let e = new PointerEvent(id, Vector.xy(<f32>this.hitX, <f32>this.hitY));
        if (kind == 0) {
            inst.pointerDown(e);
        } else if (kind == 1) {
            inst.pointerMove(e);
        } else {
            inst.pointerUp(e);
        }
    }

    // A press on a panel owns the whole gesture (taps, scroll drags); a press anywhere else orbits the
    // camera after a 5 px slop. The wheel scrolls a panel under the pointer, otherwise it zooms.
    override pointerDown(event: PointerEvent): void {
        this.visorPoke();
        let px = <f64>event.position.x;
        let py = <f64>event.position.y;
        // the visor's bars are on top of everything: a press that lands on one of their controls belongs to it
        if (this.visorUV(px, py) && this.visorEvent(event.id, 0) != 0) {
            this.visorCap = true;
            event.hit();
            return;
        }
        let k = this.pickWall(px, py);
        if (k >= 0) {
            this.capture = k;
            this.panelEvent(k, event.id, 0);
            event.hit();
            return;
        }
        this.orbitMode = 1;
        this.downX = px;
        this.downY = py;
        this.lastX = px;
        this.lastY = py;
        this.yawVel = 0;
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        this.visorPoke();
        let px = <f64>event.position.x;
        let py = <f64>event.position.y;
        if (this.visorCap) {
            if (this.visorUV(px, py)) {
                this.visorEvent(event.id, 1);
            }
            return;
        }
        if (this.capture >= 0) {
            if (this.panelUV(this.capture, px, py)) {
                this.panelEvent(this.capture, event.id, 1);
            }
            return;
        }
        if (this.orbitMode > 0) {
            if (this.orbitMode == 1 && Math.abs(px - this.downX) + Math.abs(py - this.downY) > 5) {
                this.orbitMode = 2;
            }
            if (this.orbitMode == 2) {
                let dx = px - this.lastX;
                let dy = py - this.lastY;
                this.orbitYaw -= dx * 0.006;
                this.yawVel = -dx * 0.006 * 60;
                // pitch: a third as sensitive, stiffening toward +-0.3
                let lim = 0.3;
                let stiff = 1 - Math.min(1, Math.abs(this.orbitPitch) / lim) * (Math.sign(dy) == Math.sign(this.orbitPitch) ? 1 : 0) * 0.85;
                this.orbitPitch += dy * 0.002 * stiff;
            }
            this.lastX = px;
            this.lastY = py;
            return;
        }
        // hover: the visor and the panels react under the pointer
        if (this.visorUV(px, py)) {
            this.visorEvent(event.id, 1);
        }
        let k = this.pickWall(px, py);
        if (k >= 0) {
            this.panelEvent(k, event.id, 1);
        }
    }

    override pointerUp(event: PointerEvent): void {
        this.visorPoke();
        let px = <f64>event.position.x;
        let py = <f64>event.position.y;
        if (this.visorCap) {
            this.visorUV(px, py);
            this.visorEvent(event.id, 2);
            this.visorCap = false;
            event.hit();
            return;
        }
        if (this.capture >= 0) {
            if (this.panelUV(this.capture, px, py)) {
                this.panelEvent(this.capture, event.id, 2);
            }
            this.capture = -1;
            event.hit();
            return;
        }
        if (this.orbitMode != 2) {
            this.yawVel = 0;
        }
        this.orbitMode = 0;
    }

    override pointerScroll(event: ScrollEvent): void {
        let px = <f64>event.position.x;
        let py = <f64>event.position.y;
        let k = this.pickWall(px, py);
        if (k >= 0) {
            let inst = this.walls[k].inst;
            if (inst != null) {
                inst.pointerScroll(new ScrollEvent(event.id, Vector.xy(<f32>this.hitX, <f32>this.hitY), event.delta, event.phase,
                    event.precise, event.timeStamp));
            }
            event.hit();
            return;
        }
        this.orbitZoom = clamp(this.orbitZoom * Math.exp(<f64>event.delta.y * 0.0015), 0.65, 1.6);
        event.hit();
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        this.visorPoke();
        if (event.control || event.meta || event.alt) {
            return false;
        }
        if (event.phase != "down") {
            return false;
        }
        let k = event.key;
        let cur = this.section < 0 ? 0 : this.section;
        if (k == KEY_RIGHT) {
            this.goSection((cur + 1) % 5);
        } else if (k == KEY_LEFT) {
            this.goSection((cur + 4) % 5);
        } else if (k >= 49 && k <= 53) {
            this.goSection(<i32>(k - 49));
        } else if (k >= 321 && k <= 325) {
            this.goSection(<i32>(k - 321));
        } else if (k == KEY_L) {
            this.toggleLights();
        } else if (k == KEY_B) {
            this.toggleBoost();
        } else if (k == KEY_D || k == KEY_G) {
            this.handleReq(23);
        } else if (k == KEY_R) {
            this.replay();
        } else if (k == KEY_N) {
            this.nightOn = !this.nightOn;
            this.log(this.nightOn ? "night" : "day");
        } else if (k == KEY_Q) {
            // graphics quality: High -> Balanced -> Fast -> High (a user choice: auto leaves it alone after this)
            this.gfxUser = true;
            this.setN("gfxQ", <f64>((this.gfxQ + 1) % 3));
        } else if (k == KEY_K || k == 47) {
            this.handleReq(50);   // K or / : show / hide the keyboard shortcuts
        } else {
            return false;
        }
        return true;
    }

    override advance(dt: f64): bool {
        this.time += dt;
        if (!this.ready) {
            // GPU setup and car streaming never share a frame: each script call has a ~200 ms watchdog
            this.trySetup();
        } else {
            this.streamCar(2);
        }
        // day <-> night over 4 s, eased (the sun sets / rises and the moon follows in env.wgsl)
        let nTarget = this.nightOn ? 1.0 : 0.0;
        if (this.nightT != nTarget) {
            this.nightT = nTarget > this.nightT ? Math.min(1, this.nightT + dt / 4.0) : Math.max(0, this.nightT - dt / 4.0);
            this.nightK = this.nightT * this.nightT * (3 - 2 * this.nightT);
        }
        this.director(dt);
        this.camera(dt);
        // Advance a panel's artboard only while its card is on screen or launching: its arrival choreography
        // then plays as the card flies in (not hidden during the intro), and the hidden panels cost nothing.
        for (let k = 0; k < this.walls.length; k++) {
            let wl = this.walls[k];
            let inst = wl.inst;
            let launching = k == this.section && this.introT > 2.9;
            if (inst != null && (wl.p > 0.002 || launching)) {
                inst.advance(dt);
            }
        }
        let ledi = this.ledInst;
        if (ledi != null) {
            ledi.advance(dt);
            // responsive bars: 1 drops the dock's centred climate group, 2 also the status icons and song text
            this.setN("compact", this.sizeX < 560 ? 2 : (this.sizeX < 1100 ? 1 : 0));
            let vsi = this.visorInst;
            if (vsi != null) {
                this.visorLive = vsi.advance(dt);
            }
        }
        let aspect = this.sizeY > 0 ? this.sizeX / this.sizeY : 1.0;
        this.proj = Mat4.perspective(<f32>(this.fov * PI / 180), <f32>aspect, 0.1, 400);
        // lens shift: slide the image sideways so the car sits in the 2/3 opposite the panel
        Mat4.multiply(this.proj, Mat4.fromTranslation(<f32>this.lens, 0, 0), this.proj);
        Mat4.invert(this.invView, this.view);
        this.updatePanels(dt, aspect);
        this.motionBlur(dt);
        Mat4.multiply(this.viewProj, this.proj, this.view);
        Mat4.invert(this.invViewProj, this.viewProj);
        // mirrored camera for the floor reflection: view * scale(1, -1, 1)
        let flip = Mat4.fromScale(1, -1, 1);
        let vr = Mat4.identity();
        Mat4.multiply(vr, this.view, flip);
        Mat4.multiply(this.viewProjR, this.proj, vr);
        // car + wheels
        this.carModel = Mat4.identity();
        let car = this.car;
        if (car != null) {
            for (let w = 1; w <= 4; w++) {
                let px = car.wx[w - 1];
                let py = car.wy[w - 1];
                let pz = car.wz[w - 1];
                let m = Mat4.fromTranslation(<f32>px, <f32>py, <f32>pz);
                Mat4.multiply(m, m, Mat4.fromRotationX(<f32>-this.wheelSpin));
                Mat4.multiply(m, m, Mat4.fromTranslation(<f32>-px, <f32>-py, <f32>-pz));
                let wm = Mat4.identity();
                Mat4.multiply(wm, this.carModel, m);
                this.wheelModels[w] = wm;
            }
        }
        this.wheelModels[0] = this.carModel;
        this.updatePins();
        this.updateCallouts(dt);
        return true;
    }

    writeDraw(d: Draw, ubo: GPUBuffer, vp: Mat4, eyeY: f64, hgt: bool): void {
        let b = this.scratch;
        let car = this.car!;
        let model = this.wheelModels[d.mesh.part];
        Mat4.multiply(this.mvp, vp, model);
        this.mvp.writeToBuffer(b, 0);
        model.writeToBuffer(b, 64);
        let m = d.mat;
        this.v4(128, m.r, m.g, m.b, m.metal);
        this.v4(144, m.rough, m.coat, m.coatRough, m.flake);
        let flags = (m.tex.length > 0 ? 1 : 0) + (m.bump.length > 0 ? 2 : 0);
        this.v4(160, m.mode, <f64>flags, this.exposure, this.time);
        this.v4(176, this.eyeX, eyeY, this.eyeZ, <f64>(ENV_MIPS - 1));
        this.v4(192, car.hx, car.hy, car.hz, m.bumpS);
        this.v4(208, d.mesh.u0, d.mesh.v0, d.mesh.u1 - d.mesh.u0, d.mesh.v1 - d.mesh.v0);
        this.v4(224, m.tileU, m.tileV, m.texMix, m.ao);
        let ls = m.lights > 0 ? this.lights : 1.0;
        if (this.beaconOn && d.mesh.name == "Red_Light") {
            ls = 1.0 + 9.0 * Math.pow(0.5 + 0.5 * Math.sin(this.time * 11), 4);
        }
        this.v4(240, m.er * ls, m.eg * ls, m.eb * ls, m.tint);
        this.v4(256, 0, 0, 3.6, 3.6);
        this.v4(272, 1 / <f64>this.tw, 1 / <f64>this.th, 1.0, 0.18);
        this.writeKey();
        ubo.update(0, b, UBO_SIZE, 0);
    }

    writeWallLights(): void {
        for (let k = 0; k < 9; k++) {
            this.v4(320 + k * 16, 0, 0, 0, 0);
        }
        // the light wall pools lime light on the asphalt (same centre / yaw / colour as env.wgsl)
        this.v4(320, 8.13, 2.64, -8.5, this.wallLight * 1.1);
        this.v4(336, 0.92, 0.95, 0.08, -0.547);
        // welcome light: a soft amber light carpet under the car (the UI accent, Rive #FFA41C)
        this.v4(464, 1.0, 0.37, 0.01, this.discoOn ? 1.6 : 0.0);
    }

    writeKey(): void {
        // soft key light from the big wall (back-left, above)
        this.v4(288, -0.62, 0.32, -0.78, 0.0);
        this.v4(304, 1.0, 0.66, 0.42, 0.35);
    }

    renderEnv(): void {
        let gpu = this.gpu!;
        let b = this.scratch;
        if (this.nightK != this.nightKDrawn) {
            this.staticDone = false;
            this.nightKDrawn = this.nightK;
        }
        if (!this.staticDone) {
            for (let f = 0; f < this.staticPasses.length; f++) {
                this.v4(0, <f64>f, 0, <f64>ENV_SIZE, this.time);
                this.writeEnvCommon();
                this.staticUbos[f].update(0, b, ENV_UBO, 0);
                let sp = gpu.beginRenderPass(this.staticPasses[f]);
                sp.setPipeline(this.envStaticPipe!);
                sp.setBindGroup(0, this.staticBGs[f]);
                sp.draw(3);
                sp.finish();
            }
            if (!this.hmDone) {
                this.hmDone = true;
                this.v4(0, 0, <f64>HM_SIZE, 0, 0);
                this.writeEnvCommon();
                this.hmUbo!.update(0, b, ENV_UBO, 0);
                let hpp = gpu.beginRenderPass(this.hmPass!);
                hpp.setPipeline(this.hmPipe!);
                hpp.setBindGroup(0, this.hmBG!);
                hpp.draw(3);
                hpp.finish();
                this.v4(0, 0, <f64>RB_N, 0, 0);
                this.writeEnvCommon();
                this.rbUbo!.update(0, b, ENV_UBO, 0);
                let rpp = gpu.beginRenderPass(this.rbPass!);
                rpp.setPipeline(this.rbPipe!);
                rpp.setBindGroup(0, this.rbBG!);
                rpp.draw(3);
                rpp.finish();
            }
            for (let f = 0; f < this.skyCubePasses.length; f++) {
                this.v4(0, <f64>f, 0, <f64>SKY_CUBE, this.time);
                this.writeEnvCommon();
                this.skyCubeUbos[f].update(0, b, ENV_UBO, 0);
                let kp = gpu.beginRenderPass(this.skyCubePasses[f]);
                kp.setPipeline(this.skyCubePipe!);
                kp.setBindGroup(0, this.skyCubeBGs[f]);
                kp.draw(3);
                kp.finish();
            }
            this.staticDone = true;
        }
        for (let i = 0; i < this.envPasses.length; i++) {
            this.v4(0, this.envFace[i], this.envRough[i], this.envSize[i], this.time);
            this.writeEnvCommon();
            this.envUbos[i].update(0, b, ENV_UBO, 0);
            let kind = this.envKinds[i];
            if ((this.dbgOff & 1) != 0 && this.envFrame > 2) {
                continue;
            }
            // the blurry (rough) specular mips refresh half their faces per frame, alternating: each face still
            // updates at 30 Hz, which nothing slower than the LED wall's 1 s colour swipe can show
            if (kind == 2 && this.envRough[i] > 0 && this.envFrame > 2 && (<i32>this.envFace[i]) % 2 != this.envFrame % 2) {
                continue;
            }
            // lower qualities: the live faces (and their mip chain) refresh at half rate, the rough mips at 1/4
            if (this.gfxQ >= 1 && kind <= 1 && this.envFrame > 2 && (<i32>this.envFace[i]) % 2 != this.envFrame % 2) {
                continue;
            }
            if (this.gfxQ >= 2 && kind == 2 && this.envRough[i] > 0 && this.envFrame > 2 && (this.envFrame >> 1) % 2 != 0) {
                continue;
            }
            let pipe = kind == 0 ? this.envPipe! : (kind == 1 ? this.downPipe! : this.prePipe!);
            let pass = gpu.beginRenderPass(this.envPasses[i]);
            pass.setPipeline(pipe);
            pass.setBindGroup(0, this.envBGs[i]);
            pass.draw(3);
            pass.finish();
        }
        this.envFrame++;
        if (!this.lutDone) {
            let lp = gpu.beginRenderPass(this.lutPass!);
            lp.setPipeline(this.brdfPipe!);
            lp.setBindGroup(0, this.lutBG!);
            lp.draw(3);
            lp.finish();
            this.lutDone = true;
        }
    }

    writeEnvCommon(): void {
            this.v4(16, this.wallI, this.stripI, this.boxI, <f64>ENV_MIPS);
            this.v4(32, this.up, this.wallLight, this.nightK, 0);
            for (let k = 0; k < 5; k++) {
                if (k < this.walls.length) {
                    let w = this.walls[k];
                    this.v4(48 + k * 16, w.cx, w.cy, w.cz, w.power * w.p);
                    this.v4(128 + k * 16, w.yaw, w.ww * 0.5, w.wh * 0.5, 0.9);
                } else {
                    this.v4(48 + k * 16, 0, 0, 0, 0);
                    this.v4(128 + k * 16, 0, 0, 0, 0);
                }
            }
    }

    pumpTextures(): void {
        let gpu = this.gpu!;
        for (let i = 0; i < this.texNames.length; i++) {
            let t = this.texs.get(this.texNames[i]);
            if (t.finish(gpu, this.mip8Pipe!, this.linSampler!, this.fillUbo!, this.fill2D!)) {
                this.texReadyCount++;
                this.bgDirty = true;
            }
        }
    }

    drawCar(pass: GPURenderPass, reflect: bool): void {
        let draws = this.draws;
        for (let i = 0; i < draws.length; i++) {
            let d = draws[i];
            let bg = reflect ? d.bgR : d.bg;
            if (bg == null) {
                continue;
            }
            pass.setBindGroup(0, bg);
            pass.setVertexBuffer(0, d.mesh.vbuf!);
            pass.setIndexBuffer(d.mesh.ibuf!, <u32>IndexFormat.uint32);
            pass.drawIndexed(<u32>d.mesh.icount);
        }
    }

    drawPanels(pass: GPURenderPass): void {
        let b = this.scratch;
        pass.setPipeline(this.uiPipe!);
        for (let k = 0; k < this.walls.length; k++) {
            let w = this.walls[k];
            let bg = w.bgU;
            if (bg == null || w.p < 0.002) {
                continue;
            }
            Mat4.multiply(this.mvp, this.viewProj, w.model);
            this.mvp.writeToBuffer(b, 0);
            w.model.writeToBuffer(b, 64);
            this.v4(240, 1, 0, 0, 0);   // no opacity ramp: the card slides in and out as a solid object
            this.v4(160, this.gfxBlur ? 0 : 1, 0, this.exposure, this.time);
            this.v4(176, this.eyeX, this.eyeY, this.eyeZ, <f64>(ENV_MIPS - 1));
            this.v4(272, 1 / <f64>this.ow, 1 / <f64>this.oh, 0, 0);   // drawn in the full-res resolve pass
            this.v4(256, VISOR_TAN, this.sizeX / Math.max(1, this.sizeY), VISOR_INSET, 0);
            w.uboU!.update(0, b, UBO_SIZE, 0);
            pass.setBindGroup(0, bg);
            pass.setVertexBuffer(0, this.wallVB!);
            pass.setIndexBuffer(this.wallIB!, <u32>IndexFormat.uint32);
            pass.drawIndexed(this.wallIdx);
        }
    }

    drawVisor(pass: GPURenderPass): void {
        let bg = this.visorBG;
        if (bg == null || (this.dbgOff & 64) != 0) {
            return;
        }
        let b = this.scratch;
        this.invViewProj.writeToBuffer(b, 0);
        this.v4(160, this.gfxBlur ? 0 : 1, 0, this.exposure, this.time);
        this.v4(176, this.eyeX, this.eyeY, this.eyeZ, <f64>(ENV_MIPS - 1));
        this.v4(240, VISOR_TAN, this.sizeX / Math.max(1, this.sizeY), VISOR_INSET, 0);
        this.v4(272, 1 / <f64>this.ow, 1 / <f64>this.oh, 0, 0);
        this.visorUbo!.update(0, b, UBO_SIZE, 0);
        pass.setPipeline(this.visorPipe!);
        pass.setBindGroup(0, bg);
        pass.draw(3);
    }

    // Screen point -> visor artboard point (the inverse of fs_visor's wrap). False outside the canvas.
    visorUV(px: f64, py: f64): bool {
        if (this.sizeX <= 0 || this.sizeY <= 0) {
            return false;
        }
        let x = px / this.sizeX * 2 - 1;
        let y = 1 - py / this.sizeY * 2;
        let aspect = this.sizeX / this.sizeY;
        let dx = x * VISOR_TAN;
        let dy = y * VISOR_TAN / aspect;
        let th = Math.atan(dx);
        let h = dy / Math.sqrt(dx * dx + 1);
        let u = 0.5 + th / (2 * Math.atan(VISOR_TAN));
        let v = 0.5 - h / (2 * (VISOR_TAN / aspect) * VISOR_INSET);
        if (u < 0 || u > 1 || v < 0 || v > 1) {
            return false;
        }
        this.visorHX = u * this.sizeX;
        this.visorHY = v * this.sizeY;
        return true;
    }

    // screen point -> the flat (pre-lens) ndc the UI cards are laid out in
    visorFlat(px: f64, py: f64): void {
        let x = px / this.sizeX * 2 - 1;
        let y = 1 - py / this.sizeY * 2;
        let dx = x * VISOR_TAN;
        this.flatX = Math.atan(dx) / Math.atan(VISOR_TAN);
        this.flatY = y / (VISOR_INSET * Math.sqrt(1 + dx * dx));
    }

    // flat ndc -> screen ndc through the visor lens (vs_ui's visorWarp)
    warpX(x: f64): f64 {
        return Math.tan(clamp(x, -3, 3) * Math.atan(VISOR_TAN)) / VISOR_TAN;
    }

    warpY(x: f64, y: f64): f64 {
        return y * VISOR_INSET / Math.cos(clamp(x, -3, 3) * Math.atan(VISOR_TAN));
    }

    visorEvent(id: f64, kind: i32): f64 {
        let inst = this.visorInst;
        if (inst == null) {
            return 0;
        }
        let e = new PointerEvent(id, Vector.xy(<f32>this.visorHX, <f32>this.visorHY));
        this.visorForce = true;
        this.visorPoke();
        if (kind == 0) {
            return inst.pointerDown(e);
        } else if (kind == 1) {
            return inst.pointerMove(e);
        }
        return inst.pointerUp(e);
    }

    drawWalls(pass: GPURenderPass, reflect: bool): void {
        let b = this.scratch;
        pass.setPipeline(reflect ? this.wallPipeR! : this.wallPipe!);
        for (let k = 0; k < this.walls.length; k++) {
            let w = this.walls[k];
            let bg = reflect ? w.bgR : w.bg;
            if (bg == null || w.power <= 0.001) {
                continue;
            }
            Mat4.multiply(this.mvp, reflect ? this.viewProjR : this.viewProj, w.model);
            this.mvp.writeToBuffer(b, 0);
            w.model.writeToBuffer(b, 64);
            this.v4(160, 0, 0, this.exposure, this.time);
            let pw = w.power * 1.7;
            this.v4(240, pw, pw, pw, 0);
            (reflect ? w.uboR! : w.ubo!).update(0, b, UBO_SIZE, 0);
            pass.setBindGroup(0, bg);
            pass.setVertexBuffer(0, this.wallVB!);
            pass.setIndexBuffer(this.wallIB!, <u32>IndexFormat.uint32);
            pass.drawIndexed(this.wallIdx);
        }
        pass.setPipeline(reflect ? this.carPipeR! : this.carPipe!);
    }

    override draw(renderer: Renderer): void {
        let gpu = this.gpu;
        if (!this.ready || gpu == null || this.scenePass == null || this.carPipe == null) {
            return;
        }
        if (gpu.width <= 0) {
            return;
        }
        if (F_TEX) {
            this.pumpTextures();
        }
        if (this.bgDirty) {
            this.rebuildDrawBGs();
        }
        // live comic panels -> canvases (they feed the 3D walls and the environment light)
        for (let k = 0; k < this.walls.length; k++) {
            let w = this.walls[k];
            let c = w.canvas;
            let inst = w.inst;
            if (c != null && inst != null && (w.p > 0.002 || this.introT < 0.2) && (this.dbgOff & 16) == 0) {
                let r = c.beginFrame(0);
                if (r != null) {
                    r.save();
                    r.transform(Mat2D.withUniformScale(<f32>WALL_SCALE));
                    inst.draw(r);
                    r.restore();
                    c.endFrame();
                }
            }
        }
        let lc = this.ledCanvas;
        let ledi = this.ledInst;
        if (lc != null && ledi != null && (this.dbgOff & 32) == 0) {
            let r = lc.beginFrame(0);
            if (r != null) {
                ledi.draw(r);
                lc.endFrame();
            }
        }
        let vcv = this.visorCanvas;
        let vsi = this.visorInst;
        let visorDue = this.visorLive || this.visorForce || this.time < this.visorHoldT || this.time - this.visorDrawT > 0.25 || this.time < this.visorDrawT;
        if (vcv != null && vsi != null && (this.dbgOff & 64) == 0 && visorDue) {
            this.visorForce = false;
            this.visorDrawT = this.time;
            this.visorDraws++;
            let r = vcv.beginFrame(0);
            if (r != null) {
                r.save();
                r.transform(Mat2D.withUniformScale(<f32>this.outScale));
                vsi.draw(r);
                r.restore();
                vcv.endFrame();
            }
        }
        this.renderEnv();
        let b = this.scratch;
        let all = this.allDraws();
        // per-draw uniforms: main, reflection, height
        for (let i = 0; i < all.length; i++) {
            let d = all[i];
            this.writeDraw(d, d.ubo!, this.viewProj, this.eyeY, false);
            this.writeDraw(d, d.uboR!, this.viewProjR, -this.eyeY, false);
            if (this.hgtDirty) {
                this.writeDraw(d, d.uboH!, this.viewProj, this.eyeY, true);
            }
        }

        // 1. contact-shadow height map
        if (F_HGT && this.hgtDirty && this.hgtPass != null) {
            let hp = gpu.beginRenderPass(this.hgtPass!);
            hp.setPipeline(this.hgtPipe!);
            for (let i = 0; i < this.draws.length; i++) {
                let d = this.draws[i];
                let bg = d.bgH;
                if (bg == null) {
                    continue;
                }
                hp.setBindGroup(0, bg);
                hp.setVertexBuffer(0, d.mesh.vbuf!);
                hp.setIndexBuffer(d.mesh.ibuf!, <u32>IndexFormat.uint32);
                hp.drawIndexed(<u32>d.mesh.icount);
            }
            hp.finish();
            this.hgtDirty = false;
        }
        // 2. planar reflection
        let rp = gpu.beginRenderPass(this.reflPass!);
        rp.setPipeline(this.carPipeR!);
        if (F_REFL && this.gfxRefl && (this.dbgOff & 128) == 0) {
            this.drawCar(rp, true);
        }
        rp.finish();
        for (let m = 0; m < this.reflMipPasses.length; m++) {   // cheap; keeps the chain defined (cleared) when off
            let mp = gpu.beginRenderPass(this.reflMipPasses[m]);
            mp.setPipeline(this.mip16Pipe!);
            mp.setBindGroup(0, this.reflMipBGs[m]);
            mp.draw(3);
            mp.finish();
        }
        // 3a. backdrop uniforms (+ the reduced-resolution backdrop trace)
        this.writeEnvCommon();
        // w >= 1: backdrop (skips the UI panels, drawn for real); w = 2: Balanced / Fast use a coarser lake-reflection march
        this.v4(32, this.up, this.wallLight, this.nightK, <f64>(1 | (this.gfxQ >= 1 ? 2 : 0) | (this.dbgOff & 12)));
        this.invViewProj.writeToBuffer(b, 208);
        this.v4(272, this.eyeX, this.eyeY, this.eyeZ, this.exposure);
        this.skyUbo!.update(0, b, ENV_UBO, 0);
        if (this.bgLo && (this.dbgOff & 2) == 0) {
            let lp = gpu.beginRenderPass(this.bgLoPass!);
            lp.setPipeline(this.skyPipeLo!);
            lp.setBindGroup(0, this.skyBGLo!);
            lp.draw(3);
            lp.finish();
        }
        // 3. scene
        let pass = gpu.beginRenderPass(this.scenePass!);
        pass.setPipeline(this.carPipe!);
        if (F_CAR && (this.dbgOff & 128) == 0) {
            this.drawCar(pass, false);
        }
        // floor
        let fm = Mat4.identity();
        Mat4.multiply(this.mvp, this.viewProj, fm);
        this.mvp.writeToBuffer(b, 0);
        fm.writeToBuffer(b, 64);
        this.v4(128, 0.5, 0.5, 0.5, this.nightK);
        this.v4(144, 0.4, 0, 0, 0);
        this.v4(160, 1, 0, this.exposure, this.time);
        this.v4(176, this.eyeX, this.eyeY, this.eyeZ, <f64>(ENV_MIPS - 1));
        this.v4(256, 0, 0, 3.6, 3.6);
        this.v4(272, 1 / <f64>this.tw, 1 / <f64>this.th, this.gfxRefl ? 0.6 : 0.0, 0.13);
        this.writeKey();
        this.writeWallLights();
        this.floorUbo!.update(0, b, UBO_SIZE, 0);
        if (F_FLOOR && (this.dbgOff & 256) == 0) {
            pass.setPipeline(this.floorPipe!);
            pass.setBindGroup(0, this.floorBG!);
            pass.setVertexBuffer(0, this.floor.vbuf!);
            pass.setIndexBuffer(this.floor.ibuf!, <u32>IndexFormat.uint32);
            pass.drawIndexed(6);
        }
        // backdrop: the studio traced from the camera (full res, or composited from the reduced-res target)
        if (this.bgLo) {
            this.v4(0, 1 / <f64>this.tw, 1 / <f64>this.th, 0, 0);
            this.compUbo!.update(0, b, 16, 0);
            pass.setPipeline(this.bgCompPipe!);
            pass.setBindGroup(0, this.compBG!);
        } else {
            pass.setPipeline(this.skyPipe!);
            pass.setBindGroup(0, this.skyBG!);
        }
        if ((this.dbgOff & 2) == 0) {
            pass.draw(3);
        }
        // glass last
        pass.setPipeline(this.glassPipe!);
        for (let i = 0; i < (F_GLASS ? this.glassDraws.length : 0); i++) {
            let d = this.glassDraws[i];
            let bg = d.bg;
            if (bg == null) {
                continue;
            }
            pass.setBindGroup(0, bg);
            pass.setVertexBuffer(0, d.mesh.vbuf!);
            pass.setIndexBuffer(d.mesh.ibuf!, <u32>IndexFormat.uint32);
            pass.drawIndexed(<u32>d.mesh.icount);
        }
        pass.finish();
        // 4. bloom
        let bloomOn = F_BLOOM && this.gfxBloom && (this.dbgOff & 512) == 0;
        for (let k = 0; k < (bloomOn ? BLOOM_LEVELS : 0); k++) {
            let sw = k == 0 ? <f64>this.tw : this.bloomW[k - 1];
            let sh = k == 0 ? <f64>this.th : this.bloomH[k - 1];
            this.v4(0, 1 / sw, 1 / sh, this.time, 0);
            this.v4(16, 1.2, 0.6, 0, 0);
            this.v4(32, 0, 1, 0, 0);
            this.bloomDownUbos[k].update(0, b, 48, 0);
            let p = gpu.beginRenderPass(this.bloomDownPasses[k]);
            p.setPipeline(k == 0 ? this.brightPipe! : this.bdownPipe!);
            p.setBindGroup(0, this.bloomDownBGs[k]);
            p.draw(3);
            p.finish();
        }
        for (let j = 0; j < (bloomOn ? this.bloomUpPasses.length : 0); j++) {
            let k = BLOOM_LEVELS - 1 - j;
            this.v4(0, 1 / this.bloomW[k], 1 / this.bloomH[k], this.time, 0);
            this.bloomUpUbos[j].update(0, b, 48, 0);
            let p = gpu.beginRenderPass(this.bloomUpPasses[j]);
            p.setPipeline(this.bupPipe!);
            p.setBindGroup(0, this.bloomUpBGs[j]);
            p.draw(3);
            p.finish();
        }
        // 4b. frost chain for the glass panels
        for (let k = 0; k < (this.gfxBlur && (this.dbgOff & 512) == 0 ? this.frostPasses.length : 0); k++) {
            let sw = k == 0 ? <f64>this.tw : this.frostW[k - 1];
            let sh = k == 0 ? <f64>this.th : this.frostH[k - 1];
            this.v4(0, 1 / sw, 1 / sh, this.time, 0);
            this.frostUbos[k].update(0, b, 48, 0);
            let p = gpu.beginRenderPass(this.frostPasses[k]);
            p.setPipeline(this.bdownPipe!);
            p.setBindGroup(0, this.frostBGs[k]);
            p.draw(3);
            p.finish();
        }
        // 5. resolve
        this.v4(0, 1 / <f64>gpu.width, 1 / <f64>gpu.height, this.time, 0.32);
        this.v4(16, 1.2, 0.6, bloomOn ? 0.12 : 0.0, 1.2 / 255);
        this.v4(32, 0.012, 1.0, this.mbX, this.mbY);
        this.toneUbo!.update(0, b, 48, 0);
        let tp = gpu.beginRenderPass(this.tonePass!);
        tp.setPipeline(this.tonePipe!);
        tp.setBindGroup(0, this.toneBG!);
        tp.draw(3);
        if ((this.dbgOff & 1024) == 0) {
            this.drawPanels(tp);
        }
        this.drawVisor(tp);
        tp.finish();

        renderer.save();
        renderer.transform(Mat2D.withUniformScale(<f32>(1 / this.outScale)));
        renderer.drawImage(gpu.image, this.imgSampler, BlendMode.srcOver, 1);
        renderer.restore();
        this.drawCallouts(renderer);
    }
}
