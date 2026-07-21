// daGI2 WorldSDF markFromGbuffer — seed surface voxels (JFA dilates afterward).

struct Uniforms {
    inv_view_proj: mat4x4<f32>,
    clip0: vec4<f32>,
    clip1: vec4<f32>,
    clip2: vec4<f32>,
    clip3: vec4<f32>,
    dims: vec4<f32>,
    screen: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var depth_tex: texture_depth_2d;
@group(0) @binding(2) var<storage, read_write> sdf_u: array<atomic<u32>>;

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn reconstructWorldPos(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let world = ndc * u.inv_view_proj;
    return world.xyz / max(world.w, 1e-5);
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
    let budget = u32(max(u.screen.z, 1.0) * 8192.0);
    if (id >= budget) { return; }

    let dims = max(u.screen.xy, vec2<f32>(1.0));
    let h = hash2(vec2<f32>(f32(id), u.dims.w));
    let h2 = hash2(vec2<f32>(u.dims.w, f32(id) * 1.7));
    let uv = vec2<f32>(h, h2);
    let pixel = vec2<i32>(clamp(uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
    let depth = textureLoad(depth_tex, pixel, 0);
    if (depth >= 0.9995) { return; }

    let world = reconstructWorldPos(uv, depth);
    let rx = u.dims.x;
    let ry = u.dims.y;
    let nclips = u32(u.dims.z);

    var best_c = nclips;
    for (var c = 0u; c < 4u; c++) {
        if (c >= nclips) { break; }
        let cv = clipOriginVoxel(c);
        let ext = vec3<f32>(rx, ry, rx) * cv.w;
        let local = world - cv.xyz;
        if (all(local >= vec3<f32>(0.0)) && all(local < ext)) {
            best_c = c;
            break;
        }
    }
    if (best_c >= nclips) { return; }

    let cv = clipOriginVoxel(best_c);
    let vs = max(cv.w, 0.05);
    let local = (world - cv.xyz) / vs;
    let ix = u32(clamp(floor(local.x), 0.0, rx - 1.0));
    let iy = u32(clamp(floor(local.y), 0.0, ry - 1.0));
    let iz = u32(clamp(floor(local.z), 0.0, rx - 1.0));

    // Seed surface + 1-ring (JFA fills the band).
    for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
            for (var dz = -1; dz <= 1; dz++) {
                let fx = i32(ix) + dx;
                let fy = i32(iy) + dy;
                let fz = i32(iz) + dz;
                if (fx < 0 || fy < 0 || fz < 0 || fx >= i32(rx) || fy >= i32(ry) || fz >= i32(rx)) {
                    continue;
                }
                let dist = length(vec3<f32>(f32(dx), f32(dy), f32(dz)));
                let enc = u32(saturate(dist / max(u.screen.w, 1.0)) * 65535.0);
                let idx = voxelIndex(best_c, u32(fx), u32(fy), u32(fz));
                atomicMin(&sdf_u[idx], enc);
            }
        }
    }
}
