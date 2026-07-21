// Copy atomic SDF buffer → 2D atlas (r channel = encoded 0..1 distance).

struct Uniforms {
    /// x=res_xz, y=res_y, z=clips, w=atlas_w
    dims: vec4<f32>,
    /// x=atlas_h, y=slices_per_row, z=band, w=unused
    atlas: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> sdf_u: array<u32>;
@group(0) @binding(2) var atlas_out: texture_storage_2d<rgba16float, write>;

fn voxelIndex(clip: u32, ix: u32, iy: u32, iz: u32) -> u32 {
    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    return ix + iy * rx + iz * rx * ry + clip * rx * ry * rx;
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
    if (clip >= nclips || ix >= rx || iy >= ry || iz >= rx) {
        textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(1.0, 0.0, 0.0, 1.0));
        return;
    }
    let idx = voxelIndex(clip, ix, iy, iz);
    let enc = sdf_u[idx];
    let d = f32(enc) / 65535.0;
    textureStore(atlas_out, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(d, d, d, 1.0));
}
