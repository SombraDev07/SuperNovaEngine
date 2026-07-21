// daGI2 RadianceGrid update — screen bounce + WorldSDF/lit voxel world trace.

struct Uniforms {
    inv_view_proj: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
    origin_spacing: vec4<f32>,
    origin1: vec4<f32>,
    origin2: vec4<f32>,
    grid_octa: vec4<f32>,
    params: vec4<f32>,
    sun_dir: vec4<f32>,
    sun_color: vec4<f32>,
    screen: vec4<f32>,
    camera_pos: vec4<f32>,
    budget: vec4<f32>,
    vol_clip0: vec4<f32>,
    vol_clip1: vec4<f32>,
    vol_clip2: vec4<f32>,
    vol_clip3: vec4<f32>,
    /// x=res_xz y=res_y z=clips w=atlas_w
    vol_dims: vec4<f32>,
    /// x=atlas_h y=slices_per_row z=band w=enabled
    vol_atlas: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var depth_tex: texture_depth_2d;
@group(0) @binding(3) var albedo_tex: texture_2d<f32>;
@group(0) @binding(4) var normal_tex: texture_2d<f32>;
@group(0) @binding(5) var hist_irr_tex: texture_2d<f32>;
@group(0) @binding(6) var hist_dist_tex: texture_2d<f32>;
@group(0) @binding(7) var prev_hdr_tex: texture_2d<f32>;
@group(0) @binding(8) var env_cube: texture_cube<f32>;
@group(0) @binding(9) var env_samp: sampler;
@group(0) @binding(10) var sdf_atlas: texture_2d<f32>;
@group(0) @binding(11) var lit_atlas: texture_2d<f32>;
@group(0) @binding(12) var alb_atlas: texture_2d<f32>;

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

struct FsOut {
    @location(0) irradiance: vec4<f32>,
    @location(1) distance: vec4<f32>,
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

fn reconstructWorldPos(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let world = ndc * u.inv_view_proj;
    return world.xyz / max(world.w, 1e-5);
}

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn sampleSky(dir: vec3<f32>) -> vec3<f32> {
    return textureSampleLevel(env_cube, env_samp, dir, 3.0).rgb;
}

fn volClip(c: u32) -> vec4<f32> {
    if (c == 0u) { return u.vol_clip0; }
    if (c == 1u) { return u.vol_clip1; }
    if (c == 2u) { return u.vol_clip2; }
    return u.vol_clip3;
}

fn sdfAtlasUv(clip: u32, tc: vec3<f32>) -> vec2<f32> {
    let rx = u.vol_dims.x;
    let ry = u.vol_dims.y;
    let spr = max(u.vol_atlas.y, 1.0);
    let aw = u.vol_dims.w;
    let ah = u.vol_atlas.x;
    let ix = clamp(tc.x * rx, 0.0, rx - 0.001);
    let iy = clamp(tc.y * ry, 0.0, ry - 0.001);
    let iz = clamp(tc.z * rx, 0.0, rx - 0.001);
    let slice = f32(clip) * rx + iz;
    let tile_col = floor(slice % spr);
    let tile_row = floor(slice / spr);
    let px = tile_col * rx + ix;
    let py = tile_row * ry + iy;
    return vec2<f32>((px + 0.5) / aw, (py + 0.5) / ah);
}

fn sampleSdf(clip: u32, world: vec3<f32>) -> f32 {
    let cv = volClip(clip);
    let vs = max(cv.w, 0.05);
    let rx = u.vol_dims.x;
    let ry = u.vol_dims.y;
    let local = (world - cv.xyz) / vs;
    let tc = local / vec3<f32>(rx, ry, rx);
    if (any(tc < vec3<f32>(0.0)) || any(tc > vec3<f32>(1.0))) {
        return 1.0;
    }
    let enc = textureSampleLevel(sdf_atlas, samp, sdfAtlasUv(clip, tc), 0.0).r;
    let band = max(u.vol_atlas.z, 1.0) * vs;
    return enc * band;
}

fn sampleLit(clip: u32, world: vec3<f32>) -> vec4<f32> {
    let cv = volClip(clip);
    let vs = max(cv.w, 0.05);
    let rx = u.vol_dims.x;
    let ry = u.vol_dims.y;
    let local = (world - cv.xyz) / vs;
    let tc = local / vec3<f32>(rx, ry, rx);
    if (any(tc < vec3<f32>(0.02)) || any(tc > vec3<f32>(0.98))) {
        return vec4<f32>(0.0);
    }
    return textureSampleLevel(lit_atlas, samp, sdfAtlasUv(clip, tc), 0.0);
}

fn sampleAlbedo(clip: u32, world: vec3<f32>) -> vec4<f32> {
    let cv = volClip(clip);
    let vs = max(cv.w, 0.05);
    let rx = u.vol_dims.x;
    let ry = u.vol_dims.y;
    let local = (world - cv.xyz) / vs;
    let tc = local / vec3<f32>(rx, ry, rx);
    if (any(tc < vec3<f32>(0.02)) || any(tc > vec3<f32>(0.98))) {
        return vec4<f32>(0.0);
    }
    return textureSampleLevel(alb_atlas, samp, sdfAtlasUv(clip, tc), 0.0);
}

fn sdfGradient(clip: u32, world: vec3<f32>) -> vec3<f32> {
    let vs = max(volClip(clip).w, 0.05);
    let e = vs * 0.75;
    let dx = sampleSdf(clip, world + vec3<f32>(e, 0.0, 0.0)) - sampleSdf(clip, world - vec3<f32>(e, 0.0, 0.0));
    let dy = sampleSdf(clip, world + vec3<f32>(0.0, e, 0.0)) - sampleSdf(clip, world - vec3<f32>(0.0, e, 0.0));
    let dz = sampleSdf(clip, world + vec3<f32>(0.0, 0.0, e)) - sampleSdf(clip, world - vec3<f32>(0.0, 0.0, e));
    let g = vec3<f32>(dx, dy, dz);
    let len = length(g);
    if (len < 1e-5) { return vec3<f32>(0.0, 1.0, 0.0); }
    return g / len;
}

struct TraceResult {
    radiance: vec3<f32>,
    dist: f32,
    hit: f32,
}

fn traceScreen(probe_pos: vec3<f32>, dir: vec3<f32>, jitter: f32, spacing: f32) -> TraceResult {
    var out: TraceResult;
    out.radiance = vec3<f32>(0.0);
    out.dist = 1.0;
    out.hit = 0.0;
    let max_dist = spacing * clamp(u.params.y, 0.5, 3.0);
    let dims = max(u.screen.xy, vec2<f32>(1.0));
    let steps = i32(clamp(u.budget.y * 0.5, 6.0, 12.0));
    for (var i = 0; i < 12; i++) {
        if (i >= steps) { break; }
        let t = (f32(i) + 0.5 + jitter) / f32(steps) * max_dist;
        let p = probe_pos + dir * t;
        let clip = vec4<f32>(p, 1.0) * u.view_proj;
        if (clip.w <= 1e-4) { continue; }
        let ndc = clip.xyz / clip.w;
        if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z <= 0.0 || ndc.z >= 1.0) { continue; }
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        let pixel = vec2<i32>(clamp(uv * dims, vec2<f32>(0.0), dims - vec2<f32>(1.0)));
        let depth = textureLoad(depth_tex, pixel, 0);
        if (depth >= 0.9999) { continue; }
        let scene_pos = reconstructWorldPos(uv, depth);
        let scene_dist = length(scene_pos - probe_pos);
        if (scene_dist < 0.04 || scene_dist > max_dist * 1.15) { continue; }
        if (dot(normalize(scene_pos - probe_pos), dir) < 0.6) { continue; }
        if (scene_dist > t + spacing * 0.25) { continue; }
        var rad = textureSampleLevel(prev_hdr_tex, samp, uv, 0.0).rgb;
        if (dot(rad, vec3<f32>(0.2126, 0.7152, 0.0722)) < 0.002) {
            let albedo = textureSampleLevel(albedo_tex, samp, uv, 0.0).rgb;
            let n = decodeOct(textureSampleLevel(normal_tex, samp, uv, 0.0).xy);
            rad = albedo * (u.sun_color.xyz * max(dot(n, u.sun_dir.xyz), 0.0) + vec3<f32>(u.sun_color.w));
        }
        out.radiance = rad;
        out.dist = saturate(scene_dist / max_dist);
        out.hit = 1.0;
        break;
    }
    return out;
}

fn traceSdf(probe_pos: vec3<f32>, dir: vec3<f32>, max_dist: f32) -> TraceResult {
    var out: TraceResult;
    out.radiance = sampleSky(dir);
    out.dist = 1.0;
    out.hit = 0.0;
    if (u.vol_atlas.w < 0.5) { return out; }

    var p = probe_pos + dir * 0.08;
    var t = 0.08;
    let nclips = u32(u.vol_dims.z);
    for (var i = 0; i < 48; i++) {
        if (t > max_dist) { break; }
        var best_c = nclips;
        var d = 1e5;
        for (var c = 0u; c < 4u; c++) {
            if (c >= nclips) { break; }
            let cv = volClip(c);
            let vs = max(cv.w, 0.05);
            let ext = vec3<f32>(u.vol_dims.x, u.vol_dims.y, u.vol_dims.x) * vs;
            let local = p - cv.xyz;
            if (all(local >= vec3<f32>(0.0)) && all(local < ext)) {
                best_c = c;
                d = sampleSdf(c, p);
                break;
            }
        }
        if (best_c >= nclips) {
            t += 0.35;
            p = probe_pos + dir * t;
            continue;
        }
        if (d < max(volClip(best_c).w * 0.4, 0.05)) {
            let n = sdfGradient(best_c, p);
            // Step onto surface along gradient (daGI expandSurface).
            let p_hit = p - n * d * 0.5;
            var lit = sampleLit(best_c, p_hit);
            if (lit.a < 0.05 && best_c + 1u < nclips) {
                lit = sampleLit(best_c + 1u, p_hit);
            }
            if (lit.a > 0.05) {
                out.radiance = lit.rgb;
            } else {
                // AlbedoScene fallback × analytic sun/sky (daGI2 dagi_get_radiance_at).
                var alb = sampleAlbedo(best_c, p_hit);
                if (alb.a < 0.05 && best_c + 1u < nclips) {
                    alb = sampleAlbedo(best_c + 1u, p_hit);
                }
                if (alb.a > 0.05) {
                    let ndl = max(dot(n, u.sun_dir.xyz), 0.0);
                    out.radiance = alb.rgb * (u.sun_color.xyz * ndl + vec3<f32>(u.sun_color.w) + sampleSky(n) * 0.25);
                } else {
                    out.radiance = sampleSky(reflect(-dir, n)) * 0.45;
                }
            }
            out.dist = saturate(t / max_dist);
            out.hit = 1.0;
            break;
        }
        // Coarser cascade miss → continue with larger step (daGI cascade walk).
        let step = max(d * 0.8, volClip(best_c).w * 0.2);
        t += step;
        p = probe_pos + dir * t;
    }
    return out;
}

fn clipOriginSpacing(clip: f32) -> vec4<f32> {
    if (clip < 0.5) { return u.origin_spacing; }
    if (clip < 1.5) { return u.origin1; }
    return u.origin2;
}

@fragment
fn fs_main(in: VsOut) -> FsOut {
    var out: FsOut;
    let hist_i = textureSampleLevel(hist_irr_tex, samp, in.uv, 0.0);
    let hist_d = textureSampleLevel(hist_dist_tex, samp, in.uv, 0.0);
    out.irradiance = hist_i;
    out.distance = hist_d;
    if (u.budget.z < 0.5) { return out; }

    let gx = u.grid_octa.x;
    let gy = u.grid_octa.y;
    let gz = u.grid_octa.z;
    let octa = u.grid_octa.w;
    let nclips = max(u.budget.w, 1.0);
    let clip_h = gy * gz * octa;
    let atlas = vec2<f32>(textureDimensions(hist_irr_tex));
    let pixel = in.uv * atlas;
    let px = floor(pixel.x);
    let py = floor(pixel.y);
    let clip_i = floor(py / clip_h);
    if (clip_i >= nclips) {
        out.irradiance = vec4<f32>(0.0, 0.0, 0.0, 1.0);
        out.distance = vec4<f32>(1.0, 1.0, 0.0, 1.0);
        return out;
    }
    let local_y = py - clip_i * clip_h;
    let probe_x = floor(px / octa);
    let local_x = px - probe_x * octa;
    let row = floor(local_y / octa);
    let local_oct_y = local_y - row * octa;
    let probe_z = floor(row / gy);
    let probe_y = row - probe_z * gy;
    if (probe_x >= gx || probe_y >= gy || probe_z >= gz) {
        out.irradiance = vec4<f32>(0.0, 0.0, 0.0, 1.0);
        out.distance = vec4<f32>(1.0, 1.0, 0.0, 1.0);
        return out;
    }

    let probe_count = gx * gy * gz * nclips;
    let probe_id = probe_x + probe_y * gx + probe_z * gx * gy + clip_i * gx * gy * gz;
    let ppf = max(u.budget.x, 1.0);
    let frame = u.params.z;
    let batches = max(ceil(probe_count / ppf), 1.0);
    let batch = floor(frame) % batches;
    let my_batch = floor(probe_id / ppf);
    let do_update = my_batch == batch || frame < 12.0;
    if (!do_update) { return out; }

    let os = clipOriginSpacing(clip_i);
    let spacing = os.w;
    let origin = os.xyz;
    let probe_pos = origin + vec3<f32>(probe_x, probe_y, probe_z) * spacing;
    let octa_uv = (vec2<f32>(local_x, local_oct_y) + 0.5) / octa;
    var dir = decodeOct(octa_uv);
    let ang = frame * 0.11 + hash2(pixel) * 6.28318;
    let ca = cos(ang * 0.02);
    let sa = sin(ang * 0.02);
    dir = normalize(vec3<f32>(dir.x * ca - dir.z * sa, dir.y, dir.x * sa + dir.z * ca));
    let jitter = hash2(pixel + vec2<f32>(frame, 7.0));

    var tr = traceScreen(probe_pos, dir, jitter, spacing);
    if (tr.hit < 0.5) {
        tr = traceSdf(probe_pos, dir, spacing * clamp(u.params.y, 0.5, 3.0) * 2.5);
    }

    let n_oct = decodeOct(octa_uv);
    let weight = max(dot(n_oct, dir), 0.0) * 2.0 + 0.15;
    let new_irr = tr.radiance * weight;
    let new_dist = tr.dist;
    let new_dist2 = tr.dist * tr.dist;
    let blend = clamp(u.params.x, 0.5, 0.97);
    let hist_lum = dot(hist_i.rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    let use_hist = hist_lum > 1e-5;
    let irr = select(new_irr, mix(new_irr, hist_i.rgb, blend), use_hist);
    let d_mean = select(new_dist, mix(new_dist, hist_d.r, blend), use_hist);
    let d_mean2 = select(new_dist2, mix(new_dist2, hist_d.g, blend), use_hist);
    out.irradiance = vec4<f32>(max(irr, vec3<f32>(0.0)), 1.0);
    out.distance = vec4<f32>(d_mean, d_mean2, tr.hit, 1.0);
    return out;
}
