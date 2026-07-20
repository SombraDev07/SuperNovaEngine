// Build 256-bin log-luminance histogram from 64² mid buffer (Dagor ExposureCompute role).
struct Params {
    params: vec4<f32>, // x = log_min, y = log_range, zw unused
}

@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var lum_mid: texture_2d<f32>;

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

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let bin = u32(clamp(floor(in.uv.x * 256.0), 0.0, 255.0));
    let log_min = u.params.x;
    let log_range = max(u.params.y, 0.001);
    let lo = log_min + log_range * (f32(bin) / 256.0);
    let hi = log_min + log_range * (f32(bin + 1u) / 256.0);
    var count = 0.0;
    // Sparse 32×32 over mid (center-weighted later in percentile).
    for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
            let uv = (vec2<f32>(f32(x), f32(y)) + 0.5) / 32.0;
            let v = textureSampleLevel(lum_mid, samp, uv, 0.0).r;
            let hit = (v >= lo) && (v < hi);
            count += select(0.0, 1.0, hit);
        }
    }
    return vec4<f32>(count, 0.0, 0.0, 1.0);
}
