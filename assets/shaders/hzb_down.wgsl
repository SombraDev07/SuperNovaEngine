@group(0) @binding(0) var src: texture_2d<f32>;

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
    let dims = textureDimensions(src);
    let base = vec2<i32>(in.uv * vec2<f32>(dims));
    let x0 = clamp(base.x, 0, i32(dims.x) - 1);
    let y0 = clamp(base.y, 0, i32(dims.y) - 1);
    let x1 = min(x0 + 1, i32(dims.x) - 1);
    let y1 = min(y0 + 1, i32(dims.y) - 1);
    let d0 = textureLoad(src, vec2<i32>(x0, y0), 0).r;
    let d1 = textureLoad(src, vec2<i32>(x1, y0), 0).r;
    let d2 = textureLoad(src, vec2<i32>(x0, y1), 0).r;
    let d3 = textureLoad(src, vec2<i32>(x1, y1), 0).r;
    return vec4<f32>(max(max(d0, d1), max(d2, d3)), 0.0, 0.0, 1.0);
}
