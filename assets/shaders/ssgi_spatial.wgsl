// Strong spatial filter for screen probes (daGI2 screenprobes_spatial_filtering role).

struct Uniforms {
    /// x=enabled
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var src: texture_2d<f32>;
@group(0) @binding(3) var depth_tex: texture_depth_2d;
@group(0) @binding(4) var normal_tex: texture_2d<f32>;

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

fn decodeOct(e_in: vec2<f32>) -> vec3<f32> {
    let e = e_in * 2.0 - 1.0;
    var n = vec3<f32>(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    let t = max(-n.z, 0.0);
    n.x += select(t, -t, n.x >= 0.0);
    n.y += select(t, -t, n.y >= 0.0);
    return normalize(n);
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let center = textureSampleLevel(src, samp, in.uv, 0.0);
    if (u.params.x < 0.5 || center.a < 0.05) {
        return center;
    }
    let dims = vec2<f32>(textureDimensions(depth_tex));
    let probe_dims = vec2<f32>(textureDimensions(src));
    let cp = vec2<i32>(clamp(in.uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
    let cd = textureLoad(depth_tex, cp, 0);
    let cn = decodeOct(textureSampleLevel(normal_tex, samp, in.uv, 0.0).xy);

    var acc = center.rgb * 1.5;
    var wsum = 1.5;
    // 3-pass style neighborhood (cross + diagonals)
    for (var oy = -2; oy <= 2; oy++) {
        for (var ox = -2; ox <= 2; ox++) {
            if (ox == 0 && oy == 0) { continue; }
            let suv = in.uv + vec2<f32>(f32(ox), f32(oy)) / probe_dims;
            let s = textureSampleLevel(src, samp, suv, 0.0);
            if (s.a < 0.05) { continue; }
            let sp = vec2<i32>(clamp(suv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
            let sd = textureLoad(depth_tex, sp, 0);
            let sn = decodeOct(textureSampleLevel(normal_tex, samp, suv, 0.0).xy);
            let dw = exp(-abs(sd - cd) * 60.0);
            let nw = max(dot(cn, sn), 0.0);
            let w = dw * nw * nw;
            acc += s.rgb * w;
            wsum += w;
        }
    }
    return vec4<f32>(acc / max(wsum, 1e-4), center.a);
}
