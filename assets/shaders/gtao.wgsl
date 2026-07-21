// Ground Truth AO — Jimenez "Practical Realtime Strategies for Accurate Indirect Occlusion".
// Dagor GTAORenderer / gtao_main role. Outputs RG16: R=AO, G=depth (for bilateral/temporal).

struct Uniforms {
    inv_view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
    /// x=radius_m, y=power, z=thickness, w=strength
    params: vec4<f32>,
    /// xy=screen size, z=near, w=far
    screen: vec4<f32>,
    /// x=proj_scale (0.5*h/tanHalfFov), y=sample_offset, z=slice_count, w=step_count
    proj: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var depth_tex: texture_depth_2d;
@group(0) @binding(3) var normal_oct_tex: texture_2d<f32>;

const PI: f32 = 3.14159265;
const HALF_PI: f32 = 1.5707963;

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

fn interleavedGradientNoise(p: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(p, vec2<f32>(0.06711056, 0.00583715))));
}

/// Cos-weighted visibility for one GTAO slice (angles in radians).
fn integrateArc(h1: f32, h2: f32, n: f32) -> f32 {
    let cos_n = cos(n);
    let sin_n = sin(n);
    return 0.25 * (
        (-cos(2.0 * h1 - n) + cos_n + 2.0 * h1 * sin_n) +
        (-cos(2.0 * h2 - n) + cos_n + 2.0 * h2 * sin_n)
    );
}

/// Search one side of a slice; returns max horizon cosine vs view-to-camera.
fn searchHorizon(
    uv: vec2<f32>,
    view_pos: vec3<f32>,
    view_dir: vec3<f32>,
    ss_dir: vec2<f32>,
    radius_ss: f32,
    steps: i32,
    step_offset: f32,
    radius_ws: f32,
    thickness: f32,
) -> f32 {
    var best = -1.0;
    let texel = 1.0 / u.screen.xy;
    for (var i = 0; i < 8; i++) {
        if (i >= steps) { break; }
        let s = (f32(i) + step_offset) / f32(steps);
        let suv = uv + ss_dir * (radius_ss * s) * texel;
        if (any(suv < vec2<f32>(0.0)) || any(suv > vec2<f32>(1.0))) { continue; }

        let spixel = vec2<i32>(clamp(suv * u.screen.xy, vec2<f32>(0.0), u.screen.xy - vec2<f32>(1.0)));
        let sd = textureLoad(depth_tex, spixel, 0);
        if (sd >= 0.9999) { continue; }

        let sworld = reconstructWorldPos(suv, sd);
        let sview = (vec4<f32>(sworld, 1.0) * u.view).xyz;
        var delta = sview - view_pos;
        let dist = length(delta);
        if (dist < 1e-4 || dist > radius_ws) { continue; }
        delta *= 1.0 / dist;

        // Thickness: ignore samples that pass through thin geometry.
        let t_fall = saturate(1.0 - dist / radius_ws);
        let side = saturate(dot(delta, view_dir) + thickness);
        let cos_h = dot(delta, view_dir);
        best = max(best, mix(-1.0, cos_h, t_fall * side));
    }
    return best;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let dims = u.screen.xy;
    let pixel = vec2<i32>(in.uv * dims);
    let depth = textureLoad(depth_tex, pixel, 0);
    if (depth >= 0.9999) {
        return vec4<f32>(1.0, depth, 0.0, 1.0);
    }

    let world_pos = reconstructWorldPos(in.uv, depth);
    let view_pos = (vec4<f32>(world_pos, 1.0) * u.view).xyz;
    let view_z = max(abs(view_pos.z), 1e-3);
    let view_dir = normalize(-view_pos); // toward camera (origin)

    let n_world = decodeOct(textureLoad(normal_oct_tex, pixel, 0).xy);
    var n_view = normalize((vec4<f32>(n_world, 0.0) * u.view).xyz);
    // Face toward camera.
    if (dot(n_view, view_dir) < 0.0) {
        n_view = -n_view;
    }

    let radius = max(u.params.x, 0.05);
    let power = max(u.params.y, 0.01);
    let thickness = u.params.z;
    let strength = u.params.w;
    let proj_scale = max(u.proj.x, 1.0);
    let sample_off = u.proj.y;
    let slice_count = max(i32(u.proj.z), 1);
    let step_count = max(i32(u.proj.w), 1);

    let radius_ss = clamp((radius * proj_scale) / view_z, 4.0, min(dims.x, dims.y) * 0.35);
    let noise = interleavedGradientNoise(in.uv * dims + vec2<f32>(sample_off * 17.0, sample_off * 9.0));
    let step_noise = fract(noise * 7.13 + 0.37);

    var vis = 0.0;
    for (var slice = 0; slice < 8; slice++) {
        if (slice >= slice_count) { break; }
        let phi = (f32(slice) + noise) * PI / f32(slice_count);
        let omega = vec2<f32>(cos(phi), sin(phi));

        // Slice direction in view space (screen XY ≈ view XY for perspective).
        let slice_dir = vec3<f32>(omega.x, omega.y, 0.0);

        let cos_h1 = searchHorizon(in.uv, view_pos, view_dir, omega, radius_ss, step_count, step_noise, radius, thickness);
        let cos_h2 = searchHorizon(in.uv, view_pos, view_dir, -omega, radius_ss, step_count, step_noise, radius, thickness);

        var h1 = -acos(clamp(cos_h1, -1.0, 1.0));
        var h2 = acos(clamp(cos_h2, -1.0, 1.0));

        // Project normal onto the slice plane spanned by (slice_dir, view_dir).
        let plane_n = n_view - slice_dir * dot(n_view, slice_dir);
        let plane_len = length(plane_n);
        var n_angle = 0.0;
        if (plane_len > 1e-4) {
            let pn = plane_n / plane_len;
            n_angle = -asin(clamp(dot(pn, slice_dir), -1.0, 1.0));
            // Align with view_dir component for hemisphere.
            let cos_nv = clamp(dot(pn, view_dir), -1.0, 1.0);
            n_angle = sign(dot(pn, cross(view_dir, slice_dir))) * acos(cos_nv);
        }

        h1 = n_angle + clamp(h1 - n_angle, -HALF_PI, HALF_PI);
        h2 = n_angle + clamp(h2 - n_angle, -HALF_PI, HALF_PI);

        vis += integrateArc(h1, h2, n_angle);
    }
    vis /= f32(slice_count);

    var ao = clamp(vis, 0.0, 1.0);
    ao = pow(ao, power);
    ao = mix(1.0, ao, saturate(strength));
    return vec4<f32>(ao, depth, 0.0, 1.0);
}
