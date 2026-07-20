// Upsample + accumulate from coarser bloom mip (Dagor bloom_upsample + halation).
struct Params {
    /// x = filter radius, y = upsample_factor, z = halation strength, w = mip index from fine
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var fine_tex: texture_2d<f32>;
@group(0) @binding(3) var coarse_tex: texture_2d<f32>;

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
    let dims = vec2<f32>(textureDimensions(coarse_tex));
    let texel = (1.0 / dims) * u.params.x;
    var coarse = textureSample(coarse_tex, samp, in.uv).rgb * 4.0;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>(-texel.x, 0.0)).rgb;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>( texel.x, 0.0)).rgb;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>(0.0, -texel.y)).rgb;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>(0.0,  texel.y)).rgb;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>(-texel.x, -texel.y)).rgb * 2.0;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>( texel.x, -texel.y)).rgb * 2.0;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>(-texel.x,  texel.y)).rgb * 2.0;
    coarse += textureSample(coarse_tex, samp, in.uv + vec2<f32>( texel.x,  texel.y)).rgb * 2.0;
    coarse *= (1.0 / 16.0);

    // Halation: warm tint on coarser contributions (Dagor halation_color × mip_factor).
    let halation = u.params.z * exp2(-2.0 * u.params.w);
    let tint = vec3<f32>(1.0 + 1.0 * halation, 1.0, 1.0);
    coarse *= tint;

    let fine = textureSample(fine_tex, samp, in.uv).rgb;
    let upsample = clamp(u.params.y, 0.0, 1.0);
    return vec4<f32>(fine * (1.0 - upsample * 0.15) + coarse * upsample, 1.0);
}
