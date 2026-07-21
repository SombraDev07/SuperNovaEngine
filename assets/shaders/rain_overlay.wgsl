// CryEngine-style rain: streaks with roof occlusion + localized floor puddles.
// Fixes: no uniform “mirror sheet”, sharp poças, less rain under cover.

struct RainUniforms {
    params0: vec4<f32>,      // intensity, drops_amount, drops_speed, drops_size
    params1: vec4<f32>,      // spatter, wetness, puddle_scale, lightning
    wind_time: vec4<f32>,    // wind.xz, wind_influence, time
    screen: vec4<f32>,       // w, h, near, far
    camera_pos: vec4<f32>,
    inv_view_proj: mat4x4<f32>,
    view_proj: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> u: RainUniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var depth_tex: texture_depth_2d;
@group(0) @binding(3) var normal_oct_tex: texture_2d<f32>;
@group(0) @binding(4) var streak_tex: texture_2d<f32>;
@group(0) @binding(5) var rainfall_tex: texture_2d<f32>;
@group(0) @binding(6) var spatter_tex: texture_2d<f32>;
@group(0) @binding(7) var puddle_tex: texture_2d<f32>;
@group(0) @binding(8) var flow_tex: texture_2d<f32>;
@group(0) @binding(9) var ripple_tex: texture_2d<f32>;

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

fn saturate(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }

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

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Rotate XZ to break left/right “butterfly” seam at courtyard center.
fn rot2(v: vec2<f32>, ang: f32) -> vec2<f32> {
    let c = cos(ang);
    let s = sin(ang);
    return vec2<f32>(v.x * c - v.y * s, v.x * s + v.y * c);
}

/// Sharp localized puddle islands (0 outside, 1 inside poça).
/// Procedural base matches deferred_light (aligned dark/gloss patches).
fn puddleIsland(xz: vec2<f32>, scale: f32) -> f32 {
    let p = rot2(xz + vec2<f32>(3.7, -1.9), 0.63);
    let n1 = hash21(floor(p * 0.55));
    let n2 = fract(sin(dot(p * 0.21, vec2<f32>(269.5, 183.3))) * 43758.5453);
    let n3 = fract(sin(dot(p * 0.47 + 19.0, vec2<f32>(71.7, 112.9))) * 43758.5453);
    var raw = n1 * 0.35 + n2 * 0.4 + n3 * 0.25;
    // Cry puddle_mask as edge detail (rotated — no axis seam).
    let uv_a = p * (0.18 * scale) + vec2<f32>(12.4, 5.2);
    let tex = textureSampleLevel(puddle_tex, samp, uv_a, 0.0).r;
    raw = raw * 0.75 + tex * 0.25;
    return smoothstep(0.60, 0.80, raw);
}

/// 0 = under roof, 1 = open to sky (world-up depth probe).
fn skyExposure(world_pos: vec3<f32>) -> f32 {
    var open = 0.0;
    var tests = 0.0;
    for (var i = 1; i <= 8; i++) {
        let h = f32(i) * 2.5;
        let p = world_pos + vec3<f32>(0.0, h, 0.0);
        let clip = vec4<f32>(p, 1.0) * u.view_proj;
        if (abs(clip.w) < 1e-4) { continue; }
        let ndc = clip.xyz / clip.w;
        let suv = vec2<f32>(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
        tests += 1.0;
        if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
            // Outside frustum upward → treat as open (atrium edges).
            open += 1.0;
            continue;
        }
        let dims = vec2<f32>(textureDimensions(depth_tex));
        let sd = textureLoad(depth_tex, vec2<i32>(clamp(suv, vec2<f32>(0.0), vec2<f32>(0.999)) * dims), 0);
        // Hit sky at this column → exposed.
        if (sd >= 0.9995) {
            open += 1.0;
        } else {
            // Geometry still above us → occluded for this height sample.
            open += 0.0;
        }
    }
    return saturate(open / max(tests, 1.0));
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let intensity = u.params0.x;
    if (intensity < 0.005) {
        return vec4<f32>(0.0);
    }

    let amount = u.params0.y;
    let speed = u.params0.z;
    let size = max(u.params0.w, 0.2);
    let spatter_amt = u.params1.x;
    let wetness = u.params1.y;
    let puddle_scale = u.params1.z;
    let lightning = u.params1.w;
    let wind = u.wind_time.xy * u.wind_time.z;
    let t = u.wind_time.w;

    let depth = textureLoad(depth_tex, vec2<i32>(in.uv * vec2<f32>(textureDimensions(depth_tex))), 0);
    let is_sky = depth >= 0.9999;
    let world_pos = reconstructWorldPos(in.uv, depth);
    let view_z = length(world_pos - u.camera_pos.xyz);

    let n = decodeOct(textureSampleLevel(normal_oct_tex, samp, in.uv, 0.0).xy);
    let floor_w = saturate((n.y - 0.62) * 5.0);

    // Roof / balcony occlusion (fixes rain through ceilings).
    var exposure = 1.0;
    if (is_sky) {
        exposure = 1.0;
    } else {
        exposure = skyExposure(world_pos);
        // Soften under arches: keep a little mist, kill hard streaks.
        exposure = mix(0.08, 1.0, exposure);
    }

    // --- Streaks (fall top→bottom) ---
    let tilt = wind * 0.12;
    let streak_uv0 = vec2<f32>(
        in.uv.x * (3.5 / size) + tilt.x * in.uv.y,
        in.uv.y * (1.8 / size) - t * speed * 1.6 + tilt.y
    );
    let streak_uv1 = vec2<f32>(
        in.uv.x * (5.5 / size) - tilt.x * 0.5,
        in.uv.y * (2.6 / size) - t * speed * 2.3
    );
    var streak = textureSampleLevel(streak_tex, samp, streak_uv0, 0.0).r;
    streak = max(streak, textureSampleLevel(streak_tex, samp, streak_uv1, 0.0).r * 0.75);
    let fall_uv = vec2<f32>(in.uv.x * 2.0 + wind.x * 0.2, in.uv.y * 1.2 - t * speed);
    let fall = textureSampleLevel(rainfall_tex, samp, fall_uv, 0.0).r;

    var rain_mask = saturate(streak * 1.4 + fall * 0.55) * amount * intensity * exposure;
    let dist_fade = saturate(1.4 - view_z / 60.0);
    rain_mask *= mix(0.35, 1.0, dist_fade);

    // Spatter only on exposed wet floors / near surfaces.
    var spat = 0.0;
    if (!is_sky && view_z < 14.0 && exposure > 0.35) {
        let suv = in.uv * (8.0 / size) + vec2<f32>(t * 0.15, -t * speed * 0.4);
        spat = textureSampleLevel(spatter_tex, samp, suv, 0.0).r;
        spat *= saturate(1.0 - view_z / 14.0) * spatter_amt * intensity * exposure;
    }

    // --- Localized poças: dark patches, soft edge; no noisy normal sheen
    // (grainy flow/ripple looked like fisheye warp when looking down).
    var wet_a = 0.0;
    var sheen = vec3<f32>(0.0);
    var puddle = 0.0;
    let view_dir = normalize(u.camera_pos.xyz - world_pos);
    let ndv = max(dot(n, view_dir), 0.0);
    // Fade overlay FX when looking straight down at the floor.
    let down_fade = saturate(1.15 - ndv * 1.1);
    if (!is_sky && floor_w > 0.05) {
        puddle = puddleIsland(world_pos.xz, puddle_scale);
        let damp = 0.08 * wetness * intensity * floor_w;
        let poça = puddle * wetness * intensity * floor_w;
        // Alpha darkens HDR into a readable water pool.
        wet_a = saturate(damp * 0.2 + poça * 0.9) * mix(0.35, 1.0, down_fade);

        // Subtle cool tint only (no BC5 normal sparkles).
        sheen = vec3<f32>(0.08, 0.11, 0.14) * poça * down_fade;
        let wuv = rot2(world_pos.xz, 0.63) * (0.28 * puddle_scale);
        let rip = textureSampleLevel(ripple_tex, samp, wuv * 2.0 + vec2<f32>(0.0, t * 0.15), 0.0).r;
        sheen += vec3<f32>(0.06, 0.07, 0.09) * saturate(rip) * poça * down_fade * 0.6;
    }

    // Less screen noise when camera faces the ground.
    let streak_fade = mix(0.25, 1.0, down_fade);
    let drop_col = vec3<f32>(0.55, 0.62, 0.72) * (rain_mask * 0.75 + spat * 0.9) * streak_fade;
    let flash = vec3<f32>(1.0, 1.0, 1.05) * lightning * 0.25 * exposure;

    let rgb = drop_col + sheen + flash;
    let a = saturate(wet_a * mix(0.4, 0.92, puddle));
    return vec4<f32>(rgb, a);
}
