// Bruneton-style atmosphere LUTs (transmittance + Hillaire MS + sky-view).
// Parametrization aligned with Dagor daSkies2 / Eric Bruneton + Sébastien Hillaire.

struct AtmUniforms {
    sun_dir: vec4<f32>,       // xyz = toward sun, w = sun illuminance scale
    moon_dir: vec4<f32>,      // xyz = toward moon, w = moon illuminance
    cam_pos: vec4<f32>,       // y=alt km, xz=world km, w=wind_time
    weather: vec4<f32>,       // x=cumulus, y=fog, z=rain, w=snow
    time_params: vec4<f32>,   // tod, stars, moon_phase, enabled
    clouds: vec4<f32>,        // strata, wind_dir.xy, wind_speed
    cloud_ext: vec4<f32>,     // shadow_str, taa_alpha, panorama, jitter
}

@group(0) @binding(0) var<uniform> u: AtmUniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var transmittance_tex: texture_2d<f32>;
@group(0) @binding(3) var multiscatter_tex: texture_2d<f32>;

const PI: f32 = 3.14159265359;
const BOTTOM_RADIUS: f32 = 6360.0;
const TOP_RADIUS: f32 = 6460.0;
const RAYLEIGH_SCALE: f32 = 8.0;
const MIE_SCALE: f32 = 1.2;
const RAYLEIGH_SCATTERING: vec3<f32> = vec3<f32>(0.005802, 0.013558, 0.033100);
const MIE_SCATTERING: vec3<f32> = vec3<f32>(0.003996, 0.003996, 0.003996);
const MIE_ABSORPTION: vec3<f32> = vec3<f32>(0.000444, 0.000444, 0.000444);
const OZONE_ABSORPTION: vec3<f32> = vec3<f32>(0.000650, 0.001881, 0.000085);
const MIE_G: f32 = 0.8;
const GROUND_ALBEDO: vec3<f32> = vec3<f32>(0.3, 0.3, 0.3);
const SOLAR_IRRADIANCE: vec3<f32> = vec3<f32>(1.0, 0.985, 0.92);

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

