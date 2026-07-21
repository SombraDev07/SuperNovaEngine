// daGI2 ScreenSpaceProbes *role* — Phase B.
// Tile probes: hemisphere screen-space rays → irradiance (low-res).

struct Uniforms {
    inv_view_proj: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    /// xy = full screen size, zw = near/far
    screen: vec4<f32>,
    /// x=temporal, y=intensity unused here, z=frame, w=tile_size
    params: vec4<f32>,
    /// x=ray_steps, y=max_ray_m, z=enabled, w=rays
    budget: vec4<f32>,
    sun_dir: vec4<f32>,
    sun_color: vec4<f32>,
    camera_pos: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var depth_tex: texture_depth_2d;
@group(0) @binding(3) var normal_tex: texture_2d<f32>;
@group(0) @binding(4) var albedo_tex: texture_2d<f32>;
@group(0) @binding(5) var hist_tex: texture_2d<f32>;
@group(0) @binding(6) var prev_hdr_tex: texture_2d<f32>;
@group(0) @binding(7) var env_cube: texture_cube<f32>;
@group(0) @binding(8) var env_samp: sampler;
@group(0) @binding(9) var hzb_tex: texture_2d<f32>;

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
    var out: VsOut;
    let x = f32(i32(vid & 1u) * 4 - 1);
    let y = f32(i32(vid & 2u) * 2 - 1);
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    out.uv = vec2<f32>(x, y) * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    return out;
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

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn basis(n: vec3<f32>) -> mat3x3<f32> {
    let up = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.9);
    let t = normalize(cross(up, n));
    let b = cross(n, t);
    return mat3x3<f32>(t, b, n);
}

fn hemisphere(u1: f32, u2: f32) -> vec3<f32> {
    let r = sqrt(u1);
    let phi = 6.2831853 * u2;
    let x = r * cos(phi);
    let y = r * sin(phi);
    let z = sqrt(max(1.0 - u1, 0.0));
    return vec3<f32>(x, y, z);
}

fn sampleSky(dir: vec3<f32>) -> vec3<f32> {
    return textureSampleLevel(env_cube, env_samp, dir, 3.0).rgb;
}

fn ssTrace(origin: vec3<f32>, dir: vec3<f32>, max_dist: f32, steps: i32, jitter: f32) -> vec4<f32> {
    // HZB-accelerated screen cast (daGI2 cast_screenspace_hzb_ray role).
    let dims = max(u.screen.xy, vec2<f32>(1.0));
    let hzb_dims = vec2<f32>(textureDimensions(hzb_tex));
    for (var i = 0; i < 24; i++) {
        if (i >= steps) { break; }
        let t = (f32(i) + 0.35 + jitter) / f32(steps) * max_dist;
        let p = origin + dir * t;
        let clip = vec4<f32>(p, 1.0) * u.view_proj;
        if (clip.w <= 1e-4) { continue; }
        let ndc = clip.xyz / clip.w;
        if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z <= 0.0 || ndc.z >= 1.0) {
            continue;
        }
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        let hp = vec2<i32>(clamp(uv * hzb_dims, vec2<f32>(0.0), hzb_dims - vec2<f32>(1.0)));
        let hzb_z = textureLoad(hzb_tex, hp, 0).r;
        if (ndc.z > hzb_z + 0.002 && hzb_z > 1e-4) { continue; }

        let pixel = vec2<i32>(clamp(uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
        let depth = textureLoad(depth_tex, pixel, 0);
        if (depth >= 0.9999) { continue; }
        let scene_pos = reconstructWorldPos(uv, depth);
        let scene_dist = length(scene_pos - origin);
        if (scene_dist < 0.05 || scene_dist > max_dist * 1.2) { continue; }
        let align = dot(normalize(scene_pos - origin), dir);
        if (align < 0.55) { continue; }
        if (scene_dist > t + 0.35) { continue; }

        var rad = textureSampleLevel(prev_hdr_tex, samp, uv, 0.0).rgb;
        let lum = dot(rad, vec3<f32>(0.2126, 0.7152, 0.0722));
        if (lum < 0.002) {
            let albedo = textureSampleLevel(albedo_tex, samp, uv, 0.0).rgb;
            let n = decodeOct(textureSampleLevel(normal_tex, samp, uv, 0.0).xy);
            let ndl = max(dot(n, u.sun_dir.xyz), 0.0);
            rad = albedo * (u.sun_color.xyz * ndl + vec3<f32>(u.sun_color.w));
        }
        return vec4<f32>(rad, 1.0);
    }
    return vec4<f32>(sampleSky(dir), 0.0);
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let hist = textureSampleLevel(hist_tex, samp, in.uv, 0.0);
    if (u.budget.z < 0.5) {
        return hist;
    }

    let full = max(u.screen.xy, vec2<f32>(1.0));
    // Low-res probe RT: UV maps 1:1 to screen UV (each texel = one tile).
    let probe_dims = vec2<f32>(textureDimensions(hist_tex));
    let full_uv = (floor(in.uv * probe_dims) + 0.5) / probe_dims;
    let dims = full;
    let pixel = vec2<i32>(clamp(full_uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
    let depth = textureLoad(depth_tex, pixel, 0);
    if (depth >= 0.9999) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }

    let n = decodeOct(textureSampleLevel(normal_tex, samp, full_uv, 0.0).xy);
    let world = reconstructWorldPos(full_uv, depth);
    let origin = world + n * 0.04;
    let tbn = basis(n);

    let rays = i32(clamp(u.budget.w, 4.0, 16.0));
    let steps = i32(clamp(u.budget.x, 8.0, 24.0));
    let max_dist = clamp(u.budget.y, 1.0, 12.0);
    let frame = u.params.z;

    var irr = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var r = 0; r < 16; r++) {
        if (r >= rays) { break; }
        let u1 = hash2(in.uv * 97.0 + vec2<f32>(f32(r), frame * 0.17));
        let u2 = hash2(in.uv * 41.0 + vec2<f32>(frame, f32(r) * 3.1));
        let local = hemisphere(u1, u2);
        let dir = normalize(tbn * local);
        let jitter = hash2(in.uv + vec2<f32>(f32(r), frame));
        let hit = ssTrace(origin, dir, max_dist, steps, jitter);
        let w = local.z + 0.05;
        irr += hit.rgb * w;
        wsum += w;
    }
    irr = irr / max(wsum, 1e-4);

    let blend = clamp(u.params.x, 0.5, 0.97);
    let hist_ok = hist.a > 0.1;
    let out_rgb = select(irr, mix(irr, hist.rgb, blend), hist_ok);
    return vec4<f32>(max(out_rgb, vec3<f32>(0.0)), 1.0);
}
