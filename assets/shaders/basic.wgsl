// Basic vertex-color mesh. Row-vector convention (matches zmath transpose upload).
@group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) color: vec3<f32>,
}

@vertex
fn vs_main(
    @location(0) position: vec3<f32>,
    @location(1) color: vec3<f32>,
) -> VertexOut {
    var out: VertexOut;
    out.position_clip = vec4<f32>(position, 1.0) * object_to_clip;
    out.color = color;
    return out;
}

@fragment
fn fs_main(@location(0) color: vec3<f32>) -> @location(0) vec4<f32> {
    return vec4<f32>(color, 1.0);
}