fn rayleighPhase(cos_theta: f32) -> f32 {
    return (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
}

fn miePhase(cos_theta: f32, g: f32) -> f32 {
    let g2 = g * g;
    let denom = pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
    return (3.0 / (8.0 * PI)) * ((1.0 - g2) * (1.0 + cos_theta * cos_theta)) / ((2.0 + g2) * denom);
}

fn densityRayleigh(h: f32) -> f32 { return exp(-h / RAYLEIGH_SCALE); }
fn densityMie(h: f32) -> f32 { return exp(-h / MIE_SCALE); }
fn densityOzone(h: f32) -> f32 {
    // Linear tent around ~25 km (Bruneton ozone layer).
    return max(0.0, 1.0 - abs(h - 25.0) / 15.0);
}

fn extinction(h: f32) -> vec3<f32> {
    let ray = RAYLEIGH_SCATTERING * densityRayleigh(h);
    let mie = (MIE_SCATTERING + MIE_ABSORPTION) * densityMie(h);
    let ozone = OZONE_ABSORPTION * densityOzone(h);
    return ray + mie + ozone;
}

fn scattering(h: f32) -> vec3<f32> {
    return RAYLEIGH_SCATTERING * densityRayleigh(h) + MIE_SCATTERING * densityMie(h);
}

fn raySphereIntersectNearest(ro: vec3<f32>, rd: vec3<f32>, center: vec3<f32>, radius: f32) -> f32 {
    let oc = ro - center;
    let b = dot(oc, rd);
    let c = dot(oc, oc) - radius * radius;
    let h = b * b - c;
    if (h < 0.0) { return -1.0; }
    let s = sqrt(h);
    let t0 = -b - s;
    let t1 = -b + s;
    if (t0 > 0.0) { return t0; }
    if (t1 > 0.0) { return t1; }
    return -1.0;
}

fn unitToUv(x: f32, size: f32) -> f32 {
    return 0.5 / size + x * (1.0 - 1.0 / size);
}

fn uvToUnit(u: f32, size: f32) -> f32 {
    return saturate((u - 0.5 / size) / (1.0 - 1.0 / size));
}

fn transmittanceUvFromRMu(r: f32, mu: f32) -> vec2<f32> {
    let h = sqrt(max(TOP_RADIUS * TOP_RADIUS - BOTTOM_RADIUS * BOTTOM_RADIUS, 0.0));
    let rho = SafeSqrt(r * r - BOTTOM_RADIUS * BOTTOM_RADIUS);
    let d = max(0.0, -r * mu + SafeSqrt(r * r * (mu * mu - 1.0) + TOP_RADIUS * TOP_RADIUS));
    let d_min = TOP_RADIUS - r;
    let d_max = rho + h;
    let x_mu = (d - d_min) / max(d_max - d_min, 1e-4);
    let x_r = rho / h;
    return vec2<f32>(unitToUv(x_mu, 256.0), unitToUv(x_r, 64.0));
}

fn SafeSqrt(x: f32) -> f32 { return sqrt(max(x, 0.0)); }

fn rMuFromTransmittanceUv(uv: vec2<f32>) -> vec2<f32> {
    let x_mu = uvToUnit(uv.x, 256.0);
    let x_r = uvToUnit(uv.y, 64.0);
    let h = sqrt(max(TOP_RADIUS * TOP_RADIUS - BOTTOM_RADIUS * BOTTOM_RADIUS, 0.0));
    let rho = h * x_r;
    let r = select(BOTTOM_RADIUS, sqrt(rho * rho + BOTTOM_RADIUS * BOTTOM_RADIUS), rho > 0.0);
    let d_min = TOP_RADIUS - r;
    let d_max = rho + h;
    let d = d_min + x_mu * (d_max - d_min);
    var mu = 1.0;
    if (d > 0.0) {
        mu = (h * h - rho * rho - d * d) / (2.0 * r * d);
        mu = clamp(mu, -1.0, 1.0);
    }
    return vec2<f32>(r, mu);
}

fn integrateOpticalDepth(r: f32, mu: f32) -> vec3<f32> {
    let sample_count = 40.0;
    let planet = vec3<f32>(0.0, 0.0, 0.0);
    let ro = vec3<f32>(0.0, r, 0.0);
    let rd = vec3<f32>(sqrt(max(1.0 - mu * mu, 0.0)), mu, 0.0);
    var t_max = raySphereIntersectNearest(ro, rd, planet, TOP_RADIUS);
    if (t_max < 0.0) { return vec3<f32>(1e20); }
    let t_ground = raySphereIntersectNearest(ro, rd, planet, BOTTOM_RADIUS);
    if (t_ground > 0.0) { t_max = min(t_max, t_ground); }
    let dt = t_max / sample_count;
    var od = vec3<f32>(0.0);
    var i = 0.0;
    loop {
        if (i >= sample_count) { break; }
        let t = (i + 0.5) * dt;
        let p = ro + rd * t;
        let h = length(p) - BOTTOM_RADIUS;
        od += extinction(h) * dt;
        i += 1.0;
    }
    return od;
}

@fragment
fn fs_transmittance(in: VsOut) -> @location(0) vec4<f32> {
    let rm = rMuFromTransmittanceUv(in.uv);
    let od = integrateOpticalDepth(rm.x, rm.y);
    let t = exp(-od);
    return vec4<f32>(t, 1.0);
}

fn sampleTransmittance(r: f32, mu: f32) -> vec3<f32> {
    let uv = transmittanceUvFromRMu(clamp(r, BOTTOM_RADIUS, TOP_RADIUS), clamp(mu, -1.0, 1.0));
    return textureSampleLevel(transmittance_tex, samp, uv, 0.0).rgb;
}

fn sampleMultiscatter(r: f32, mu_s: f32) -> vec3<f32> {
    let u_r = saturate((r - BOTTOM_RADIUS) / (TOP_RADIUS - BOTTOM_RADIUS));
    let u_mu = saturate(mu_s * 0.5 + 0.5);
    return textureSampleLevel(multiscatter_tex, samp, vec2<f32>(u_mu, u_r), 0.0).rgb;
}

// Hillaire-style infinite isotropic MS approximation LUT (32²).
@fragment
fn fs_multiscatter(in: VsOut) -> @location(0) vec4<f32> {
    let mu_s = in.uv.x * 2.0 - 1.0;
    let r = mix(BOTTOM_RADIUS, TOP_RADIUS, in.uv.y);
    let sample_count = 20.0;
    let sun_dir = vec3<f32>(sqrt(max(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0);
    let planet = vec3<f32>(0.0);
    let ro = vec3<f32>(0.0, r, 0.0);

    var lum = vec3<f32>(0.0);
    var i = 0.0;
    loop {
        if (i >= sample_count) { break; }
        let t = (i + 0.5) / sample_count;
        // Uniform sphere sample (Fibonacci-ish).
        let phi = i * 2.39996323;
        let z = 1.0 - 2.0 * t;
        let xy = SafeSqrt(1.0 - z * z);
        let rd = vec3<f32>(cos(phi) * xy, z, sin(phi) * xy);
        var t_max = raySphereIntersectNearest(ro, rd, planet, TOP_RADIUS);
        if (t_max < 0.0) { i += 1.0; continue; }
        let tg = raySphereIntersectNearest(ro, rd, planet, BOTTOM_RADIUS);
        var hit_ground = false;
        if (tg > 0.0) { t_max = tg; hit_ground = true; }
        let dt = t_max / 8.0;
        var transmittance = vec3<f32>(1.0);
        var sample_lum = vec3<f32>(0.0);
        var s = 0.0;
        loop {
            if (s >= 8.0) { break; }
            let p = ro + rd * ((s + 0.5) * dt);
            let h = length(p) - BOTTOM_RADIUS;
            let ext = extinction(h);
            let scat = scattering(h);
            let mu = dot(normalize(p), sun_dir);
            let t_sun = sampleTransmittance(length(p), mu);
            let phase = rayleighPhase(mu) + miePhase(mu, MIE_G);
            let sample_s = scat * phase * t_sun * SOLAR_IRRADIANCE * u.sun_dir.w;
            let sample_t = exp(-ext * dt);
            sample_lum += transmittance * sample_s * dt;
            transmittance *= sample_t;
            s += 1.0;
        }
        if (hit_ground) {
            let p = ro + rd * t_max;
            let n = normalize(p);
            let mu = dot(n, sun_dir);
            let t_sun = sampleTransmittance(BOTTOM_RADIUS, max(mu, 0.0));
            sample_lum += transmittance * GROUND_ALBEDO * (1.0 / PI) * max(mu, 0.0) * t_sun * SOLAR_IRRADIANCE * u.sun_dir.w;
        }
        lum += sample_lum;
        i += 1.0;
    }
    lum /= sample_count;
    // Isotropic MS factor (Hillaire).
    let h = r - BOTTOM_RADIUS;
    let sigma_s = scattering(h);
    let sigma_t = extinction(h);
    let fms = sigma_s / max(sigma_t, vec3<f32>(1e-6));
    let ms = lum * fms / (1.0 - fms * 0.9);
    return vec4<f32>(max(ms, vec3<f32>(0.0)), 1.0);
}

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let n000 = hash21(i.xy + i.z * 17.0);
    let n100 = hash21(i.xy + vec2<f32>(1.0, 0.0) + i.z * 17.0);
    let n010 = hash21(i.xy + vec2<f32>(0.0, 1.0) + i.z * 17.0);
    let n110 = hash21(i.xy + vec2<f32>(1.0, 1.0) + i.z * 17.0);
    let n001 = hash21(i.xy + (i.z + 1.0) * 17.0);
    let n101 = hash21(i.xy + vec2<f32>(1.0, 0.0) + (i.z + 1.0) * 17.0);
    let n011 = hash21(i.xy + vec2<f32>(0.0, 1.0) + (i.z + 1.0) * 17.0);
    let n111 = hash21(i.xy + vec2<f32>(1.0, 1.0) + (i.z + 1.0) * 17.0);
    let nx00 = mix(n000, n100, u.x);
    let nx10 = mix(n010, n110, u.x);
    let nx01 = mix(n001, n101, u.x);
    let nx11 = mix(n011, n111, u.x);
    let nxy0 = mix(nx00, nx10, u.y);
    let nxy1 = mix(nx01, nx11, u.y);
    return mix(nxy0, nxy1, u.z);
}

fn fbm(p: vec3<f32>) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var x = p;
    for (var i = 0; i < 5; i++) {
        v += a * noise3(x);
        x = x * 2.02 + 17.0;
        a *= 0.5;
    }
    return v;
}

fn windOffset() -> vec3<f32> {
    let dir = normalize(vec3<f32>(u.clouds.y, 0.0, u.clouds.z) + vec3<f32>(1e-4, 0.0, 0.0));
    return dir * (u.cam_pos.w * u.clouds.w);
}

fn densityCumulus(pos_km: vec3<f32>) -> f32 {
    let cov = u.weather.x;
    if (cov < 0.01) { return 0.0; }
    let h = length(pos_km) - BOTTOM_RADIUS;
    let hm = saturate(1.0 - abs(h - 2.4) / 1.4);
    if (hm <= 0.0) { return 0.0; }
    let n = fbm(pos_km * 0.07 + windOffset() * 0.15);
    return saturate(n - (1.0 - cov)) * saturate(n - (1.0 - cov)) * hm * 2.8;
}

fn densityStrata(pos_km: vec3<f32>) -> f32 {
    let cov = u.clouds.x;
    if (cov < 0.01) { return 0.0; }
    let h = length(pos_km) - BOTTOM_RADIUS;
    let hm = saturate(1.0 - abs(h - 7.5) / 1.8);
    if (hm <= 0.0) { return 0.0; }
    let n = fbm(pos_km * 0.03 + windOffset() * 0.35);
    return saturate(n - (1.0 - cov * 0.85)) * hm * 1.0;
}

fn cloudDensity(pos_km: vec3<f32>) -> f32 {
    return densityCumulus(pos_km) + densityStrata(pos_km);
}

fn skyViewDirFromUv(uv: vec2<f32>) -> vec3<f32> {
    // Non-linear zenith mapping (Hillaire sky-view).
    let azimuth = (uv.x - 0.5) * 2.0 * PI;
    let v = uvToUnit(uv.y, 108.0);
    let cos_horizon = 0.0; // camera near ground
    let beta = v * v;
    let zenith = mix(-0.15, 1.0, beta); // slight below horizon for AP
    let cos_z = zenith;
    let sin_z = SafeSqrt(1.0 - cos_z * cos_z);
    return normalize(vec3<f32>(cos(azimuth) * sin_z, cos_z, sin(azimuth) * sin_z));
}

fn integrateSky(ro: vec3<f32>, rd: vec3<f32>, sun_dir: vec3<f32>) -> vec3<f32> {
    let planet = vec3<f32>(0.0);
    var t_max = raySphereIntersectNearest(ro, rd, planet, TOP_RADIUS);
    if (t_max < 0.0) { return vec3<f32>(0.0); }
    let tg = raySphereIntersectNearest(ro, rd, planet, BOTTOM_RADIUS);
    if (tg > 0.0) { t_max = min(t_max, tg); }

    let steps = 32.0;
    let dt = t_max / steps;
    var transmittance = vec3<f32>(1.0);
    var lum = vec3<f32>(0.0);
    let moon_dir = normalize(u.moon_dir.xyz);

    var i = 0.0;
    loop {
        if (i >= steps) { break; }
        let t = (i + 0.5) * dt;
        let p = ro + rd * t;
        let r = length(p);
        let h = r - BOTTOM_RADIUS;
        let up = p / r;
        let mu_s = dot(up, sun_dir);
        let ext = extinction(h);
        let scat_r = RAYLEIGH_SCATTERING * densityRayleigh(h);
        let scat_m = MIE_SCATTERING * densityMie(h);
        let cos_theta = dot(rd, sun_dir);
        let phase_r = rayleighPhase(cos_theta);
        let phase_m = miePhase(cos_theta, MIE_G);
        let t_sun = sampleTransmittance(r, mu_s);
        let ms = sampleMultiscatter(r, mu_s);
        var sample_s = (scat_r * phase_r + scat_m * phase_m) * t_sun * SOLAR_IRRADIANCE * u.sun_dir.w;
        sample_s += (scat_r + scat_m) * ms;

        // Moon contribution (secondary light).
        let cos_m = dot(rd, moon_dir);
        let mu_m = dot(up, moon_dir);
        let t_moon = sampleTransmittance(r, mu_m);
        sample_s += (scat_r * rayleighPhase(cos_m) + scat_m * miePhase(cos_m, MIE_G))
            * t_moon * u.moon_dir.w * vec3<f32>(0.6, 0.7, 1.0);

        // Dual-layer clouds kept light in sky-view; full trace+TAA lives in clouds_ext.
        let cd = cloudDensity(p);
        if (cd > 0.0) {
            let cloud_sigma = cd * 0.55;
            let light = t_sun * SOLAR_IRRADIANCE * u.sun_dir.w * (0.35 + 0.65 * phase_m);
            let ambient = ms * 0.5 + vec3<f32>(0.02, 0.03, 0.05) * u.moon_dir.w;
            sample_s += (light + ambient) * cloud_sigma;
            transmittance *= exp(-vec3<f32>(cloud_sigma) * dt);
        }

        let sample_t = exp(-ext * dt);
        lum += transmittance * sample_s * dt;
        transmittance *= sample_t;
        if (max(transmittance.x, max(transmittance.y, transmittance.z)) < 0.01) { break; }
        i += 1.0;
    }

    // Sun / moon disks.
    let sun_dot = saturate(dot(rd, sun_dir));
    let sun_disk = pow(sun_dot, 5000.0) * 40.0 * transmittance * SOLAR_IRRADIANCE * u.sun_dir.w;
    lum += sun_disk;
    let moon_dot = saturate(dot(rd, moon_dir));
    let phase = mix(0.15, 1.0, abs(u.time_params.z * 2.0 - 1.0));
    lum += pow(moon_dot, 8000.0) * 8.0 * phase * transmittance * u.moon_dir.w * vec3<f32>(0.7, 0.75, 0.9);

    // Stars (night).
    let star_i = u.time_params.y;
    if (star_i > 0.01 && rd.y > 0.05) {
        let sp = rd * 400.0;
        let cell = floor(sp);
        let h = hash21(cell.xy + cell.z * 13.0);
        if (h > 0.997) {
            let local = fract(sp) - 0.5;
            let d = length(local);
            let twinkle = 0.6 + 0.4 * hash21(cell.yz + u.time_params.x);
            lum += vec3<f32>(star_i * twinkle * saturate(1.0 - d * 40.0)) * transmittance;
        }
    }

    // Artistic fog boost for weather.
    let fog = u.weather.y;
    if (fog > 0.0) {
        let fog_amount = saturate(1.0 - exp(-fog * t_max * 0.02));
        lum = mix(lum, lum * vec3<f32>(0.7, 0.75, 0.85) + vec3<f32>(0.15, 0.18, 0.22) * fog, fog_amount * 0.5);
    }

    return lum;
}

@fragment
fn fs_skyview(in: VsOut) -> @location(0) vec4<f32> {
    let rd = skyViewDirFromUv(in.uv);
    let cam_h = max(u.cam_pos.y, 0.001);
    let ro = vec3<f32>(0.0, BOTTOM_RADIUS + cam_h, 0.0);
    let sun_dir = normalize(u.sun_dir.xyz);
    let lum = integrateSky(ro, rd, sun_dir);
    return vec4<f32>(lum, 1.0);
}
