// Depth-only shadow pass (instanced SSBO + optional albedo alpha test).
struct Uniforms {
    light_vp: mat4x4<f32>,
}

struct Instance {
    object_to_world: mat4x4<f32>,
    material: vec4<f32>,
    color: vec4<f32>, // a = alpha cutoff (0 = opaque)
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;
@group(0) @binding(2) var mat_samp: sampler;
@group(0) @binding(3) var albedo_map: texture_2d<f32>;

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) alpha_cutoff: f32,
}

@vertex
fn vs_main(
    @location(0) position: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @builtin(instance_index) iid: u32,
) -> VsOut {
    var out: VsOut;
    let world = vec4<f32>(position, 1.0) * instances[iid].object_to_world;
    out.position = world * u.light_vp;
    out.uv = uv;
    out.alpha_cutoff = instances[iid].color.w;
    return out;
}

@fragment
fn fs_main(in: VsOut) {
    // Sample must be in uniform control flow (WGSL / Tint).
    let a = textureSample(albedo_map, mat_samp, in.uv).a;
    if (in.alpha_cutoff > 0.0 && a < in.alpha_cutoff) {
        discard;
    }
}
