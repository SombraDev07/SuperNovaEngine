struct Uniforms {
    dims: vec4<f32>,
    atlas: vec4<f32>,
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> alb_rgb: array<u32>;
@group(0) @binding(2) var<storage, read> alb_w: array<u32>;
@group(0) @binding(3) var hist_atlas: texture_2d<f32>;
@group(0) @binding(4) var atlas_out: texture_storage_2d<rgba16float, write>;

fn voxelIndex(clip: u32, ix: u32, iy: u32, iz: u32) -> u32 {
    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    return ix + iy * rx + iz * rx * ry + clip * rx * ry * rx;
}

fn unpackRgb(p: u32) -> vec3<f32> {
    return vec3<f32>(
        f32(p & 0xFFu) / 255.0,
        f32((p >> 8u) & 0xFFu) / 255.0,
        f32((p >> 16u) & 0xFFu) / 255.0,
    );
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
    let w = alb_w[idx];
    let keep = clamp(u.params.x, 0.5, 0.98);
    if (w == 0u) {
        textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), hist);
        return;
    }
    let neu = unpackRgb(alb_rgb[idx]);
    let outc = mix(neu, hist.rgb, keep);
    textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(outc, saturate(hist.a + 0.2)));
}
