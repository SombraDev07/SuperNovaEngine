// Separable 9-tap Gaussian blur (horizontal or vertical via uniform).
struct Params {
    direction: vec4<f32>, // xy = texel * dir
}

@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var src_tex: texture_2d<f32>;

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
    let dir = u.direction.xy;
    // Weights ≈ Gaussian σ≈2.0, normalized.
    let w0 = 0.227027;
    let w1 = 0.1945946;
    let w2 = 0.1216216;
    let w3 = 0.054054;
    let w4 = 0.016216;

    var color = textureSample(src_tex, samp, in.uv).rgb * w0;
    color += textureSample(src_tex, samp, in.uv + dir * 1.0).rgb * w1;
    color += textureSample(src_tex, samp, in.uv - dir * 1.0).rgb * w1;
    color += textureSample(src_tex, samp, in.uv + dir * 2.0).rgb * w2;
    color += textureSample(src_tex, samp, in.uv - dir * 2.0).rgb * w2;
    color += textureSample(src_tex, samp, in.uv + dir * 3.0).rgb * w3;
    color += textureSample(src_tex, samp, in.uv - dir * 3.0).rgb * w3;
    color += textureSample(src_tex, samp, in.uv + dir * 4.0).rgb * w4;
    color += textureSample(src_tex, samp, in.uv - dir * 4.0).rgb * w4;
    return vec4<f32>(color, 1.0);
}
