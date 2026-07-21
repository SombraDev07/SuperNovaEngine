// Dual-layer cloud tracing (cumulus + strata), TAA, 3D cloud shadows, rain map, panorama.
// Dagor daSkies2 / clouds2 role on WebGPU (fullscreen FS, no compute).

struct AtmUniforms {
    sun_dir: vec4<f32>,
    moon_dir: vec4<f32>,
    cam_pos: vec4<f32>,       // y=alt km, xz=world km, w=wind_time
    weather: vec4<f32>,       // x=cumulus, y=fog, z=rain, w=snow
    time_params: vec4<f32>,   // tod, stars, moon_phase, enabled
    clouds: vec4<f32>,        // x=strata, yz=wind_dir, w=wind_speed
    cloud_ext: vec4<f32>,     // x=shadow_str, y=taa_alpha, z=panorama, w=jitter
}

@group(0) @binding(0) var<uniform> u: AtmUniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var transmittance_tex: texture_2d<f32>;
@group(0) @binding(3) var history_tex: texture_2d<f32>;
@group(0) @binding(4) var skyview_tex: texture_2d<f32>;

const PI: f32 = 3.14159265359;
const BOTTOM_RADIUS: f32 = 6360.0;

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

fn saturate(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }
fn SafeSqrt(x: f32) -> f32 { return sqrt(max(x, 0.0)); }

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let uu = f * f * (3.0 - 2.0 * f);
    let n000 = hash21(i.xy + i.z * 17.0);
    let n100 = hash21(i.xy + vec2<f32>(1.0, 0.0) + i.z * 17.0);
    let n010 = hash21(i.xy + vec2<f32>(0.0, 1.0) + i.z * 17.0);
    let n110 = hash21(i.xy + vec2<f32>(1.0, 1.0) + i.z * 17.0);
    let n001 = hash21(i.xy + (i.z + 1.0) * 17.0);
    let n101 = hash21(i.xy + vec2<f32>(1.0, 0.0) + (i.z + 1.0) * 17.0);
    let n011 = hash21(i.xy + vec2<f32>(0.0, 1.0) + (i.z + 1.0) * 17.0);
    let n111 = hash21(i.xy + vec2<f32>(1.0, 1.0) + (i.z + 1.0) * 17.0);
    return mix(
        mix(mix(n000, n100, uu.x), mix(n010, n110, uu.x), uu.y),
        mix(mix(n001, n101, uu.x), mix(n011, n111, uu.x), uu.y),
        uu.z
    );
}

fn fbm(p: vec3<f32>, oct: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var x = p;
    for (var i = 0; i < 6; i++) {
        if (i >= oct) { break; }
        v += a * noise3(x);
        x = x * 2.03 + 19.0;
        a *= 0.5;
    }
    return v;
}

fn windOffset() -> vec3<f32> {
    let dir = normalize(vec3<f32>(u.clouds.y, 0.0, u.clouds.z) + vec3<f32>(1e-4, 0.0, 0.0));
    let t = u.cam_pos.w * u.clouds.w;
    return dir * t;
}

/// Cumulus: thick mid layer ~1.2–3.8 km, billowy.
fn densityCumulus(pos_km: vec3<f32>) -> f32 {
    let cov = u.weather.x;
    if (cov < 0.01) { return 0.0; }
    let h = length(pos_km) - BOTTOM_RADIUS;
    let hm = saturate(1.0 - abs(h - 2.4) / 1.4);
    if (hm <= 0.0) { return 0.0; }
    let p = pos_km * 0.07 + windOffset() * 0.15;
    let n = fbm(p, 5);
    let worley = 1.0 - abs(noise3(p * 2.3) * 2.0 - 1.0);
    let shape = saturate(n * 0.65 + worley * 0.35 - (1.0 - cov));
    return shape * shape * hm * 3.2;
}

/// Strata: thin high veil ~6–9 km, smoother.
fn densityStrata(pos_km: vec3<f32>) -> f32 {
    let cov = u.clouds.x;
    if (cov < 0.01) { return 0.0; }
    let h = length(pos_km) - BOTTOM_RADIUS;
    let hm = saturate(1.0 - abs(h - 7.5) / 1.8);
    if (hm <= 0.0) { return 0.0; }
    let p = pos_km * 0.03 + windOffset() * 0.35 + vec3<f32>(40.0, 0.0, 12.0);
    let n = fbm(p, 3);
    let d = saturate(n - (1.0 - cov * 0.85));
    return d * hm * 1.1;
}

