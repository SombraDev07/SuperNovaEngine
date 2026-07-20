// 256-bin hist → 1×1 log-luminance at ~50th/90th percentile mix (Dagor exposure).
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var hist_tex: texture_2d<f32>;

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
    const LOG_MIN: f32 = -12.0;
    const LOG_RANGE: f32 = 15.0;
    var total = 0.0;
    var bins: array<f32, 256>;
    for (var i = 0; i < 256; i++) {
        let c = textureLoad(hist_tex, vec2<i32>(i, 0), 0).r;
        bins[i] = c;
        total += c;
    }
    let target50 = total * 0.50;
    let target90 = total * 0.90;
    var cum = 0.0;
    var p50 = LOG_MIN + LOG_RANGE * 0.5;
    var p90 = LOG_MIN + LOG_RANGE * 0.75;
    var found50 = false;
    var found90 = false;
    for (var i = 0; i < 256; i++) {
        cum += bins[i];
        let log_v = LOG_MIN + LOG_RANGE * ((f32(i) + 0.5) / 256.0);
        if (!found50 && cum >= target50) {
            p50 = log_v;
            found50 = true;
        }
        if (!found90 && cum >= target90) {
            p90 = log_v;
            found90 = true;
        }
    }
    let log_lum = mix(p50, p90, 0.35);
    return vec4<f32>(log_lum, 0.0, 0.0, 1.0);
}
