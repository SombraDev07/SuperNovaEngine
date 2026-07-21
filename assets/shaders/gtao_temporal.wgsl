// Temporal accumulate for GTAO (Dagor gtao_temporal role).
// Reprojects previous AO via prev view-proj; blends with current spatial result.

struct Uniforms {
    prev_view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    /// x=blend (history weight), y=enabled, zw=screen size
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var curr_tex: texture_2d<f32>;
@group(0) @binding(3) var hist_tex: texture_2d<f32>;
@group(0) @binding(4) var depth_tex: texture_depth_2d;

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

fn reconstructWorldPos(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let world = ndc * u.inv_view_proj;
    return world.xyz / max(world.w, 1e-5);
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let curr = textureSampleLevel(curr_tex, samp, in.uv, 0.0);
    let c_ao = curr.r;
    let c_d = curr.g;

    if (u.params.y < 0.5) {
        return vec4<f32>(c_ao, c_d, 0.0, 1.0);
    }

    let dims = u.params.zw;
    let pixel = vec2<i32>(in.uv * dims);
    let depth = textureLoad(depth_tex, pixel, 0);
    if (depth >= 0.9999) {
        return vec4<f32>(1.0, depth, 0.0, 1.0);
    }

    let world = reconstructWorldPos(in.uv, depth);
    let prev_clip = vec4<f32>(world, 1.0) * u.prev_view_proj;
    let prev_ndc = prev_clip.xyz / max(prev_clip.w, 1e-5);
    let prev_uv = vec2<f32>(prev_ndc.x * 0.5 + 0.5, 0.5 - prev_ndc.y * 0.5);

    var hist_ao = c_ao;
    var blend = 0.0;
    if (all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0))) {
        let hist = textureSampleLevel(hist_tex, samp, prev_uv, 0.0);
        let depth_diff = abs(hist.g - c_d);
        if (depth_diff < 0.02) {
            hist_ao = hist.r;
            blend = u.params.x;
            // Neighborhood clamp (3x3 of current) to reduce ghosting.
            var nmin = c_ao;
            var nmax = c_ao;
            let texel = 1.0 / dims;
            for (var y = -1; y <= 1; y++) {
                for (var x = -1; x <= 1; x++) {
                    let s = textureSampleLevel(curr_tex, samp, in.uv + vec2<f32>(f32(x), f32(y)) * texel, 0.0).r;
                    nmin = min(nmin, s);
                    nmax = max(nmax, s);
                }
            }
            hist_ao = clamp(hist_ao, nmin, nmax);
        }
    }

    let ao = mix(c_ao, hist_ao, blend);
    return vec4<f32>(ao, c_d, 0.0, 1.0);
}