fn cloudDensity(pos_km: vec3<f32>) -> f32 {
    return densityCumulus(pos_km) + densityStrata(pos_km);
}

fn skyDirFromUv(uv: vec2<f32>) -> vec3<f32> {
    let azimuth = (uv.x - 0.5) * 2.0 * PI;
    let v = saturate(uv.y);
    let cos_z = mix(-0.15, 1.0, v * v);
    let sin_z = SafeSqrt(1.0 - cos_z * cos_z);
    return normalize(vec3<f32>(cos(azimuth) * sin_z, cos_z, sin(azimuth) * sin_z));
}

fn miePhase(cos_theta: f32, g: f32) -> f32 {
    let g2 = g * g;
    let denom = pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
    return (3.0 / (8.0 * PI)) * ((1.0 - g2) * (1.0 + cos_theta * cos_theta)) / ((2.0 + g2) * denom);
}

/// Dedicated cloud tracer (half-res). RGB = inscatter, A = transmittance.
@fragment
fn fs_cloud_trace(in: VsOut) -> @location(0) vec4<f32> {
    let jitter = (hash21(in.uv * 1024.0 + u.cloud_ext.w) - 0.5) * 0.002;
    let uv = in.uv + vec2<f32>(jitter);
    let rd = skyDirFromUv(uv);
    let ro = vec3<f32>(0.0, BOTTOM_RADIUS + max(u.cam_pos.y, 0.001), 0.0);
    let sun = normalize(u.sun_dir.xyz);

    // March only through cloud altitude band (cumulus + strata).
    let t0 = 0.5;
    let t1 = 120.0;
    let steps = 48.0;
    let dt = (t1 - t0) / steps;
    var tr = 1.0;
    var lum = vec3<f32>(0.0);

    var i = 0.0;
    loop {
        if (i >= steps) { break; }
        let t = t0 + (i + 0.5) * dt;
        let p = ro + rd * t;
        let h = length(p) - BOTTOM_RADIUS;
        if (h < 0.8 || h > 10.0) { i += 1.0; continue; }
        let d = cloudDensity(p);
        if (d > 0.001) {
            let sigma = d * 0.55;
            // Light march toward sun (cheap self-shadow).
            var light_od = 0.0;
            var s = 1.0;
            loop {
                if (s > 4.0) { break; }
                let lp = p + sun * s * 0.35;
                light_od += cloudDensity(lp) * 0.35;
                s += 1.0;
            }
            let beer = exp(-light_od * 1.2);
            let cos_th = saturate(dot(rd, sun));
            let phase = mix(0.4, miePhase(cos_th, 0.6), 0.7);
            let powder = 1.0 - exp(-d * 2.0);
            let ambient = vec3<f32>(0.08, 0.10, 0.14) * (0.3 + 0.7 * u.sun_dir.w)
                + vec3<f32>(0.02, 0.03, 0.05) * u.moon_dir.w;
            let sun_c = vec3<f32>(1.0, 0.96, 0.90) * u.sun_dir.w * beer * phase * powder;
            let sample_l = (sun_c + ambient) * sigma;
            lum += tr * sample_l * dt;
            tr *= exp(-sigma * dt);
            if (tr < 0.02) { break; }
        }
        i += 1.0;
    }
    return vec4<f32>(lum, tr);
}

/// Temporal accumulation (Dagor daCloudsTaa role).
@fragment
fn fs_cloud_taa(in: VsOut) -> @location(0) vec4<f32> {
    // history_tex = previous TAA; skyview unused slot reused as current trace via binding remap.
    // Binding layout: 3=history, 4=current_trace (bound as skyview_tex name).
    let cur = textureSampleLevel(skyview_tex, samp, in.uv, 0.0);
    let wind = vec2<f32>(u.clouds.y, u.clouds.z) * u.clouds.w * 0.0008;
    let hist_uv = clamp(in.uv - wind, vec2<f32>(0.0), vec2<f32>(1.0));
    let hist = textureSampleLevel(history_tex, samp, hist_uv, 0.0);
    let a = clamp(u.cloud_ext.y, 0.05, 0.35);
    // Reject history if transmittance diverges a lot (camera/cut).
    let reject = select(a, 1.0, abs(cur.a - hist.a) > 0.45);
    let out_c = mix(hist, cur, reject);
    return out_c;
}

