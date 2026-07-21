// Bilateral spatial filter for GTAO (Dagor gtao_spatial role).
// Separable: direction.xy = texel step (1,0) or (0,1).

struct Uniforms {
    /// xy = direction in texels, z = depth_sigma, w = unused
    params: vec4<f32>,
    /// xy = screen size
    screen: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var ao_tex: texture_2d<f32>;

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
    let center = textureSampleLevel(ao_tex, samp, in.uv, 0.0);
    let c_ao = center.r;
    let c_d = center.g;
    let dir = u.params.xy;
    let sigma = max(u.params.z, 1e-4);
    let texel = 1.0 / u.screen.xy;

    // 7-tap gaussian × bilateral depth
    let offsets = array<f32, 4>(-3.0, -2.0, -1.0, 1.0);
    let weights = array<f32, 4>(0.05, 0.15, 0.25, 0.25);
    // center weight 0.3
    var sum = c_ao * 0.3;
    var wsum = 0.3;

    for (var i = 0; i < 4; i++) {
        let uv = in.uv + dir * offsets[i] * texel;
        let s = textureSampleLevel(ao_tex, samp, uv, 0.0);
        let dz = abs(s.g - c_d) * 200.0; // depth in [0,1] — scale for indoor
        let bw = exp(-dz * dz / (2.0 * sigma * sigma));
        let w = weights[i] * bw;
        sum += s.r * w;
        wsum += w;
    }
    // +2 symmetric for +2,+3 (weights already cover ±1 and we need +2,+3)
    let offsets2 = array<f32, 2>(2.0, 3.0);
    let weights2 = array<f32, 2>(0.15, 0.05);
    for (var i = 0; i < 2; i++) {
        let uv = in.uv + dir * offsets2[i] * texel;
        let s = textureSampleLevel(ao_tex, samp, uv, 0.0);
        let dz = abs(s.g - c_d) * 200.0;
        let bw = exp(-dz * dz / (2.0 * sigma * sigma));
        let w = weights2[i] * bw;
        sum += s.r * w;
        wsum += w;
    }

    return vec4<f32>(sum / max(wsum, 1e-4), c_d, 0.0, 1.0);
}
