// tex.as — JPEG/PNG blobs decoded at runtime into mipmapped GPU textures.
//
// The CLI hands us image bytes as BlobAssets; Context.decodeImage turns them into RGBA8, which is
// uploaded to mip 0 of a render-target texture. The rest of the chain is built on the GPU with a
// box-filter pass per level (tex.wgsl), so minified textures (tyres, pinstripes) don't shimmer.

import { Context, DecodedImage, ImageDecodeListener } from "rive/host";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import {
    GPUBindGroup, GPUBindGroupSampler, GPUBindGroupTexture, GPUBindGroupUBO, GPUBuffer, GPUCanvas, GPUColorAttachment, GPUPassDesc,
    GPUPipeline, GPUSampler, GPUTexture, GPUTextureDesc, GPUTextureView, GPUTextureViewDesc,
} from "rive/gpu";
import { LoadOp, StoreOp, TextureFormat, TextureViewDimension } from "rive/gpu_enums";

export class MipTex extends ImageDecodeListener {
    name: string;
    tex: GPUTexture? = null;
    view: GPUTextureView? = null;
    width: u32 = 0;
    height: u32 = 0;
    mips: u32 = 1;
    pending: DecodedImage? = null;
    failed: bool = false;
    ready: bool = false;
    half: GPUTexture? = null;

    constructor(name: string) {
        super();
        this.name = name;
    }

    override onImageDecoded(image: DecodedImage): void {
        this.pending = image;
    }

    override onImageDecodeFailed(message: string): void {
        this.failed = true;
    }

    start(ctx: Context): bool {
        let b = ctx.blob(this.name);
        if (b == null) {
            this.failed = true;
            return false;
        }
        ctx.decodeImage(b, this);
        return true;
    }

    // Called each frame from the GPU owner until ready; returns true when it did work.
    finish(gpu: GPUCanvas, pipe: GPUPipeline, samp: GPUSampler, fillUbo: GPUBuffer, fill2D: GPUTextureView): bool {
        let img = this.pending;
        if (img == null || this.ready) {
            return false;
        }
        let w = img.width;
        let h = img.height;
        let m: u32 = 1;
        let s = w > h ? w : h;
        while ((s >> m) > 0) {
            m++;
        }
        let d = new GPUTextureDesc();
        d.width = w;
        d.height = h;
        d.format = TextureFormat.rgba8unorm;
        d.renderTarget = true;
        d.numMipmaps = m;
        let t = new GPUTexture(d);
        // uploads into a render-target texture crash on Metal: stage through a plain texture and copy
        // it into mip 0 with a draw
        let sd = new GPUTextureDesc();
        sd.width = w;
        sd.height = h;
        sd.format = TextureFormat.rgba8unorm;
        let staging = new GPUTexture(sd);
        let region = new rive_gpu_texture_upload_v1();
        region.width = w;
        region.height = h;
        staging.upload(region, img.data);
        let stagingView = staging.view();
        // Box-filter chain through a half-size scratch: level k-1 -> scratch level k-1 (2x box), then
        // scratch -> level k (same size: exact bilinear copy). Never samples the texture being rendered,
        // which WebGL2 rejects as a feedback loop (the levels stayed black on the web).
        let hd = new GPUTextureDesc();
        hd.width = w > 1 ? w >> 1 : 1;
        hd.height = h > 1 ? h >> 1 : 1;
        hd.format = TextureFormat.rgba8unorm;
        hd.renderTarget = true;
        hd.numMipmaps = m > 1 ? m - 1 : 1;
        let half = new GPUTexture(hd);
        this.blit(gpu, pipe, samp, fillUbo, fill2D, stagingView, level(t, 0));
        for (let k: u32 = 1; k < m; k++) {
            this.blit(gpu, pipe, samp, fillUbo, fill2D, level(t, k - 1), level(half, k - 1));
            this.blit(gpu, pipe, samp, fillUbo, fill2D, level(half, k - 1), level(t, k));
        }
        this.half = half;
        this.tex = t;
        this.view = t.view();
        this.width = w;
        this.height = h;
        this.mips = m;
        this.ready = true;
        this.pending = null;
        return true;
    }

    blit(gpu: GPUCanvas, pipe: GPUPipeline, samp: GPUSampler, fillUbo: GPUBuffer, fill2D: GPUTextureView, src: GPUTextureView,
        dst: GPUTextureView): void {
        let a = new GPUColorAttachment();
        a.view = dst;
        a.loadOp = LoadOp.clear;
        a.storeOp = StoreOp.store;
        let p = new GPUPassDesc();
        p.color = [a];
        // post.wgsl's UBO (0) and bloom slot (3) are unused here but must be filled (CLI 1.7 / WebGPU)
        let bg = new GPUBindGroup(pipe.getBindGroupLayout(0), [new GPUBindGroupUBO(0, fillUbo)],
            [new GPUBindGroupTexture(1, src), new GPUBindGroupTexture(3, fill2D)], [new GPUBindGroupSampler(2, samp)]);
        let pass = gpu.beginRenderPass(p);
        pass.setPipeline(pipe);
        pass.setBindGroup(0, bg);
        pass.draw(3);
        pass.finish();
    }
}

function level(t: GPUTexture, k: u32): GPUTextureView {
    let d = new GPUTextureViewDesc();
    d.dimension = TextureViewDimension.texture2D;
    d.baseMipLevel = k;
    d.mipCount = 1;
    return t.view(d);
}
