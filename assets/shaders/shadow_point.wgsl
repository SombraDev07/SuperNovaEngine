// Point-light cubemap shadow (instanced SSBO + indirect).
struct Uniforms {
    face_vp: mat4x4<f32>,
    light_pos_range: vec4<f32>,
}

struct Instance {
    object_to_world: mat4x4<f32>,
    material: vec4<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
}

@vertex
fn vs_main(
    @location(0) position: vec3<f32>,
    @builtin(instance_index) iid: u32,
) -> VsOut {
    var out: VsOut;
    let world = vec4<f32>(position, 1.0) * instances[iid].object_to_world;
    out.world_pos = world.xyz;
    out.position = world * u.face_vp;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @builtin(frag_depth) f32 {
    let dist = length(in.world_pos - u.light_pos_range.xyz);
    return clamp(dist / max(u.light_pos_range.w, 0.001), 0.0, 1.0);
}
