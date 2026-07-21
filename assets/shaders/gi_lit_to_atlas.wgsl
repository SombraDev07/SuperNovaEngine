// Lit buffer → atlas with temporal blend from history atlas.

struct Uniforms {
    dims: vec4<f32>,
    atlas: vec4<f32>,
    /// x=temporal blend keep, y=enabled
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> lit_rgb: array<u32>;
@group(0) @binding(2) var<storage, read> lit_w: array<u32>;
@group(0) @binding(3) var hist_atlas: texture_2d<f32>;
@group(0) @binding(4) var atlas_out: texture_storage_2d<rgba16float, write>;

fn voxelIndex(clip: u32, ix: u32, iy: u32, iz: u32) -> u32 {
    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    return ix + iy * rx + iz * rx * ry + clip * rx * ry * rx;
}

fn unpackRgb(p: u32) -> vec3<f32> {
    let r = f32(p & 0x3FFu) / 16.0;
    let g = f32((p >> 10u) & 0x3FFu) / 16.0;
    let b = f32((p >> 20u) & 0x3FFu) / 16.0;
    return vec3<f32>(r, g, b);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let aw = u32(u.dims.w);
    let ah = u32(u.atlas.x);
    if (gid.x >= aw || gid.y >= ah) { return; }

    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    let spr = u32(max(u.atlas.y, 1.0));
    let tile_row = gid.y / ry;
    let iy = gid.y % ry;
    let tile_col = gid.x / rx;
    let ix = gid.x % rx;
    let slice = tile_row * spr + tile_col;
    let nclips = u32(u.dims.z);
    let clip = slice / rx;
    let iz = slice % rx;
    let hist = textureLoad(hist_atlas, vec2<i32>(i32(gid.x), i32(gid.y)), 0);

    if (clip >= nclips || ix >= rx || iy >= ry || iz >= rx) {
        textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), hist);
        return;
    }
    let idx = voxelIndex(clip, ix, iy, iz);
    let w = lit_w[idx];
    let keep = clamp(u.params.x, 0.5, 0.98);
    if (w == 0u) {
        textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), hist);
        return;
    }
    let neu = unpackRgb(lit_rgb[idx]);
    let outc = mix(neu, hist.rgb, keep);
    let alpha = saturate(hist.a + 0.15);
    textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(outc, alpha));
}
