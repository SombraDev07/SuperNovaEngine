// Kawase-style 4-tap downsample (half resolution).
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var src_tex: texture_2d<f32>;

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
    let dims = vec2<f32>(textureDimensions(src_tex));
    let texel = 1.0 / dims;
    let o = texel * 0.5;
    var c = textureSample(src_tex, samp, in.uv + vec2<f32>(-o.x, -o.y)).rgb;
    c += textureSample(src_tex, samp, in.uv + vec2<f32>( o.x, -o.y)).rgb;
    c += textureSample(src_tex, samp, in.uv + vec2<f32>(-o.x,  o.y)).rgb;
    c += textureSample(src_tex, samp, in.uv + vec2<f32>( o.x,  o.y)).rgb;
    return vec4<f32>(c * 0.25, 1.0);
}
