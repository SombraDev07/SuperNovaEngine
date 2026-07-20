// Terrain G-buffer: packed int16 verts + 4 detail albedos + splat + holes (Dagor LandClass).
struct Frame {
    world_to_clip: mat4x4<f32>,
    decode_origin: vec4<f32>,
    decode_scale: vec4<f32>,
}

@group(0) @binding(0) var<uniform> frame: Frame;
@group(0) @binding(1) var mat_samp: sampler;
@group(0) @binding(2) var albedo0: texture_2d<f32>;
@group(0) @binding(3) var albedo1: texture_2d<f32>;
@group(0) @binding(4) var albedo2: texture_2d<f32>;
@group(0) @binding(5) var albedo3: texture_2d<f32>;
@group(0) @binding(6) var splat_map: texture_2d<f32>;
@group(0) @binding(7) var hole_map: texture_2d<f32>;

struct VsOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) world_n: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) world_pos: vec3<f32>,
}

struct GBuffer {
    @location(0) albedo_ao: vec4<f32>,
    @location(1) normal_oct: vec4<f32>,
    @location(2) material: vec4<f32>,
    @location(3) emissive: vec4<f32>,
}

fn encodeOct(n_in: vec3<f32>) -> vec2<f32> {
    var n = n_in / max(abs(n_in.x) + abs(n_in.y) + abs(n_in.z), 1e-5);
    if (n_in.z < 0.0) {
        let nx = (1.0 - abs(n.y)) * select(-1.0, 1.0, n.x >= 0.0);
        let ny = (1.0 - abs(n.x)) * select(-1.0, 1.0, n.y >= 0.0);
        n = vec3<f32>(nx, ny, n.z);
    }
    return n.xy * 0.5 + 0.5;
}

fn detailNormal(base_n: vec3<f32>, albedo: vec4<f32>, uv: vec2<f32>) -> vec3<f32> {
    let lum = dot(albedo.rgb, vec3<f32>(0.299, 0.587, 0.114));
    let bump_tex = albedo.a;
    let eps = 0.002;
    let t1 = normalize(cross(base_n, vec3<f32>(0.0, 0.0, 1.0) + vec3<f32>(eps)));
    let t2 = cross(base_n, t1);
    let bump = (bump_tex - 0.5) * 0.55 + (lum - 0.5) * 0.2;
    let h = fract(sin(dot(uv * 64.0, vec2<f32>(12.9898, 78.233))) * 43758.5453);
    return normalize(base_n + t1 * bump + t2 * (bump * 0.65 + (h - 0.5) * 0.05));
}

@vertex
fn vs_main(
    @location(0) pos_i: vec4<i32>,
    @location(1) nrm_i: vec4<i32>,
    @location(2) uv_i: vec2<u32>,
) -> VsOut {
    let pn = vec3<f32>(f32(pos_i.x), f32(pos_i.y), f32(pos_i.z)) / 32767.0;
    let position = pn * frame.decode_scale.xyz + frame.decode_origin.xyz;
    let normal = normalize(vec3<f32>(f32(nrm_i.x), f32(nrm_i.y), f32(nrm_i.z)) / 32767.0);
    let uv = vec2<f32>(f32(uv_i.x), f32(uv_i.y)) / 65535.0;

    var out: VsOut;
    out.world_n = normal;
    out.uv = uv;
    out.world_pos = position;
    out.position_clip = vec4<f32>(position, 1.0) * frame.world_to_clip;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> GBuffer {
    let hole = textureSample(hole_map, mat_samp, in.uv);
    if (hole.r > 0.45 || hole.g > 0.5) {
        discard;
    }

    var w = textureSample(splat_map, mat_samp, in.uv);
    let wsum = max(w.r + w.g + w.b + w.a, 1e-4);
    w = w / wsum;

    let ngeo = normalize(in.world_n);
    let slope = 1.0 - clamp(ngeo.y, 0.0, 1.0);
    let cliff = smoothstep(0.35, 0.85, slope);
    w.g = clamp(w.g + cliff * 0.55, 0.0, 1.0);
    let rest = max(1.0 - w.g, 1e-4);
    let flat = w.r + w.b + w.a;
    w.r = w.r / max(flat, 1e-4) * rest;
    w.b = w.b / max(flat, 1e-4) * rest;
    w.a = w.a / max(flat, 1e-4) * rest;

    let duv = in.uv * 8.0;
    let s0 = textureSample(albedo0, mat_samp, duv);
    let s1 = textureSample(albedo1, mat_samp, duv);
    let s2 = textureSample(albedo2, mat_samp, duv);
    let s3 = textureSample(albedo3, mat_samp, duv);
    let albedo = s0 * w.r + s1 * w.g + s2 * w.b + s3 * w.a;

    let metallic = 0.02 * w.r + 0.10 * w.g + 0.01 * w.b + 0.03 * w.a;
    let roughness = 0.90 * w.r + 0.50 * w.g + 0.85 * w.b + 0.78 * w.a;
    let ao = mix(1.0, 0.80, w.a * 0.6 + cliff * 0.2);

    let n = detailNormal(ngeo, albedo, duv);
    let oct = encodeOct(n);

    var g: GBuffer;
    g.albedo_ao = vec4<f32>(albedo.rgb, ao);
    g.normal_oct = vec4<f32>(oct, 0.0, 1.0);
    g.material = vec4<f32>(metallic, roughness, 1.0, 1.0);
    g.emissive = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    return g;
}
