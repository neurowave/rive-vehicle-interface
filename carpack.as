// carpack.as — loader for the hero-car mesh pack ("RCP2", written by tools/export_car.py).
//
// Vertex = 20 bytes: pos snorm16x4 (scaled by the pack half-extent), normal octahedral snorm16x2,
// uv unorm16x2 (per-mesh uv range), ao + spare unorm8x4. Indices are u32.

import { Buffer } from "rive/buffer";
import { GPUBuffer } from "rive/gpu";
import { BufferUsage } from "rive/gpu_enums";

export class CarMesh {
    name: string = "";
    part: i32 = 0; // 0 body, 1..4 wheels FL FR RL RR
    vcount: i32 = 0;
    icount: i32 = 0;
    u0: f64 = 0;
    v0: f64 = 0;
    u1: f64 = 1;
    v1: f64 = 1;
    vdata: ArrayBuffer;
    idata: ArrayBuffer;
    vbuf: GPUBuffer? = null;
    ibuf: GPUBuffer? = null;

    constructor(vdata: ArrayBuffer, idata: ArrayBuffer) {
        this.vdata = vdata;
        this.idata = idata;
    }

    upload(): void {
        if (this.vbuf == null) {
            this.vbuf = new GPUBuffer(BufferUsage.vertex, <u32>this.vdata.byteLength, this.vdata, true);
            this.ibuf = new GPUBuffer(BufferUsage.index, <u32>this.idata.byteLength, this.idata, true);
        }
    }
}

export class CarPack {
    hx: f64 = 1;
    hy: f64 = 1;
    hz: f64 = 1;
    meshes: Array<CarMesh> = [];
    // wheel pivots (x, y, z) and radius
    wx: Array<f64> = [];
    wy: Array<f64> = [];
    wz: Array<f64> = [];
    wr: f64 = 0.39;
}

// Streaming reader: the header (extents, wheel pivots) is read at once, the meshes one at a time, so
// a large pack never parses inside a single script call (each call has a ~200 ms watchdog).
export class CarReader {
    b: ArrayBuffer;
    pack: CarPack = new CarPack();
    count: i32 = 0;
    next: i32 = 0;
    o: i32 = 0;

    constructor(b: ArrayBuffer) {
        this.b = b;
        let out = this.pack;
        this.count = <i32>Buffer.readu32(b, 4);
        out.hx = Buffer.readf32(b, 8);
        out.hy = Buffer.readf32(b, 12);
        out.hz = Buffer.readf32(b, 16);
        let o: i32 = 32;
        let nw = <i32>Buffer.readu32(b, o);
        o += 16;
        for (let k = 0; k < nw; k++) {
            out.wx.push(Buffer.readf32(b, o));
            out.wy.push(Buffer.readf32(b, o + 4));
            out.wz.push(Buffer.readf32(b, o + 8));
            out.wr = Buffer.readf32(b, o + 12);
            o += 16;
        }
        this.o = o;
    }

    done(): bool {
        return this.next >= this.count;
    }

    // parse the next mesh, append it to the pack and return it
    read(): CarMesh {
        let b = this.b;
        let o = this.o;
        let z = 0;
        while (z < 32 && Buffer.readu8(b, o + z) != 0) {
            z++;
        }
        let name = Buffer.readstring(b, o, z);
        o += 32;
        let part = <i32>Buffer.readu32(b, o);
        let vc = <i32>Buffer.readu32(b, o + 4);
        let ic = <i32>Buffer.readu32(b, o + 8);
        let u0 = Buffer.readf32(b, o + 16);
        let v0 = Buffer.readf32(b, o + 20);
        let u1 = Buffer.readf32(b, o + 24);
        let v1 = Buffer.readf32(b, o + 28);
        o += 32;
        let vd = b.slice(o, o + vc * 20);
        o += vc * 20;
        let id = b.slice(o, o + ic * 4);
        o += ic * 4;
        let m = new CarMesh(vd, id);
        m.name = name;
        m.part = part;
        m.vcount = vc;
        m.icount = ic;
        m.u0 = u0;
        m.v0 = v0;
        m.u1 = u1;
        m.v1 = v1;
        this.pack.meshes.push(m);
        this.o = o;
        this.next++;
        return m;
    }
}

export function openCar(b: ArrayBuffer): CarReader? {
    if (b.byteLength < 48 || Buffer.readstring(b, 0, 4) != "RCP2") {
        return null;
    }
    return new CarReader(b);
}
