// Deferred lighting + IBL + 3D froxel lights + depth reconstruct + octahedral normals.
struct GpuLight {
    pos_type: vec4<f32>,
    color: vec4<f32>,
    dir_range: vec4<f32>,
    cone: vec4<f32>,
}

struct Frame {
    inv_view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
    camera_pos: vec4<f32>,
    ambient: vec4<f32>,
    counts: vec4<f32>,
    ibl_params: vec4<f32>,
    shadow_light_ids: vec4<f32>,
    point_shadow_slots: vec4<f32>,
    point_shadow_slots_hi: vec4<f32>,
    spot_shadow_slots: vec4<f32>,
    sh: array<vec4<f32>, 9>,
    lights: array<GpuLight, 32>,
    shadow_vp: array<mat4x4<f32>, 4>,
    spot_shadow_vp: array<mat4x4<f32>, 4>,
    cascade_splits: vec4<f32>,
    cascade_radii: vec4<f32>,
    shadow_params: vec4<f32>,
    point_shadow_params: vec4<f32>,
    cascade_z_ranges: vec4<f32>,
    shadow_fade: vec4<f32>,
}

@group(0) @binding(0) var<uniform> frame: Frame;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var albedo_ao_tex: texture_2d<f32>;
@group(0) @binding(3) var normal_oct_tex: texture_2d<f32>;
@group(0) @binding(4) var material_tex: texture_2d<f32>;
@group(0) @binding(5) var depth_tex: texture_depth_2d;
@group(0) @binding(6) var env_cube: texture_cube<f32>;
@group(0) @binding(7) var env_samp: sampler;
@group(0) @binding(8) var dfg_tex: texture_2d<f32>;
@group(0) @binding(9) var dfg_samp: sampler;
@group(0) @binding(10) var shadow_maps: texture_depth_2d_array;
@group(0) @binding(11) var shadow_samp: sampler_comparison;
@group(0) @binding(12) var shadow_depth_samp: sampler;
@group(0) @binding(13) var point_shadow_cubes: texture_depth_cube_array;
@group(0) @binding(14) var<storage, read> tile_masks: array<u32>;
@group(0) @binding(15) var emissive_tex: texture_2d<f32>;
@group(0) @binding(16) var spot_shadow_maps: texture_depth_2d_array;

const PI: f32 = 3.14159265;
const SHADOW_MAP_SIZE: f32 = 1024.0;

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

