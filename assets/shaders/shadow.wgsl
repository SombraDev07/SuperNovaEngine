// Depth-only shadow pass (no color targets).
struct Uniforms {
    object_to_clip: mat4x4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;

struct VsOut {
    @builtin(position) position: vec4<f32>,
}

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> VsOut {
    var out: VsOut;
    out.position = vec4<f32>(position, 1.0) * u.object_to_clip;
    return out;
}
