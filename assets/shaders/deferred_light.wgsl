// Deferred lighting + IBL + CSM (PCSS) + point cubemap shadows.
struct GpuLight {
    pos_type: vec4<f32>,
    color: vec4<f32>,
    dir_range: vec4<f32>,
    cone: vec4<f32>,
}

struct Frame {
    camera_pos: vec4<f32>,
    ambient: vec4<f32>,
    counts: vec4<f32>,
    ibl_params: vec4<f32>,
    sh: array<vec4<f32>, 9>,
    lights: array<GpuLight, 8>,
    shadow_vp: array<mat4x4<f32>, 4>,
    cascade_splits: vec4<f32>,
    shadow_params: vec4<f32>,
    point_shadow_params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> frame: Frame;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var albedo_ao_tex: texture_2d<f32>;
@group(0) @binding(3) var normal_rough_tex: texture_2d<f32>;
@group(0) @binding(4) var world_pos_metal_tex: texture_2d<f32>;
@group(0) @binding(5) var env_cube: texture_cube<f32>;
@group(0) @binding(6) var env_samp: sampler;
@group(0) @binding(7) var shadow_maps: texture_depth_2d_array;
@group(0) @binding(8) var shadow_samp: sampler_comparison;
@group(0) @binding(9) var shadow_depth_samp: sampler;
@group(0) @binding(10) var point_shadow_cube: texture_depth_cube;

const PI: f32 = 3.14159265;
const SHADOW_MAP_SIZE: f32 = 1024.0;

// Poisson disk (16 taps).
const POISSON: array<vec2<f32>, 16> = array<vec2<f32>, 16>(
    vec2<f32>(-0.94201624, -0.39906216),
    vec2<f32>(0.94558609, -0.76890725),
    vec2<f32>(-0.094184101, -0.92938870),
    vec2<f32>(0.34495938, 0.29387760),
    vec2<f32>(-0.91588581, 0.45771432),
    vec2<f32>(-0.81544232, -0.87912464),
    vec2<f32>(-0.38277543, 0.27676845),
    vec2<f32>(0.97484398, 0.75648379),
    vec2<f32>(0.44323325, -0.97511554),
    vec2<f32>(0.53742981, -0.47373420),
    vec2<f32>(-0.26496911, -0.41893023),
    vec2<f32>(0.79197514, 0.19090188),
    vec2<f32>(-0.24188840, 0.99706507),
    vec2<f32>(-0.81409955, 0.91437590),
    vec2<f32>(0.19984126, 0.78641367),
    vec2<f32>(0.14383161, -0.14100790),
);

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

fn distributionGGX(n_dot_h: f32, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

fn geometrySchlickGGX(n_dot_x: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return n_dot_x / (n_dot_x * (1.0 - k) + k);
}

fn geometrySmith(n_dot_v: f32, n_dot_l: f32, roughness: f32) -> f32 {
    return geometrySchlickGGX(n_dot_v, roughness) * geometrySchlickGGX(n_dot_l, roughness);
}

fn fresnelSchlick(cos_theta: f32, f0: vec3<f32>) -> vec3<f32> {
    return f0 + (vec3<f32>(1.0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn fresnelSchlickRoughness(cos_theta: f32, f0: vec3<f32>, roughness: f32) -> vec3<f32> {
    return f0 + (max(vec3<f32>(1.0 - roughness), f0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn envBRDFApprox(roughness: f32, n_dot_v: f32) -> vec2<f32> {
    let c0 = vec4<f32>(-1.0, -0.0275, -0.572, 0.022);
    let c1 = vec4<f32>(1.0, 0.0425, 1.04, -0.04);
    let r = roughness * c0 + c1;
    let a004 = min(r.x * r.x, exp2(-9.28 * n_dot_v)) * r.x + r.y;
    return vec2<f32>(-1.04, 1.04) * a004 + r.zw;
}

fn shIrradiance(n: vec3<f32>) -> vec3<f32> {
    let x = n.x;
    let y = n.y;
    let z = n.z;
    var r = frame.sh[0].rgb * 0.282095;
    r += frame.sh[1].rgb * (0.488603 * y);
    r += frame.sh[2].rgb * (0.488603 * z);
    r += frame.sh[3].rgb * (0.488603 * x);
    r += frame.sh[4].rgb * (1.092548 * x * y);
    r += frame.sh[5].rgb * (1.092548 * y * z);
    r += frame.sh[6].rgb * (0.315392 * (3.0 * z * z - 1.0));
    r += frame.sh[7].rgb * (1.092548 * x * z);
    r += frame.sh[8].rgb * (0.546274 * (x * x - y * y));
    return max(r, vec3<f32>(0.0));
}

fn selectCascade(cam_dist: f32) -> i32 {
    var c = 3;
    c = select(c, 2, cam_dist < frame.cascade_splits.z);
    c = select(c, 1, cam_dist < frame.cascade_splits.y);
    c = select(c, 0, cam_dist < frame.cascade_splits.x);
    return c;
}

fn shadowUvDepth(world_pos: vec3<f32>, n: vec3<f32>, cascade: i32) -> vec4<f32> {
    let biased_pos = world_pos + n * frame.shadow_params.y;
    let clip = vec4<f32>(biased_pos, 1.0) * frame.shadow_vp[cascade];
    let ndc = clip.xyz / max(clip.w, 0.0001);
    let uv = ndc.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    let depth = clamp(ndc.z - frame.shadow_params.x, 0.0, 1.0);
    let in_bounds = (uv.x >= 0.0) && (uv.x <= 1.0) && (uv.y >= 0.0) && (uv.y <= 1.0) && (ndc.z >= 0.0) && (ndc.z <= 1.0);
    return vec4<f32>(uv, depth, select(0.0, 1.0, in_bounds));
}

// PCSS: blocker search → penumbra → variable-radius PCF.
fn sampleShadowPCSS(world_pos: vec3<f32>, n: vec3<f32>, cascade: i32) -> f32 {
    let ud = shadowUvDepth(world_pos, n, cascade);
    let uv = ud.xy;
    let recv_depth = ud.z;
    let in_bounds = ud.w > 0.5;

    let texel = 1.0 / SHADOW_MAP_SIZE;
    let light_size = max(frame.shadow_params.z, 0.001);
    // Search radius in texels (scaled by light size).
    let search_radius = clamp(light_size * 40.0, 2.0, 12.0) * texel;

    var blocker_sum = 0.0;
    var blocker_count = 0.0;
    for (var i = 0; i < 16; i++) {
        let sample_uv = uv + POISSON[i] * search_radius;
        let blocker_depth = textureSample(shadow_maps, shadow_depth_samp, sample_uv, cascade);
        let is_blocker = blocker_depth < recv_depth;
        blocker_sum += select(0.0, blocker_depth, is_blocker);
        blocker_count += select(0.0, 1.0, is_blocker);
    }

    let avg_blocker = blocker_sum / max(blocker_count, 1.0);
    let penumbra = clamp((recv_depth - avg_blocker) * light_size / max(avg_blocker, 0.0001), 0.0, 1.0);
    // No blockers → fully lit; otherwise filter radius grows with penumbra.
    let filter_radius = mix(1.5, 8.0, penumbra) * texel;
    let use_search = blocker_count > 0.5;

    var sum = 0.0;
    for (var i = 0; i < 16; i++) {
        let offset = POISSON[i] * select(1.5 * texel, filter_radius, use_search);
        sum += textureSampleCompare(shadow_maps, shadow_samp, uv + offset, cascade, recv_depth);
    }
    let shadow = sum / 16.0;
    return select(1.0, shadow, in_bounds);
}

fn directionalShadow(world_pos: vec3<f32>, n: vec3<f32>) -> f32 {
    let cam_dist = length(world_pos - frame.camera_pos.xyz);
    let cascade = selectCascade(cam_dist);
    let shadowed = sampleShadowPCSS(world_pos, n, cascade);
    return select(1.0, shadowed, frame.shadow_params.w >= 0.5);
}

fn pointLightShadow(world_pos: vec3<f32>, n: vec3<f32>) -> f32 {
    let light = frame.lights[1];
    let light_pos = light.pos_type.xyz;
    let range = max(light.dir_range.w, 0.001);
    let bias = frame.point_shadow_params.x;
    let soft = frame.point_shadow_params.y;

    let to_frag = world_pos + n * frame.shadow_params.y - light_pos;
    let dist = length(to_frag);
    let dir = to_frag / max(dist, 0.0001);
    let recv = clamp(dist / range - bias, 0.0, 1.0);

    // Tangent basis for angular PCF offsets.
    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), abs(dir.y) < 0.99);
    let t = normalize(cross(up, dir));
    let b = cross(dir, t);
    let angle = soft * 0.02;

    var sum = 0.0;
    for (var i = 0; i < 16; i++) {
        let offset = (t * POISSON[i].x + b * POISSON[i].y) * angle;
        let sample_dir = normalize(dir + offset);
        sum += textureSampleCompare(point_shadow_cube, shadow_samp, sample_dir, recv);
    }
    let shadow = sum / 16.0;
    return select(1.0, shadow, frame.point_shadow_params.z >= 0.5);
}

fn evaluateLight(
    light: GpuLight,
    world_pos: vec3<f32>,
    n: vec3<f32>,
    v: vec3<f32>,
    albedo: vec3<f32>,
    metallic: f32,
    roughness: f32,
    shadow: f32,
) -> vec3<f32> {
    let kind = i32(light.pos_type.w);
    var l: vec3<f32>;
    var attenuation: f32 = 1.0;

    if (kind == 0) {
        l = normalize(light.pos_type.xyz);
    } else {
        let to_light = light.pos_type.xyz - world_pos;
        let dist = length(to_light);
        let range = max(light.dir_range.w, 0.001);
        // Avoid non-uniform early-out before caller already sampled shadows;
        // zero contribution via attenuation instead.
        let in_range = dist <= range;
        l = to_light / max(dist, 0.0001);
        let dist2 = dist * dist;
        let range2 = range * range;
        attenuation = saturate(1.0 - (dist2 * dist2) / (range2 * range2));
        attenuation = attenuation * attenuation / max(dist2, 0.0001);
        attenuation *= select(0.0, 1.0, in_range);
        if (kind == 2) {
            let spot_dir = normalize(light.dir_range.xyz);
            let cos_theta = dot(-l, spot_dir);
            attenuation *= smoothstep(light.cone.y, light.cone.x, cos_theta);
        }
    }

    let h = normalize(v + l);
    let n_dot_v = max(dot(n, v), 0.0);
    let n_dot_l = max(dot(n, l), 0.0);
    let n_dot_h = max(dot(n, h), 0.0);

    let f0 = mix(vec3<f32>(0.04), albedo, metallic);
    let d = distributionGGX(n_dot_h, roughness);
    let g = geometrySmith(n_dot_v, n_dot_l, roughness);
    let f = fresnelSchlick(max(dot(h, v), 0.0), f0);
    let specular = (d * g * f) / max(4.0 * n_dot_v * n_dot_l, 0.001);
    let kd = (vec3<f32>(1.0) - f) * (1.0 - metallic);
    let radiance = light.color.rgb * light.color.w * attenuation * shadow;
    return (kd * albedo / PI + specular) * radiance * n_dot_l;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let albedo_ao = textureSample(albedo_ao_tex, samp, in.uv);
    let normal_rough = textureSample(normal_rough_tex, samp, in.uv);
    let world_pos_metal = textureSample(world_pos_metal_tex, samp, in.uv);

    let albedo = albedo_ao.rgb;
    let ao = albedo_ao.a;
    let n_raw = normal_rough.xyz;
    let is_sky = length(n_raw) < 0.01;
    let n = normalize(select(vec3<f32>(0.0, 1.0, 0.0), n_raw, !is_sky));
    let roughness = clamp(normal_rough.w, 0.04, 1.0);
    let world_pos = world_pos_metal.xyz;
    let metallic = clamp(world_pos_metal.w, 0.0, 1.0);

    // Shadow samples under uniform control flow.
    let sun_shadow = directionalShadow(world_pos, n);
    let pt_shadow = pointLightShadow(world_pos, n);

    let ndc = vec2<f32>(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    let forward = normalize(-frame.camera_pos.xyz);
    let world_up = vec3<f32>(0.0, 1.0, 0.0);
    let right = normalize(cross(forward, world_up));
    let up = cross(right, forward);
    let sky_dir = normalize(forward + right * ndc.x * 1.2 + up * ndc.y * 0.7);
    let sky = textureSampleLevel(env_cube, env_samp, sky_dir, 0.0).rgb;

    let v = normalize(frame.camera_pos.xyz - world_pos);
    let n_dot_v = max(dot(n, v), 0.0);
    let f0 = mix(vec3<f32>(0.04), albedo, metallic);

    var color = frame.ambient.rgb * albedo * ao;

    let count = i32(frame.counts.x);
    for (var i = 0; i < 8; i++) {
        if (i >= count) { break; }
        let kind = i32(frame.lights[i].pos_type.w);
        var sh = 1.0;
        sh = select(sh, sun_shadow, kind == 0 && i == 0);
        sh = select(sh, pt_shadow, kind == 1 && i == 1);
        color += evaluateLight(frame.lights[i], world_pos, n, v, albedo, metallic, roughness, sh);
    }

    let ibl_intensity = frame.ibl_params.y;
    let max_mip = frame.ibl_params.x;

    let diffuse_ibl = shIrradiance(n) * albedo * (1.0 - metallic);
    let r = reflect(-v, n);
    let spec_mip = roughness * max_mip;
    let prefiltered = textureSampleLevel(env_cube, env_samp, r, spec_mip).rgb;
    let f_ibl = fresnelSchlickRoughness(n_dot_v, f0, roughness);
    let brdf = envBRDFApprox(roughness, n_dot_v);
    let specular_ibl = prefiltered * (f_ibl * brdf.x + brdf.y);
    let kd_ibl = (vec3<f32>(1.0) - f_ibl) * (1.0 - metallic);

    color += (kd_ibl * diffuse_ibl + specular_ibl) * ao * ibl_intensity;

    return vec4<f32>(select(color, sky, is_sky), 1.0);
}
