// removeFromDepth / HZB occlusion — inflate SDF where geometry left (daGI2 role).

struct Uniforms {
    view_proj: mat4x4<f32>,
    clip0: vec4<f32>,
    clip1: vec4<f32>,
    clip2: vec4<f32>,
    clip3: vec4<f32>,
    /// x=res_xz y=res_y z=clips w=frame
    dims: vec4<f32>,
    /// xy=screen, z=budget, w=band
    screen: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var depth_tex: texture_depth_2d;
@group(0) @binding(2) var hzb_tex: texture_2d<f32>;
@group(0) @binding(3) var<storage, read_write> sdf_u: array<atomic<u32>>;

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

fn clipOriginVoxel(c: u32) -> vec4<f32> {
    if (c == 0u) { return u.clip0; }
    if (c == 1u) { return u.clip1; }
    if (c == 2u) { return u.clip2; }
    return u.clip3;
}

fn voxelIndex(clip: u32, ix: u32, iy: u32, iz: u32) -> u32 {
    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    return ix + iy * rx + iz * rx * ry + clip * rx * ry * rx;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let id = gid.x;
    let budget = u32(max(u.screen.z, 1.0) * 2048.0);
    if (id >= budget) { return; }

    let rx = u.dims.x;
    let ry = u.dims.y;
    let nclips = u32(u.dims.z);
    let h0 = hash2(vec2<f32>(f32(id), u.dims.w));
    let h1 = hash2(vec2<f32>(u.dims.w, f32(id) * 2.1));
    let h2 = hash2(vec2<f32>(f32(id) * 0.5, h0));
    let clip = u32(h0 * f32(nclips)) % nclips;
    let ix = u32(h1 * rx) % u32(rx);
    let iy = u32(h2 * ry) % u32(ry);
    let iz = u32(hash2(vec2<f32>(h1, h2)) * rx) % u32(rx);

    let idx = voxelIndex(clip, ix, iy, iz);
    let enc = atomicLoad(&sdf_u[idx]);
    let d_norm = f32(enc) / 65535.0;
    // Only touch near-surface voxels.
    if (d_norm > 0.35) { return; }

    let cv = clipOriginVoxel(clip);
    let vs = max(cv.w, 0.05);
    let world = cv.xyz + (vec3<f32>(f32(ix), f32(iy), f32(iz)) + 0.5) * vs;
    let clip4 = vec4<f32>(world, 1.0) * u.view_proj;
    if (clip4.w <= 1e-4) { return; }
    let ndc = clip4.xyz / clip4.w;
    if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z <= 0.0 || ndc.z >= 1.0) {
        // Outside frustum → slowly forget
        let inflated = min(enc + 2048u, 65535u);
        atomicMax(&sdf_u[idx], inflated);
        return;
    }
    let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let dims = max(u.screen.xy, vec2<f32>(1.0));
    let pixel = vec2<i32>(clamp(uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
    let depth = textureLoad(depth_tex, pixel, 0);
    let hzb_dims = vec2<f32>(textureDimensions(hzb_tex));
    let hp = vec2<i32>(clamp(uv * hzb_dims, vec2<f32>(0.0), hzb_dims - vec2<f32>(1.0)));
    let hzb_z = textureLoad(hzb_tex, hp, 0).r;

    // Geometry gone / much farther than this voxel's depth → inflate SDF.
    let gone = depth >= 0.9995 || (hzb_z > 1e-4 && ndc.z + 0.02 < hzb_z);
    if (gone) {
        let inflated = min(enc + 4096u, 65535u);
        atomicMax(&sdf_u[idx], inflated);
    }
}
