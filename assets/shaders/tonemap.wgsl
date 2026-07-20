// ACES (Hill RRT+ODT) tonemap of HDR + bloom → swapchain (exposure from 1×1 GPU texture).
struct Params {
    params: vec4<f32>, // bloom_strength, _, _, _
}

@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var hdr_tex: texture_2d<f32>;
@group(0) @binding(3) var bloom_tex: texture_2d<f32>;
@group(0) @binding(4) var exp_tex: texture_2d<f32>;

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

// Stephen Hill's ACES fitted RRT+ODT (more filmic than Narkowicz).
fn rrtAndOdtFit(v: vec3<f32>) -> vec3<f32> {
    let a = v * (v + 0.0245786) - 0.000090537;
    let b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

fn acesHill(color_in: vec3<f32>) -> vec3<f32> {
    // Columns of Hill ACESInputMat / ACESOutputMat (HLSL row-major → WGSL columns).
    let aces_in = mat3x3<f32>(
        vec3<f32>(0.59719, 0.07600, 0.02840),
        vec3<f32>(0.35458, 0.90834, 0.13383),
        vec3<f32>(0.04823, 0.01566, 0.83777),
    );
    let aces_out = mat3x3<f32>(
        vec3<f32>(1.60475, -0.10208, -0.00327),
        vec3<f32>(-0.53108, 1.10813, -0.07276),
        vec3<f32>(-0.07367, -0.00605, 1.07602),
    );
    var color = aces_in * color_in;
    color = rrtAndOdtFit(color);
    color = aces_out * color;
    return clamp(color, vec3<f32>(0.0), vec3<f32>(1.0));
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let hdr = textureSample(hdr_tex, samp, in.uv).rgb;
    let bloom = textureSample(bloom_tex, samp, in.uv).rgb;
    let exposure = max(textureSample(exp_tex, samp, vec2<f32>(0.5, 0.5)).r, 0.001);
    let combined = (hdr + bloom * u.params.x) * exposure;
    let mapped = acesHill(combined);
    let srgb = pow(mapped, vec3<f32>(1.0 / 2.2));
    return vec4<f32>(srgb, 1.0);
}
