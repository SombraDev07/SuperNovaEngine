// HDR → 64² log-luminance (R).
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var hdr_tex: texture_2d<f32>;

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
    // 4-tap box for stable average.
    let texel = 1.0 / vec2<f32>(textureDimensions(hdr_tex));
    var sum = 0.0;
    for (var oy = 0; oy < 2; oy++) {
        for (var ox = 0; ox < 2; ox++) {
            let uv = in.uv + (vec2<f32>(f32(ox), f32(oy)) - 0.5) * texel;
            let c = textureSampleLevel(hdr_tex, samp, uv, 0.0).rgb;
            let lum = max(dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)), 1e-4);
            sum += log(lum);
        }
    }
    return vec4<f32>(sum * 0.25, 0.0, 0.0, 1.0);
}
