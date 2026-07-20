// Adapt exposure with dual-speed (Dagor adaptUp / adaptDown).
struct Params {
    /// x = key, y = adapt_up (brighten), z = min_exp, w = max_exp
    /// adapt_down = adapt_up * 8 (packed in shader like Dagor 1 vs 8)
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var lum_1x1: texture_2d<f32>;
@group(0) @binding(3) var prev_exp: texture_2d<f32>;

struct VsOut {
    @builtin(position) position: vec4<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
    var out: VsOut;
    let x = f32(i32(vid & 1u) * 4 - 1);
    let y = f32(i32(vid & 2u) * 2 - 1);
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(_in: VsOut) -> @location(0) vec4<f32> {
    _ = _in;
    let avg_log = textureSampleLevel(lum_1x1, samp, vec2<f32>(0.5, 0.5), 0.0).r;
    let prev = textureSampleLevel(prev_exp, samp, vec2<f32>(0.5, 0.5), 0.0).r;
    let key = u.params.x;
    let adapt_up = u.params.y;
    let adapt_down = u.params.y * 8.0;
    let min_e = u.params.z;
    let max_e = u.params.w;
    // Dagor-like: autoExposureScale ~1.5 on key.
    let target_exp = clamp((key * 1.5) / max(exp(avg_log), 1e-4), min_e, max_e);
    let safe_prev = select(1.0, prev, prev > 1e-5);
    let going_brighter = target_exp > safe_prev;
    let adapt = select(adapt_down, adapt_up, going_brighter);
    let adapted = mix(safe_prev, target_exp, clamp(adapt, 0.0, 1.0));
    return vec4<f32>(clamp(adapted, min_e, max_e), 0.0, 0.0, 1.0);
}
