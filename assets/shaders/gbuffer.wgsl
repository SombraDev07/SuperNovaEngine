// Geometry pass → G-buffer (deferred PBR).
struct Frame {
    object_to_clip: mat4x4<f32>,
    object_to_world: mat4x4<f32>,
    // metallic, roughness, ao, _pad
    material: vec4<f32>,
}

@group(0) @binding(0) var<uniform> frame: Frame;

struct VsOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) world_n: vec3<f32>,
    @location(2) albedo: vec3<f32>,
}

struct GBuffer {
    @location(0) albedo_ao: vec4<f32>,
    @location(1) normal_rough: vec4<f32>,
    @location(2) world_pos_metal: vec4<f32>,
}

@vertex
fn vs_main(
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) color: vec3<f32>,
) -> VsOut {
    var out: VsOut;
    let wp4 = vec4<f32>(position, 1.0) * frame.object_to_world;
    out.world_pos = wp4.xyz;
    // Normal matrix ≈ upper 3x3 of object_to_world (uniform scale OK for cube).
    let n4 = vec4<f32>(normal, 0.0) * frame.object_to_world;
    out.world_n = normalize(n4.xyz);
    out.albedo = color;
    out.position_clip = vec4<f32>(position, 1.0) * frame.object_to_clip;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> GBuffer {
    var g: GBuffer;
    g.albedo_ao = vec4<f32>(in.albedo, frame.material.z);
    g.normal_rough = vec4<f32>(normalize(in.world_n), frame.material.y);
    g.world_pos_metal = vec4<f32>(in.world_pos, frame.material.x);
    return g;
}
