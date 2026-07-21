// HDR + bloom → swapchain. Mode: 0 = ACES Hill, 1 = AgX (natural grade).
struct Params {
    params: vec4<f32>, // bloom_strength, tonemap_mode, _, _
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

fn rrtAndOdtFit(v: vec3<f32>) -> vec3<f32> {
    let a = v * (v + 0.0245786) - 0.000090537;
    let b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
}

fn acesHill(color_in: vec3<f32>) -> vec3<f32> {
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

// AgX (Blender / Filament) — softer highlights, more natural midtones.
fn agxDefaultContrastApprox(x: vec3<f32>) -> vec3<f32> {
    let x2 = x * x;
    let x4 = x2 * x2;
    return 15.5 * x4 * x2
        - 40.14 * x4 * x
        + 31.96 * x4
        - 6.868 * x2 * x
        + 0.4298 * x2
        + 0.002253 * x
        + 0.0003304;
}

fn agx(color_in: vec3<f32>) -> vec3<f32> {
    // Columns = Blender AgXInsetMatrix / AgXOutsetMatrix (row-major source → WGSL columns).
    let inset = mat3x3<f32>(
        vec3<f32>(0.856627153315983, 0.137318972929847, 0.111898212949541),
        vec3<f32>(0.0951212405381588, 0.761241990602591, 0.0767994186034242),
        vec3<f32>(0.0482516061458583, 0.101439036467562, 0.811302368447035),
    );
    // GLSL AgXOutsetMatrix 9-float ctor is column-major.
    let outset = mat3x3<f32>(
        vec3<f32>(1.127100581557994, -0.110606573788186, -0.016494007769809),
        vec3<f32>(-0.141329763498654, 1.157823702216272, -0.016494007769809),
        vec3<f32>(-0.141329763498654, -0.110606573788186, 1.251936337286995),
    );
    var color = inset * max(color_in, vec3<f32>(0.0));
    // Log2 encode into ~[-12.5, +4] EV range used by AgX.
    let min_ev = -12.47393;
    let max_ev = 4.026069;
    color = clamp((log2(max(color, vec3<f32>(1e-10))) - min_ev) / (max_ev - min_ev), vec3<f32>(0.0), vec3<f32>(1.0));
    color = agxDefaultContrastApprox(color);
    color = outset * color;
    return clamp(color, vec3<f32>(0.0), vec3<f32>(1.0));
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let hdr = textureSample(hdr_tex, samp, in.uv).rgb;
    let bloom = textureSample(bloom_tex, samp, in.uv).rgb;
    let exposure = max(textureSample(exp_tex, samp, vec2<f32>(0.5, 0.5)).r, 0.001);
    let combined = (hdr + bloom * u.params.x) * exposure;
    var mapped: vec3<f32>;
    if (u.params.y > 0.5) {
        mapped = agx(combined);
    } else {
        mapped = acesHill(combined);
    }
    let srgb = pow(max(mapped, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    return vec4<f32>(srgb, 1.0);
}
