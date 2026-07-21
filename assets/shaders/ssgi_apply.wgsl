// Phase B apply: bilateral upsample of screen-probe irradiance → additive GI.

struct Uniforms {
    inv_view_proj: mat4x4<f32>,
    /// x=intensity, y=enabled, z=blend, w=tile_size
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var albedo_ao_tex: texture_2d<f32>;
@group(0) @binding(3) var normal_oct_tex: texture_2d<f32>;
@group(0) @binding(4) var material_tex: texture_2d<f32>;
@group(0) @binding(5) var depth_tex: texture_depth_2d;
@group(0) @binding(6) var gtao_tex: texture_2d<f32>;
@group(0) @binding(7) var ssgi_tex: texture_2d<f32>;

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
    if (u.params.y < 0.5) {
        return vec4<f32>(0.0);
    }
    let dims = vec2<f32>(textureDimensions(depth_tex));
    let pixel = vec2<i32>(in.uv * dims);
    let depth = textureLoad(depth_tex, pixel, 0);
    let material = textureSampleLevel(material_tex, samp, in.uv, 0.0);
    if (depth >= 0.9999 || material.b < 0.5) {
        return vec4<f32>(0.0);
    }

    let albedo_ao = textureSampleLevel(albedo_ao_tex, samp, in.uv, 0.0);
    let n = decodeOct(textureSampleLevel(normal_oct_tex, samp, in.uv, 0.0).xy);
    let metallic = clamp(material.r, 0.0, 1.0);
    let ao = saturate(albedo_ao.a * textureSampleLevel(gtao_tex, samp, in.uv, 0.0).r);

    let probe_dims = vec2<f32>(textureDimensions(ssgi_tex));
    let puv = in.uv * probe_dims - vec2<f32>(0.5);
    let base = floor(puv);
    let f = fract(puv);
    var irr = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var iy = 0; iy < 2; iy++) {
        for (var ix = 0; ix < 2; ix++) {
            let c = clamp(base + vec2<f32>(f32(ix), f32(iy)), vec2<f32>(0.0), probe_dims - vec2<f32>(1.0));
            let suv = (c + 0.5) / probe_dims;
            let s = textureSampleLevel(ssgi_tex, samp, suv, 0.0);
            if (s.a < 0.1) { continue; }
            let center_uv = suv; // probe UV ≈ full UV (same 0..1 mapping)
            let cp = vec2<i32>(clamp(center_uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
            let pd = textureLoad(depth_tex, cp, 0);
            let dw = exp(-abs(pd - depth) * 80.0);
            let pn = decodeOct(textureSampleLevel(normal_oct_tex, samp, center_uv, 0.0).xy);
            let nw = max(dot(n, pn), 0.0);
            let bil =
                select(1.0 - f.x, f.x, ix == 1) *
                select(1.0 - f.y, f.y, iy == 1) *
                (0.1 + nw * nw) * dw;
            irr += s.rgb * bil;
            wsum += bil;
        }
    }
    irr = irr / max(wsum, 1e-4);

    let kd = 1.0 - metallic;
    let gi = albedo_ao.rgb * irr * kd * ao * u.params.x * u.params.z;
    return vec4<f32>(gi, 0.0);
}
