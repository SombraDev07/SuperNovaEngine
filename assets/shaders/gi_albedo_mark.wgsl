// daGI2 AlbedoScene markFromGbuffer — sparse albedo for lit-miss fallback.

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
@group(0) @binding(2) var albedo_tex: texture_2d<f32>;
@group(0) @binding(3) var normal_tex: texture_2d<f32>;
@group(0) @binding(4) var<storage, read_write> alb_rgb: array<atomic<u32>>;
@group(0) @binding(5) var<storage, read_write> alb_w: array<atomic<u32>>;

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn decodeOct(e_in: vec2<f32>) -> vec3<f32> {
    let e = e_in * 2.0 - 1.0;
    var n = vec3<f32>(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    let t = max(-n.z, 0.0);
    n.x += select(t, -t, n.x >= 0.0);
    n.y += select(t, -t, n.y >= 0.0);
    return normalize(n);
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

fn packRgb(c: vec3<f32>) -> u32 {
    let r = u32(clamp(c.r, 0.0, 1.0) * 255.0);
    let g = u32(clamp(c.g, 0.0, 1.0) * 255.0);
    let b = u32(clamp(c.b, 0.0, 1.0) * 255.0);
    // Pack dominant normal axis in high bits for anisotropic sample (0=x,1=y,2=z).
    return (r & 0xFFu) | ((g & 0xFFu) << 8u) | ((b & 0xFFu) << 16u);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let id = gid.x;
    let budget = u32(max(u.screen.z, 1.0) * 2048.0);
    if (id >= budget) { return; }

    let dims = max(u.screen.xy, vec2<f32>(1.0));
    let uv = vec2<f32>(hash2(vec2<f32>(f32(id), u.dims.w)), hash2(vec2<f32>(u.dims.w, f32(id))));
    let pixel = vec2<i32>(clamp(uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
    let depth = textureLoad(depth_tex, pixel, 0);
    if (depth >= 0.9995) { return; }

    let world = reconstructWorldPos(uv, depth);
    let albedo = textureLoad(albedo_tex, pixel, 0).rgb;
    let n = decodeOct(textureLoad(normal_tex, pixel, 0).xy);
    _ = n;

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
    let idx = voxelIndex(best_c, ix, iy, iz);
    atomicStore(&alb_rgb[idx], packRgb(albedo));
    atomicAdd(&alb_w[idx], 1u);
}
