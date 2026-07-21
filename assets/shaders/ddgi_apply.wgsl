// Phase A+C apply: multi-clip trilinear octa irradiance × Chebyshev.

struct Uniforms {
    inv_view_proj: mat4x4<f32>,
    origin: vec4<f32>,
    origin1: vec4<f32>,
    origin2: vec4<f32>,
    grid: vec4<f32>,
    params: vec4<f32>,
    camera_pos: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var albedo_ao_tex: texture_2d<f32>;
@group(0) @binding(3) var normal_oct_tex: texture_2d<f32>;
@group(0) @binding(4) var material_tex: texture_2d<f32>;
@group(0) @binding(5) var depth_tex: texture_depth_2d;
@group(0) @binding(6) var gtao_tex: texture_2d<f32>;
@group(0) @binding(7) var ddgi_irr_tex: texture_2d<f32>;
@group(0) @binding(8) var ddgi_dist_tex: texture_2d<f32>;

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

fn encodeOct(v: vec3<f32>) -> vec2<f32> {
    var n = v / max(abs(v.x) + abs(v.y) + abs(v.z), 1e-5);
    var o = n.xy;
    if (n.z < 0.0) {
        let sx = select(-1.0, 1.0, o.x >= 0.0);
        let sy = select(-1.0, 1.0, o.y >= 0.0);
        o = (vec2<f32>(1.0) - abs(o.yx)) * vec2<f32>(sx, sy);
    }
    return o * 0.5 + 0.5;
}

fn reconstructWorldPos(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let world = ndc * u.inv_view_proj;
    return world.xyz / max(world.w, 1e-5);
}

fn chebyshev(dist_to_probe: f32, mean: f32, mean2: f32) -> f32 {
    if (dist_to_probe <= mean) {
        return 1.0;
    }
    let variance = max(mean2 - mean * mean, 1e-4);
    let d = dist_to_probe - mean;
    return saturate(variance / (variance + d * d));
}

fn clipOrigin(clip: i32) -> vec3<f32> {
    if (clip == 0) { return u.origin.xyz; }
    if (clip == 1) { return u.origin1.xyz; }
    return u.origin2.xyz;
}

fn clipSpacing(clip: i32, spacing0: f32) -> f32 {
    if (clip == 0) { return spacing0; }
    if (clip == 1) { return u.origin1.w; }
    return u.origin2.w;
}

fn sampleProbeCorner(
    pid: vec3<f32>,
    n: vec3<f32>,
    world_pos: vec3<f32>,
    origin: vec3<f32>,
    spacing: f32,
    octa: f32,
    gx: f32,
    gy: f32,
    gz: f32,
    clip: f32,
    nclips: f32,
) -> vec4<f32> {
    let oct_uv = encodeOct(n);
    let clip_h = gy * gz * octa;
    let atlas_h = clip_h * nclips;
    let atlas_uv = vec2<f32>(
        (pid.x * octa + oct_uv.x * octa) / (gx * octa),
        (clip * clip_h + (pid.z * gy + pid.y) * octa + oct_uv.y * octa) / atlas_h,
    );
    let irr = textureSampleLevel(ddgi_irr_tex, samp, atlas_uv, 0.0).rgb;
    let dist_s = textureSampleLevel(ddgi_dist_tex, samp, atlas_uv, 0.0);
    let probe_pos = origin + pid * spacing;
    let dist_to = length(world_pos - probe_pos) / max(spacing * 1.732, 0.01);
    let vis = chebyshev(dist_to, dist_s.r, max(dist_s.g, dist_s.r * dist_s.r));
    return vec4<f32>(irr, vis);
}

fn sampleClip(world_pos: vec3<f32>, n: vec3<f32>, clip: i32, require_inside: bool) -> vec4<f32> {
    // rgb irradiance, a = 1 if used
    let spacing0 = max(u.grid.x, 0.01);
    let gx = max(u.grid.y, 2.0);
    let gy = max(u.grid.z, 2.0);
    let gz = max(u.grid.w, 2.0);
    let octa = max(u.params.x, 2.0);
    let nclips = max(u.params.w, 1.0);
    let origin = clipOrigin(clip);
    let spacing = clipSpacing(clip, spacing0);

    var coord = (world_pos - origin) / spacing;
    let lo = vec3<f32>(0.25);
    let hi = vec3<f32>(gx, gy, gz) - vec3<f32>(1.25);
    let inside = all(coord >= lo) && all(coord <= hi);
    if (require_inside && !inside) {
        return vec4<f32>(0.0);
    }
    coord = clamp(coord, vec3<f32>(0.0), vec3<f32>(gx, gy, gz) - vec3<f32>(1.001));
    let base = floor(coord);
    let f = fract(coord);

    var irr = vec3<f32>(0.0);
    var wsum = 0.0;
    for (var iz = 0; iz < 2; iz++) {
        for (var iy = 0; iy < 2; iy++) {
            for (var ix = 0; ix < 2; ix++) {
                let pid = base + vec3<f32>(f32(ix), f32(iy), f32(iz));
                let trilin =
                    select(1.0 - f.x, f.x, ix == 1) *
                    select(1.0 - f.y, f.y, iy == 1) *
                    select(1.0 - f.z, f.z, iz == 1);
                let s = sampleProbeCorner(pid, n, world_pos, origin, spacing, octa, gx, gy, gz, f32(clip), nclips);
                let w = trilin * max(s.a, 0.05);
                irr += s.rgb * w;
                wsum += w;
            }
        }
    }
    let L0 = max(irr / max(wsum, 1e-4), vec3<f32>(0.0));
    // Detailed irradiance (SH1 / SPH role): L0 + directional lobe · n
    let pid_c = base + f;
    let sx = sampleProbeCorner(pid_c, vec3<f32>(1.0, 0.0, 0.0), world_pos, origin, spacing, octa, gx, gy, gz, f32(clip), nclips).rgb;
    let sy = sampleProbeCorner(pid_c, vec3<f32>(0.0, 1.0, 0.0), world_pos, origin, spacing, octa, gx, gy, gz, f32(clip), nclips).rgb;
    let sz = sampleProbeCorner(pid_c, vec3<f32>(0.0, 0.0, 1.0), world_pos, origin, spacing, octa, gx, gy, gz, f32(clip), nclips).rgb;
    let L1 = (sx * n.x + sy * n.y + sz * n.z) * 0.45;
    return vec4<f32>(max(L0 + L1, vec3<f32>(0.0)), 1.0);
}

fn sampleDdgi(world_pos: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
    let nclips = i32(max(u.params.w, 1.0));
    // Finest cascade first (daGI2 irradiance clip selection).
    for (var c = 0; c < 3; c++) {
        if (c >= nclips) { break; }
        let s = sampleClip(world_pos, n, c, true);
        if (s.a > 0.5) {
            return s.rgb * u.origin.w;
        }
    }
    let last = sampleClip(world_pos, n, nclips - 1, false);
    return last.rgb * u.origin.w;
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
    let world_pos = reconstructWorldPos(in.uv, depth);

    let irr = sampleDdgi(world_pos, n);
    let kd = 1.0 - metallic;
    let blend = u.params.z;
    let gi = albedo_ao.rgb * irr * kd * ao * blend;
    return vec4<f32>(gi, 0.0);
}
