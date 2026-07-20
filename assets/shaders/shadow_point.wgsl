// Point-light cubemap shadow: write linear depth = distance / range.
struct Uniforms {
    object_to_clip: mat4x4<f32>,
    object_to_world: mat4x4<f32>,
    light_pos_range: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
}

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> VsOut {
    var out: VsOut;
    let world = vec4<f32>(position, 1.0) * u.object_to_world;
    out.world_pos = world.xyz;
    out.position = vec4<f32>(position, 1.0) * u.object_to_clip;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @builtin(frag_depth) f32 {
    let dist = length(in.world_pos - u.light_pos_range.xyz);
    return clamp(dist / max(u.light_pos_range.w, 0.001), 0.0, 1.0);
}
