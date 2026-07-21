// Jump Flood / chamfer dilate for WorldSDF (daGI2 ping-pong role).
// Reads seed distances, writes min over ±jump neighborhood.

struct Uniforms {
    /// x=res_xz, y=res_y, z=clips, w=jump (voxels)
    dims: vec4<f32>,
    /// x=band, y=pass_index
    params: vec4<f32>,
}

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> sdf_in: array<u32>;
@group(0) @binding(2) var<storage, read_write> sdf_out: array<u32>;

fn voxelIndex(clip: u32, ix: u32, iy: u32, iz: u32) -> u32 {
    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    return ix + iy * rx + iz * rx * ry + clip * rx * ry * rx;
}

fn decode(enc: u32) -> f32 {
    return f32(enc) / 65535.0 * max(u.params.x, 1.0);
}

fn encode(d: f32) -> u32 {
    let t = saturate(d / max(u.params.x, 1.0));
    return u32(t * 65535.0);
}

@compute @workgroup_size(4, 4, 4)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let rx = u32(u.dims.x);
    let ry = u32(u.dims.y);
    let nclips = u32(u.dims.z);
    let jump = i32(max(u.dims.w, 1.0));

    // Flatten: x=ix, y=iy, z = iz + clip*rx
    let ix = gid.x;
    let iy = gid.y;
    let flat_z = gid.z;
    if (ix >= rx || iy >= ry) { return; }
    let clip = flat_z / rx;
    let iz = flat_z % rx;
    if (clip >= nclips) { return; }

    let idx = voxelIndex(clip, ix, iy, iz);
    var best = decode(sdf_in[idx]);

    // 26-neighborhood at jump distance (JFA sample pattern).
    for (var dz = -1; dz <= 1; dz++) {
        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0 && dz == 0) { continue; }
                let fx = i32(ix) + dx * jump;
                let fy = i32(iy) + dy * jump;
                let fz = i32(iz) + dz * jump;
                if (fx < 0 || fy < 0 || fz < 0 || fx >= i32(rx) || fy >= i32(ry) || fz >= i32(rx)) {
                    continue;
                }
                let nidx = voxelIndex(clip, u32(fx), u32(fy), u32(fz));
                let nd = decode(sdf_in[nidx]);
                let step_cost = length(vec3<f32>(f32(dx), f32(dy), f32(dz))) * f32(jump);
                best = min(best, nd + step_cost);
            }
        }
    }
    sdf_out[idx] = encode(best);
}
