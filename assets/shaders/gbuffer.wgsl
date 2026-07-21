// Geometry pass → packed G-buffer (instanced via SSBO + indirect draw).
struct Frame {
    world_to_clip: mat4x4<f32>,
}

struct Instance {
    object_to_world: mat4x4<f32>,
    material: vec4<f32>, // metallic, roughness, ao, use_maps
    color: vec4<f32>,    // rgb factor; a = alpha cutoff (0 = opaque)
}

@group(0) @binding(0) var<uniform> frame: Frame;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;
@group(0) @binding(2) var mat_samp: sampler;
@group(0) @binding(3) var albedo_map: texture_2d<f32>;
@group(0) @binding(4) var normal_map: texture_2d<f32>;
@group(0) @binding(5) var orm_map: texture_2d<f32>;
@group(0) @binding(6) var emissive_map: texture_2d<f32>;

struct VsOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) world_n: vec3<f32>,
    @location(1) world_t: vec3<f32>,
    @location(2) world_b: vec3<f32>,
    @location(3) albedo: vec3<f32>,
    @location(4) uv: vec2<f32>,
    @location(5) material: vec4<f32>,
    @location(6) view_dir_ts: vec3<f32>,
    @location(7) alpha_cutoff: f32,
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

fn parallaxUv(uv: vec2<f32>, view_ts: vec3<f32>) -> vec2<f32> {
    let height = textureSample(orm_map, mat_samp, uv).a;
    let scale = 0.04;
    let v = normalize(view_ts);
    return uv - v.xy / max(v.z, 0.1) * (height * scale);
}

@vertex
fn vs_main(
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
    @location(3) uv: vec2<f32>,
    @builtin(instance_index) iid: u32,
) -> VsOut {
    let inst = instances[iid];
    var out: VsOut;
    let n4 = vec4<f32>(normal, 0.0) * inst.object_to_world;
    out.world_n = normalize(n4.xyz);
    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), abs(out.world_n.y) < 0.999);
    out.world_t = normalize(cross(up, out.world_n));
    out.world_b = cross(out.world_n, out.world_t);
    out.albedo = color * inst.color.xyz;
    out.uv = uv;
    out.material = inst.material;
    out.alpha_cutoff = inst.color.w;
    let world = vec4<f32>(position, 1.0) * inst.object_to_world;
    out.position_clip = world * frame.world_to_clip;
    let view_ws = normalize(-world.xyz);
    out.view_dir_ts = vec3<f32>(
        dot(view_ws, out.world_t),
        dot(view_ws, out.world_b),
        dot(view_ws, out.world_n),
    );
    return out;
}

@fragment
fn fs_main(in: VsOut) -> GBuffer {
    var albedo = in.albedo;
    var n = normalize(in.world_n);
    var metallic = in.material.x;
    var roughness = in.material.y;
    var ao = in.material.z;
    var emissive = vec3<f32>(0.0);

    let use_maps = in.material.w > 0.5;
    let uv_para = parallaxUv(in.uv, in.view_dir_ts);
    let uv = select(in.uv, uv_para, use_maps);
    let base_s = textureSample(albedo_map, mat_samp, uv);
    let orm = textureSample(orm_map, mat_samp, uv);
    let nt = textureSample(normal_map, mat_samp, uv).xyz * 2.0 - 1.0;
    let em = textureSample(emissive_map, mat_samp, uv).rgb;
    let n_mapped = normalize(in.world_t * nt.x + in.world_b * nt.y + in.world_n * nt.z);

    // Alpha mask / blend cutout (glTF MASK/BLEND → discard). color.w == 0 → opaque.
    let alpha = select(1.0, base_s.a, use_maps);
    if (in.alpha_cutoff > 0.0 && alpha < in.alpha_cutoff) {
        discard;
    }

    albedo = select(albedo, base_s.rgb * in.albedo, use_maps);
    ao = select(ao, ao * orm.r, use_maps);
    roughness = select(roughness, roughness * orm.g, use_maps);
    metallic = select(metallic, metallic * orm.b, use_maps);
    n = select(n, n_mapped, use_maps);
    emissive = select(emissive, em, use_maps);

    let oct = encodeOct(n);
    var g: GBuffer;
    g.albedo_ao = vec4<f32>(albedo, ao);
    g.normal_oct = vec4<f32>(oct, 0.0, 1.0);
    g.material = vec4<f32>(clamp(metallic, 0.0, 1.0), clamp(roughness, 0.04, 1.0), 1.0, 1.0);
    g.emissive = vec4<f32>(emissive, 1.0);
    return g;
}