fn decodeOct(e_in: vec2<f32>) -> vec3<f32> {
    let e = e_in * 2.0 - 1.0;
    var n = vec3<f32>(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    let t = max(-n.z, 0.0);
    n.x += select(t, -t, n.x >= 0.0);
    n.y += select(t, -t, n.y >= 0.0);
    return normalize(n);
}

fn distributionGGX(n_dot_h: f32, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

/// Smith GGX correlated (Dagor BRDF.hlsl role) — replaces Schlick-Smith approx.
fn geometrySmithCorrelated(n_dot_v: f32, n_dot_l: f32, roughness: f32) -> f32 {
    let a2 = roughness * roughness * roughness * roughness;
    let gv = n_dot_l * sqrt(n_dot_v * n_dot_v * (1.0 - a2) + a2);
    let gl = n_dot_v * sqrt(n_dot_l * n_dot_l * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 0.0001);
}

fn fresnelSchlick(cos_theta: f32, f0: vec3<f32>) -> vec3<f32> {
    return f0 + (vec3<f32>(1.0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn fresnelSchlickRoughness(cos_theta: f32, f0: vec3<f32>, roughness: f32) -> vec3<f32> {
    return f0 + (max(vec3<f32>(1.0 - roughness), f0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

/// Disney/Burley diffuse (Dagor fixed Burley role).
fn diffuseBurley(albedo: vec3<f32>, roughness: f32, n_dot_v: f32, n_dot_l: f32, l_dot_h: f32) -> vec3<f32> {
    let fd90 = 0.5 + 2.0 * l_dot_h * l_dot_h * roughness;
    let light_scatter = 1.0 + (fd90 - 1.0) * pow(1.0 - n_dot_l, 5.0);
    let view_scatter = 1.0 + (fd90 - 1.0) * pow(1.0 - n_dot_v, 5.0);
    return albedo * ((1.0 / PI) * light_scatter * view_scatter);
}

/// Specular occlusion from AO + roughness (Dagor computeSpecOcclusion role).
fn specularOcclusion(ao: f32, n_dot_v: f32, roughness: f32) -> f32 {
    return clamp(pow(n_dot_v + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao, 0.0, 1.0);
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

fn reconstructWorldPos(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let world = ndc * frame.inv_view_proj;
    return world.xyz / max(world.w, 1e-5);
}

fn depthSlice(view_z: f32) -> u32 {
    let near = frame.ibl_params.z;
    let far = frame.ibl_params.w;
    let tiles_z = u32(frame.counts.w);
    let z = clamp(view_z, near, far);
    let t = log(z / near) / log(far / near);
    return min(u32(floor(clamp(t, 0.0, 0.9999) * f32(tiles_z))), tiles_z - 1u);
}

fn interleavedGradientNoise(uv: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(uv, vec2<f32>(0.06711056, 0.00583715))));
}

fn selectCascadeBlend(view_z: f32, uv: vec2<f32>) -> vec3<f32> {
    let dither = (interleavedGradientNoise(uv * 1024.0) - 0.5) * frame.shadow_fade.z;
    let z = view_z + dither;
    let s = frame.cascade_splits;
    var c0 = 3;
    var split_near = s.z;
    var split_far = s.w;
    if (z < s.x) {
        c0 = 0;
        split_near = frame.ibl_params.z;
        split_far = s.x;
    } else if (z < s.y) {
        c0 = 1;
        split_near = s.x;
        split_far = s.y;
    } else if (z < s.z) {
        c0 = 2;
        split_near = s.y;
        split_far = s.z;
    }
    let thickness = max(split_far - split_near, 0.001);
    let blend_w = thickness * 0.15;
    let blend = smoothstep(split_far - blend_w, split_far, z);
    let c1 = min(c0 + 1, 3);
    return vec3<f32>(f32(c0), f32(c1), select(0.0, blend, c0 < 3));
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

fn cascadeRadius(cascade: i32) -> f32 {
    if (cascade <= 0) { return frame.cascade_radii.x; }
    if (cascade == 1) { return frame.cascade_radii.y; }
    if (cascade == 2) { return frame.cascade_radii.z; }
    return frame.cascade_radii.w;
}

fn cascadeZRange(cascade: i32) -> f32 {
    if (cascade <= 0) { return max(frame.cascade_z_ranges.x, 0.001); }
    if (cascade == 1) { return max(frame.cascade_z_ranges.y, 0.001); }
    if (cascade == 2) { return max(frame.cascade_z_ranges.z, 0.001); }
    return max(frame.cascade_z_ranges.w, 0.001);
}

fn sampleShadowPCSS(world_pos: vec3<f32>, n: vec3<f32>, cascade: i32) -> f32 {
    let ud = shadowUvDepth(world_pos, n, cascade);
    let uv = ud.xy;
    let recv_depth = ud.z;
    let in_bounds = ud.w > 0.5;
    let texel = 1.0 / SHADOW_MAP_SIZE;
    let radius = max(cascadeRadius(cascade), 0.001);
    let light_size = max(frame.shadow_params.z, 0.001);
    let world_to_uv = 1.0 / (2.0 * radius);
    let search_radius = clamp(light_size * world_to_uv * 0.75, 2.0 * texel, 12.0 * texel);
    // Linearize with actual cascade ortho depth extent (not radius*5 heuristic).
    let z_extent = cascadeZRange(cascade);

    var blocker_sum = 0.0;
    var blocker_count = 0.0;
    for (var i = 0; i < 16; i++) {
        let sample_uv = uv + POISSON[i] * search_radius;
        let blocker_depth = textureSampleLevel(shadow_maps, shadow_depth_samp, sample_uv, cascade, 0);
        let is_blocker = blocker_depth < recv_depth;
        blocker_sum += select(0.0, blocker_depth, is_blocker);
        blocker_count += select(0.0, 1.0, is_blocker);
    }

    let avg_blocker = blocker_sum / max(blocker_count, 1.0);
    let blocker_world = max(recv_depth - avg_blocker, 0.0) * z_extent;
    let avg_blocker_world = max(avg_blocker * z_extent, 0.001);
    let penumbra_world = blocker_world * light_size / avg_blocker_world;
    let filter_radius = clamp(penumbra_world * world_to_uv, 1.5 * texel, 10.0 * texel);
    let use_search = blocker_count > 0.5;

    var sum = 0.0;
    for (var i = 0; i < 16; i++) {
        let offset = POISSON[i] * select(1.5 * texel, filter_radius, use_search);
        sum += textureSampleCompareLevel(shadow_maps, shadow_samp, uv + offset, cascade, recv_depth);
    }
    return select(1.0, sum / 16.0, in_bounds);
}

fn directionalShadow(world_pos: vec3<f32>, n: vec3<f32>, uv: vec2<f32>) -> f32 {
    let view_z = (vec4<f32>(world_pos, 1.0) * frame.view).z;
    let sel = selectCascadeBlend(view_z, uv);
    let c0 = i32(sel.x);
    let c1 = i32(sel.y);
    let blend = sel.z;
    let s0 = sampleShadowPCSS(world_pos, n, c0);
    let s1 = sampleShadowPCSS(world_pos, n, c1);
    var shadow = mix(s0, s1, blend);
    // Last-cascade distance fade (Dagor csm_shadow_fade_out).
    let fade = 1.0 - smoothstep(frame.shadow_fade.x, frame.shadow_fade.y, view_z);
    shadow = mix(1.0, shadow, fade);
    return select(1.0, shadow, frame.shadow_params.w >= 0.5);
}

fn contactShadow(uv: vec2<f32>, depth: f32, world_pos: vec3<f32>, light_dir: vec3<f32>) -> f32 {
    let contact_len = frame.point_shadow_params.w;
    if (contact_len < 0.001 || depth >= 0.9999) { return 1.0; }
    _ = world_pos;
    let dims = vec2<f32>(textureDimensions(depth_tex));
    let step_uv = (normalize(light_dir).xy * vec2<f32>(1.0, -1.0)) * (contact_len * 0.012);
    let noise = interleavedGradientNoise(uv * dims);
    var occ = 1.0;
    var t = noise * 0.12;
    // Fixed iteration count — no early break (FXC cannot unroll gradient loops with exits).
    for (var i = 0; i < 20; i++) {
        t += 1.0 / 20.0;
        let sample_uv = uv + step_uv * t;
        let inb = sample_uv.x >= 0.0 && sample_uv.x <= 1.0 && sample_uv.y >= 0.0 && sample_uv.y <= 1.0;
        let sample_depth = textureSampleLevel(depth_tex, shadow_depth_samp, sample_uv, 0);
        let thickness = mix(0.0004, 0.0035, t);
        let hit = inb && (sample_depth + thickness < depth);
        occ = select(occ, 0.0, hit);
    }
    return mix(1.0, occ, 0.9);
}

fn spotShadowSlotForLight(light_index: i32) -> i32 {
    if (light_index < 0) { return -1; }
    if (i32(frame.spot_shadow_slots.x) == light_index) { return 0; }
    if (i32(frame.spot_shadow_slots.y) == light_index) { return 1; }
    if (i32(frame.spot_shadow_slots.z) == light_index) { return 2; }
    if (i32(frame.spot_shadow_slots.w) == light_index) { return 3; }
    return -1;
}

fn spotLightShadow(world_pos: vec3<f32>, n: vec3<f32>, light_index: i32) -> f32 {
    let slot = spotShadowSlotForLight(light_index);
    if (slot < 0) { return 1.0; }
    let biased = world_pos + n * frame.shadow_params.y;
    let clip = vec4<f32>(biased, 1.0) * frame.spot_shadow_vp[slot];
    let ndc = clip.xyz / max(clip.w, 0.0001);
    let uv = ndc.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    let recv = clamp(ndc.z - frame.shadow_params.x * 2.0, 0.0, 1.0);
    let in_bounds = (uv.x > 0.001) && (uv.x < 0.999) && (uv.y > 0.001) && (uv.y < 0.999) && (ndc.z > 0.0) && (ndc.z < 1.0);
    if (!in_bounds) { return 1.0; }
    let texel = 1.0 / 512.0;
    let soft = max(frame.point_shadow_params.y, 0.001);
    let search_r = clamp(soft * 4.0 * texel, 2.0 * texel, 10.0 * texel);

    var blocker_sum = 0.0;
    var blocker_count = 0.0;
    for (var i = 0; i < 16; i++) {
        let sample_uv = uv + POISSON[i] * search_r;
        let bd = textureSampleLevel(spot_shadow_maps, shadow_depth_samp, sample_uv, slot, 0);
        let is_blocker = bd < recv;
        blocker_sum += select(0.0, bd, is_blocker);
        blocker_count += select(0.0, 1.0, is_blocker);
    }
    let avg_blocker = blocker_sum / max(blocker_count, 1.0);
    let penumbra = clamp((recv - avg_blocker) * soft / max(avg_blocker, 1e-4), 0.0, 1.0);
    let filter_r = mix(1.5 * texel, 8.0 * texel, penumbra);
    let use_search = blocker_count > 0.5;

    var sum = 0.0;
    for (var i = 0; i < 16; i++) {
        let offset = POISSON[i] * select(1.5 * texel, filter_r, use_search);
        sum += textureSampleCompareLevel(spot_shadow_maps, shadow_samp, uv + offset, slot, recv);
    }
    return sum / 16.0;
}

fn pointShadowSlotForLight(light_index: i32) -> i32 {
    if (light_index < 0) { return -1; }
    if (i32(frame.point_shadow_slots.x) == light_index) { return 0; }
    if (i32(frame.point_shadow_slots.y) == light_index) { return 1; }
    if (i32(frame.point_shadow_slots.z) == light_index) { return 2; }
    if (i32(frame.point_shadow_slots.w) == light_index) { return 3; }
    if (i32(frame.point_shadow_slots_hi.x) == light_index) { return 4; }
    if (i32(frame.point_shadow_slots_hi.y) == light_index) { return 5; }
    if (i32(frame.point_shadow_slots_hi.z) == light_index) { return 6; }
    if (i32(frame.point_shadow_slots_hi.w) == light_index) { return 7; }
    return -1;
}

fn pointLightShadow(world_pos: vec3<f32>, n: vec3<f32>, light_index: i32) -> f32 {
    let slot = pointShadowSlotForLight(light_index);
    if (slot < 0) { return 1.0; }
    let light = frame.lights[light_index];
    let light_pos = light.pos_type.xyz;
    let range = max(light.dir_range.w, 0.001);
    let bias = frame.point_shadow_params.x;
    let soft = max(frame.point_shadow_params.y, 0.001);

    let to_frag = world_pos + n * frame.shadow_params.y - light_pos;
    let dist = length(to_frag);
    let dir = to_frag / max(dist, 0.0001);
    let recv = clamp(dist / range - bias, 0.0, 1.0);

    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), abs(dir.y) < 0.99);
    let t = normalize(cross(up, dir));
    let b = cross(dir, t);

    let search_angle = soft * 0.035;
    var blocker_sum = 0.0;
    var blocker_count = 0.0;
    for (var i = 0; i < 16; i++) {
        let offset = (t * POISSON[i].x + b * POISSON[i].y) * search_angle;
        let sample_dir = normalize(dir + offset);
        let blocker_depth = textureSampleLevel(point_shadow_cubes, shadow_depth_samp, sample_dir, slot, 0);
        let is_blocker = blocker_depth < recv;
        blocker_sum += select(0.0, blocker_depth, is_blocker);
        blocker_count += select(0.0, 1.0, is_blocker);
    }
    let avg_blocker = blocker_sum / max(blocker_count, 1.0);
    let penumbra = clamp((recv - avg_blocker) * soft / max(avg_blocker, 1e-4), 0.0, 1.0);
    let filter_angle = mix(0.008, 0.04, penumbra) * soft;
    let use_search = blocker_count > 0.5;

    var sum = 0.0;
    for (var i = 0; i < 16; i++) {
        let ang = select(0.012 * soft, filter_angle, use_search);
        let offset = (t * POISSON[i].x + b * POISSON[i].y) * ang;
        let sample_dir = normalize(dir + offset);
        sum += textureSampleCompareLevel(point_shadow_cubes, shadow_samp, sample_dir, slot, recv);
    }
    return select(1.0, sum / 16.0, frame.point_shadow_params.z >= 0.5);
}

fn evaluateLight(
    light: GpuLight,
    world_pos: vec3<f32>,
    n: vec3<f32>,
    v: vec3<f32>,
    albedo: vec3<f32>,
    metallic: f32,
    roughness: f32,
    ao: f32,
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
    let n_dot_v = max(dot(n, v), 0.001);
    let n_dot_l = max(dot(n, l), 0.0);
    let n_dot_h = max(dot(n, h), 0.0);
    let l_dot_h = max(dot(l, h), 0.0);

    let f0 = mix(vec3<f32>(0.04), albedo, metallic);
    let d = distributionGGX(n_dot_h, roughness);
    let g = geometrySmithCorrelated(n_dot_v, n_dot_l, roughness);
    let f = fresnelSchlick(max(dot(h, v), 0.0), f0);
    let specular = (d * g * f);
    let kd = (vec3<f32>(1.0) - f) * (1.0 - metallic);
    let diffuse = diffuseBurley(albedo, roughness, n_dot_v, n_dot_l, l_dot_h);
    let spec_ao = specularOcclusion(ao, n_dot_v, roughness);
    let radiance = light.color.rgb * light.color.w * attenuation * shadow;
    return (kd * diffuse + specular * spec_ao) * radiance * n_dot_l;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let dims = vec2<f32>(textureDimensions(depth_tex));
    let pixel = vec2<i32>(in.uv * dims);
    let depth = textureLoad(depth_tex, pixel, 0);

    let albedo_ao = textureSample(albedo_ao_tex, samp, in.uv);
    let normal_oct = textureSample(normal_oct_tex, samp, in.uv);
    let material = textureSample(material_tex, samp, in.uv);

    let albedo = albedo_ao.rgb;
    let ao = albedo_ao.a;
    let is_sky = depth >= 0.9999 || material.b < 0.5;
    let n = decodeOct(normal_oct.xy);
    let roughness = clamp(material.g, 0.04, 1.0);
    let metallic = clamp(material.r, 0.0, 1.0);
    let world_pos = reconstructWorldPos(in.uv, depth);

    let dir_id = i32(frame.shadow_light_ids.x);
    var sun_shadow = directionalShadow(world_pos, n, in.uv);
    if (dir_id >= 0) {
        let sun_dir = normalize(frame.lights[dir_id].pos_type.xyz);
        sun_shadow *= contactShadow(in.uv, depth, world_pos, sun_dir);
    }

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

    let view_pos = vec4<f32>(world_pos, 1.0) * frame.view;
    let tiles_x = u32(frame.counts.y);
    let tiles_y = u32(frame.counts.z);
    let tiles_z = u32(frame.counts.w);
    let tx = min(u32(in.uv.x * f32(tiles_x)), tiles_x - 1u);
    let ty = min(u32(in.uv.y * f32(tiles_y)), tiles_y - 1u);
    let tz = depthSlice(view_pos.z);
    let mask = tile_masks[tz * (tiles_x * tiles_y) + ty * tiles_x + tx];
    let count = i32(frame.counts.x);

    for (var i = 0; i < 32; i++) {
        let bit = 1u << u32(i);
        let lit = (i < count) && ((mask & bit) != 0u);
        if (!lit) { continue; }
        var sh = 1.0;
        sh = select(sh, sun_shadow, i == dir_id);
        sh *= pointLightShadow(world_pos, n, i);
        sh *= spotLightShadow(world_pos, n, i);
        color += evaluateLight(frame.lights[i], world_pos, n, v, albedo, metallic, roughness, ao, sh);
    }

    let ibl_intensity = frame.ibl_params.y;
    let max_mip = frame.ibl_params.x;
    let spec_ao = specularOcclusion(ao, max(n_dot_v, 0.001), roughness);

    let diffuse_ibl = shIrradiance(n) * albedo;
    let r = reflect(-v, n);
    let spec_mip = roughness * max_mip;
    let prefiltered = textureSampleLevel(env_cube, env_samp, r, spec_mip).rgb;
    let f_ibl = fresnelSchlickRoughness(n_dot_v, f0, roughness);
    let dfg = textureSample(dfg_tex, dfg_samp, vec2<f32>(n_dot_v, roughness)).rg;
    let specular_ibl = prefiltered * (f_ibl * dfg.x + dfg.y) * spec_ao;
    let kd_ibl = (vec3<f32>(1.0) - f_ibl) * (1.0 - metallic);

    color += (kd_ibl * diffuse_ibl + specular_ibl) * ao * ibl_intensity;

    let emissive = textureSample(emissive_tex, samp, in.uv).rgb;
    color += emissive;

    return vec4<f32>(select(color, sky, is_sky), 1.0);
}
