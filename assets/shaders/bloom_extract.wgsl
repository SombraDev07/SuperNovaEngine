// Bright-pass extract + downsample (samples HDR at full res into half-res target).
struct Params {
    params: vec4<f32>, // threshold, knee, _, _
}

@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var hdr_tex: texture_2d<f32>;

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

fn luminance(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    // 4-tap box downsample.
    let tex_size = vec2<f32>(textureDimensions(hdr_tex));
    let texel = 1.0 / tex_size;
    var color = vec3<f32>(0.0);
    color += textureSample(hdr_tex, samp, in.uv + texel * vec2<f32>(-0.5, -0.5)).rgb;
    color += textureSample(hdr_tex, samp, in.uv + texel * vec2<f32>(0.5, -0.5)).rgb;
    color += textureSample(hdr_tex, samp, in.uv + texel * vec2<f32>(-0.5, 0.5)).rgb;
    color += textureSample(hdr_tex, samp, in.uv + texel * vec2<f32>(0.5, 0.5)).rgb;
    color *= 0.25;

    let threshold = u.params.x;
    let knee = max(u.params.y, 0.001);
    let soft = luminance(color) - threshold + knee;
    let soft_clamped = clamp(soft, 0.0, 2.0 * knee);
    let soft_factor = (soft_clamped * soft_clamped) / (4.0 * knee + 0.0001);
    let contrib = max(soft_factor, luminance(color) - threshold) / max(luminance(color), 0.0001);
    return vec4<f32>(color * max(contrib, 0.0), 1.0);
}