/// Top-down cloud shadow map: RGBA = optical depth at 4 altitude bands (pseudo-3D).
@fragment
fn fs_cloud_shadow(in: VsOut) -> @location(0) vec4<f32> {
    // Map UV → world XZ km around camera (±40 km).
    let extent = 40.0;
    let xz = (in.uv * 2.0 - 1.0) * extent + u.cam_pos.xz;
    let sun = normalize(u.sun_dir.xyz);
    // Avoid grazing singularity.
    let sun_up = max(sun.y, 0.08);
    let sun_march = vec3<f32>(sun.x, sun_up, sun.z);

    let bands = array<f32, 4>(1.5, 2.5, 4.0, 7.5);
    var od = vec4<f32>(0.0);
    for (var b = 0; b < 4; b++) {
        let h0 = bands[b];
        // March from band height along -sun through cloud stack.
        var p = vec3<f32>(xz.x, BOTTOM_RADIUS + h0, xz.y);
        var o = 0.0;
        for (var s = 0; s < 16; s++) {
            p += sun_march * 0.25;
            o += cloudDensity(p) * 0.25;
        }
        if (b == 0) { od.x = o; }
        else if (b == 1) { od.y = o; }
        else if (b == 2) { od.z = o; }
        else { od.w = o; }
    }
    return od * u.cloud_ext.x;
}

/// GPU rain coverage map (Dagor rain map role): R=rain, G=puddle/wet, B=snow.
@fragment
fn fs_rain_map(in: VsOut) -> @location(0) vec4<f32> {
    let extent = 32.0;
    let xz = (in.uv * 2.0 - 1.0) * extent + u.cam_pos.xz;
    let wind = windOffset().xz;
    let n = fbm(vec3<f32>(xz.x * 0.12 + wind.x, 0.0, xz.y * 0.12 + wind.y), 4);
    let cell = hash21(floor(xz * 0.5));
    let rain_base = u.weather.z;
    let snow_base = u.weather.w;
    // Heavier rain under cumulus coverage blobs.
    let under_cloud = saturate(n - (1.0 - u.weather.x * 0.9));
    let rain = saturate(rain_base * (0.35 + under_cloud * 1.2 + cell * 0.15));
    let wet = saturate(rain * 1.4 + rain_base * 0.3);
    let snow = saturate(snow_base * (0.4 + (1.0 - under_cloud) * 0.6));
    return vec4<f32>(rain, wet, snow, 1.0);
}

/// Equirect panorama (sky + clouds) for reflection probes / IBL bake.
@fragment
fn fs_panorama(in: VsOut) -> @location(0) vec4<f32> {
    let phi = in.uv.x * 2.0 * PI;
    let theta = (1.0 - in.uv.y) * PI; // 0 zenith → pi nadir
    let rd = normalize(vec3<f32>(
        sin(theta) * cos(phi),
        cos(theta),
        sin(theta) * sin(phi)
    ));
    // Sample sky-view LUT.
    let az = atan2(rd.z, rd.x);
    let u_az = az / (2.0 * PI) + 0.5;
    let cos_z = clamp(rd.y, -0.15, 1.0);
    let v_lin = (cos_z + 0.15) / 1.15;
    let u_v = sqrt(clamp(v_lin, 0.0, 1.0));
    var sky = textureSampleLevel(skyview_tex, samp, vec2<f32>(u_az, u_v), 0.0).rgb;

    // Overlay cloud TAA (history_tex holds resolved clouds).
    let clouds = textureSampleLevel(history_tex, samp, vec2<f32>(u_az, u_v), 0.0);
    sky = sky * clouds.a + clouds.rgb;

    // Cheap ground fill for lower hemisphere.
    if (rd.y < 0.0) {
        let g = saturate(-rd.y);
        sky = mix(sky, vec3<f32>(0.12, 0.11, 0.09) * (0.2 + 0.8 * u.sun_dir.w), g);
    }
    return vec4<f32>(sky, 1.0);
}
