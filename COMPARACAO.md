# Auditoria Tecnica: TucanoEngine vs DagorEngine

## Streamer (World Streaming)

**Paridade: ~91%** (re-audit 2026-07-20; fase ainda NOK até ≥95%)

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Grid Chebyshev + ActionSphere/ZoneSet | Sphere streaming ActionSphere (loadRad2 / unloadRad2) |
| zjobs multi-job + cancel mid-load | cpujobs + unloadRequested |
| Double-buffer front/back + LOD upgrade | Binary dump load/unload + optima re-eval |
| Hysteresis load/unload + zone keep | loadRad2 / unloadRad2 |
| Frame budget µs + schedule_budget_ms | usecAllowedPerFrame |
| CHMZ dump_root load/save on unload | BinaryDump lifecycle |
| GPU upload budget/frame + backpressure | Delayed tex / resident budget |
| syncLoadAt / preloadAtPos | readScene / sync bindump |
| optima(dist, lod) priority | getBinDumpOptima |

### Componentes ausentes / fracos
- Debug rendering de load / unload zones
- Texture pack delayed loading completo (só hint/backpressure)
- BinaryDump multi-scene holder (Controller+Manager+SceneHolder)
- Dedicated virtual job manager (usa zjobs)

### Plano para ≥95%
1. Debug viz dos raios ActionSphere / load rings
2. Delayed texture-pack path alinhado ao resident budget
3. SceneHolder / multi-bindump tracking por cena

---

## Heightfield

**Paridade: 45%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| f32 array, resolution, world_size, origin | CompressedHeightmap BC5-style block compression |
| Bilinear `sampleWorld()` | Hierarchical height range blocks (quad-tree culling) |
| `minMax()` range query | SIMD block decode (4 alturas em 1 operacao) |
| Serialization: raw F32, R16, HMAP native | Multi-chunk streaming com Oodle / Zstd |
| 160 LOC em `heightfield.zig` | `compressedHeightmap.cpp` + `HeightmapPhysHandler` |

### Componentes ausentes
- Block compression BC5-style (8:1 compressao)
- Hierarchical range blocks (quad-tree de min/max para fast culling)
- SIMD cell decode (`decodeInsideBlock4HeightsRaw`)
- Diamond interpolation (4-triangulo, 5-ponto por cell) -> `getHeightmapCell5Pt`
- Ray tracing contra heightmap (`traceray`, `rayhitNormalized`)
- Triangle generation (`get_faces_from_midpoint_heightmap`)
- Pack / unpack scale-bias (hScale, hMin)
- Oodle / Zstd compression no streaming
- Multi-threaded parallel unpack

### Componentes simplificados
- Tucano: f32 bruto (4 bytes/pixel) vs Dagor: ~1.125 bytes/pixel
- Tucano: bilinear interpolation simples vs Dagor: diamond (4-triangle) interpolation
- Tucano: sem compressao no streaming vs Dagor: Oodle / Zstd + parallel unpack

### Diferencas de performance
- Tucano consome 4x mais memoria por pixel de heightmap
- Tucano decode e scalar. Dagor usa SIMD (4 alturas em 1 operacao)
- Tucano sem hierarchical culling (testa todos os pixels). Dagor usa range blocks para early rejection

### Plano para atingir 100%
1. Portar `CompressedHeightmap` block compression
2. Portar hierarchical range blocks
3. Implementar diamond interpolation (4-triangulo)
4. Implementar SIMD decode
5. Adicionar Oodle / Zstd compression no streaming

---

## Splat Map

**Paridade: 30%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| 4-layer weight map per-vertex `[4]f32` | LandClass detail textures (ate 7 layers) |
| `fillFromSlope()`: steep -> rock, flat -> grass | DetailMap: per-cell pair of DDS textures |
| `paint()` per-layer via brush | Land classes: albedo, normal, reflectance arrays |
| `normalizeAt()` | Mega details: 3 carrays de TEXTUREID |
| 95 LOC em `splat.zig` | `lmeshManager.cpp` detail map section |

### Componentes ausentes
- Detail texture arrays com tiling factors
- Mega detail textures (3 arrays separados por tipo)
- Per-cell texture pair (tex1 DDS + tex2 DDS)
- Land class system com inheritance

### Componentes simplificados
- Tucano: per-vertex float weights (caro em VRAM)
- Dagor: per-cell texture indices (economico, texturas sao shared)

### Diferencas de performance
- Tucano: cada vertice carrega 4 floats de peso = +16 bytes/vertice
- Dagor: cada cell carrega 7 indices de textura = +7 bytes/cell (muito mais barato)

### Plano para atingir 100%
1. Substituir per-vertex weight por per-cell detail texture indices
2. Adicionar mega detail textures (3 arrays)
3. Implementar land class inheritance

---

## Holes

**Paridade: 35%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Density field (0 = solid, 1 = open) | HoleCells uniform grid |
| `stampDisk()` (projecao circular) | Projection holes (2D / TM33) |
| `stampTunnelDensity()` (segmento 3D) | Shape intersection holes (full 3D TM) |
| `isHole()` para mesh cutting | Mesh vertex removal com hole list |
| 90 LOC em `holes.zig` | `lmeshHoles.cpp` |

### Componentes ausentes
- Cell-based hole organization (grid de holeCellsCount x holeCellsCount)
- Transformation matrix per hole (TM33 2D ou TM 3D)
- Shape intersection test (volume-based)

### Plano para atingir 100%
1. Portar `LandMeshHolesManager` cell grid + per-cell hole lists
2. Implementar projection holes (TM33) e shape intersection holes (TM)
3. Unificar `isHole()` com teste de matrix

---

## Terrain Mesh

**Paridade: 30%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Geo-mipmap LOD (step 1 / 2 / 4) | 2-level geometry LOD (LOD_COUNT = 2) |
| `buildMesh()`: vertex grid + normals + splat colors | Packed int16 vertices + decoding matrix |
| Triangle indices skipping hole quads | Per-cell ShaderMesh (LOD0, LOD1, combined, decal, patches) |
| 105 LOC em `terrain_mesh.zig` | `lmeshManager.cpp` + `lmeshRenderer.cpp` |

### Componentes ausentes
- Packed vertex format (int16 -> 50% VRAM savings)
- Vertex shader decoding matrix
- Multiple mesh types per cell (land / decal / combined / patches)
- Optimized scene rendering (bitmask visibility, merged adjacent draws)
- Cell bounding boxes + radii para culling
- PREFETCH_DATA optimization

### Componentes simplificados
- Tucano: vertices float32 (44 bytes / vertice)
- Dagor: vertices int16 packed (8 bytes / vertice no arquivo, decode no VS)

### Diferencas de performance
- Tucano consome ~5x mais VRAM por vertice
- Tucano faz LOD simples (step 1/2/4). Dagor faz 2 LODs pre-definidos com geometria otimizada offline

### Plano para atingir 100%
1. Implementar packed int16 vertex format
2. Implementar vertex shader decoding matrix
3. Adicionar multiple mesh types per cell
4. Portar optimized scene rendering (bitmask visibility + merged draws)
5. Adicionar cell bounding data para culling rapido

---

## Terrain Editing

**Paridade: 25%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Brush (radius, strength, falloff exponent) | Terraform: patches 256x256 com 8-bit alt data |
| `raise()` / `lower()` / `smooth()` / `paint()` | `storeSphereAlt`, `storeQuad` |
| `forEachInBrush` helper | PrimModes: DYN_REPLACE, DYN_ADDITIVE, DYN_MIN, DYN_MAX |
| 83 LOC em `terrain_edit.zig` | `terraformDig`: soil spreading, bomb craters, area plates |
| | `TerraformComponent`: network serialization, generation tracking |

### Componentes ausentes
- Alta resolucao de deformacao (cellsPerMeter = 4, MAX_CELLS = 65536)
- Patch system (256x256 patches com saved heightmap values)
- Quad primitives para deformacao (4 vertices)
- Soil spreading physics (consume soil -> create heap)
- Digging mechanics (`advanceDigging` com rastr_line)
- Bomb crater generation (inner / outer radius com smooth falloff)
- Area plate / cylinder (flatten com smoothing)
- Network serialization (BitStream run-length encoded delta patches)
- Generation tracking (uint32 generation counter)
- Dirty block tracking para GPU upload parcial

### Componentes simplificados
- Tucano: operacoes diretas no heightmap float32
- Dagor: sistema de patches + dirty tracking + recompute hmapRangeBlocks + GPU upload parcial

### Diferencas de performance
- Tucano: toda vez que edita, faz upload do heightmap inteiro
- Dagor: so faz upload dos blocos dirty (32x32 pixels) via `fillHmapRegion()`

### Plano para atingir 100%
1. Portar `Terraform` core: patches 256x256, 8-bit alt, PrimModes
2. Portar `TerraformDig`: soil spreading, digging, bomb craters, area plates
3. Portar `TerraformComponent`: network serialization, generation tracking
4. Integrar com HeightmapHandler para dirty block tracking + GPU upload parcial

---

## Procedural Generation

**Paridade: 60%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| znoise (FastNoiseLite): Perlin, Simplex | dag_noise (internal library) |
| FBM + domain warp opcionais | Perlin noise em `engine/math/perlin.cpp` |
| `ProceduralConfig`: seed, freq, octaves, amplitude | Parametros similares |
| `fillHeightfield()` | Generation integrado com terrain system |
| ~100 LOC em `procedural.zig` | ~200 LOC dag_noise + math/perlin.cpp |

### Componentes ausentes
- Biome-based generation com slope / height rules (Dagor tem via landMesh)
- Nada critico — znoise e equivalente funcional ao dag_noise

### Plano para atingir 100%
- Manter znoise. Adicionar biome-based terrain generation com slope / height rules

---

## Renderer (Pipeline)

**Paridade: 25%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Deferred PBR 1 pass | Deferred renderer multi-pass |
| G-buffer: albedo, normal oct, ORM, depth | G-buffer equivalente |
| WebGPU via zgpu / Dawn | DX11 / DX12 / Vulkan / Metal multi-backend |
| 13 WGSL shaders | .dshl meta-shader + ShaderCompiler2 (51k LOC) |
| 1400 LOC em `renderer.zig` | 50K+ LOC (drv + shaders + gameLibs/render) |

### Componentes ausentes
- DX12 / Vulkan nativo (Dagor: drv3d_DX12 223 arquivos, Vulkan ~150)
- .dshl meta-shader compiler
- Render multithread (command buffer recording paralelo)
- Dynamic resolution scaling
- Upscaling: FSR 2/3, DLSS, XeSS
- SSAO
- SSR
- TAA
- DOF / Motion Blur
- Decals (projective e billboard)
- Volumetric fog / lights
- Water rendering (FFT ocean, water objects)
- GPU readback para CPU access de textura

### Componentes simplificados
- Render graph: Tucano placeholder vs Dagor daFrameGraph (33k LOC com scheduling / barriers / aliasing)
- GPU-driven: Tucano CPU batch vs Dagor compute-scatter + toroidal grid
- Shadow: Tucano 4 cascades + 1 point vs Dagor atlas packing com LRU + adaptive quality + clipmap
- Bloom: Tucano 2-target ping-pong vs Dagor 7-8 mip chain com halation

### Diferencas arquiteturais
- Backend: Tucano usa WebGPU (API portavel). Dagor usa backends nativos (controle total de memoria GPU).
- Shaders: Tucano usa WGSL texto. Dagor usa .dshl compilado offline para binario.
- Resource binding: Tucano usa bind groups explicitos WebGPU. Dagor usa bindless descriptor tables.

### Diferencas de performance
- Dagor tem 5-10x mais passes de render (SSAO / SSR / TAA / DOF / volumetricos / water / decals)
- Dagor tem GPU readback para occlusion / exposure / histogram
- Dagor tem render multithread com command buffer recording paralelo
- Dagor faz resource aliasing via frame graph (40-60% menos VRAM para transientes)

### Plano para atingir 100%
1. Substituir render graph placeholder pelo `daFrameGraph`
2. Portar `drv3d_` abstraction layer para Zig
3. Implementar passes ausentes: SSAO, SSR, TAA, DOF, volumetrics, decals, water
4. Adicionar Dynamic Resolution + upscaling
5. Implementar GPU readback ring-buffer

---

## Frame Graph

**Paridade: 5%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| `RenderGraph` com enum de ResourceId (18) e PassId (9) | `daFrameGraph` com compilador IR + scheduler + barrier inserter |
| Execucao linear de passes | Topological sort + pass merging + resource aliasing |
| `Node` com reads / writes arrays | 8-stage pipeline: NameResolver -> DepCalculator -> IrGraph -> Scheduler -> BarrierScheduler -> ResourceAllocator |
| 30 LOC em `render_graph.zig` | 33K LOC em 50+ arquivos |

### Componentes ausentes
- Compilacao de grafo (topological sort, deteccao de ciclos)
- Pass merging (coloracao de passes DAG)
- Resource alias analysis (reuso de memoria entre recursos transientes)
- Barrier scheduling (Vulkan / DX12 pipeline barriers automaticas)
- Multiplexing (stereo, history, super / sub sampling)
- Incremental recompilation (`markStageDirty`)
- Bindless slot management
- Dynamic resolution integration
- Visual debugger (DOT graph dump)
- Execucao multi-threaded de passes independentes

### Diferencas arquiteturais
- Tucano: vetor estatico de passes executados em ordem linear. Sem analise de dependencias real.
- Dagor: compilador completo com IR intermediario, scheduling topologico, insercao de barreiras, e alocacao de recursos transientes com aliasing.

### Diferencas de performance
- Tucano: cada pass cria recursos sem reuso de memoria (GBuffer / bloom / shadow maps alocados estaticamente)
- Dagor: memory aliasing reduz consumo de VRAM em ~40-60% para recursos transientes
- Dagor: barreiras automaticas evitam stalls desnecessarios de GPU

### Plano para atingir 100%
1. Portar `daFrameGraph` (33k LOC C++) para Zig, arquivo por arquivo
2. Implementar bindless slot manager para o backend WebGPU
3. Adicionar visual debugger (export DOT graph)

---

## Occlusion Culling

**Paridade: 15%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Software HiZ (256x128, 8 mips) | Dual-path: GPU HiZ readback + Intel MOC SW raster |
| Rasteriza AABB via projecao corners | Rasteriza AABB, quads, triangulos |
| Max-of-4 mip build | GPU depth downsample + CPU reprojection |
| Hole detection | Temporal reprojection multi-frame (8 frames historico) |
| 175 LOC em `occlusion.zig` | `occlusionSystem.cpp` + `MaskedOcclusionCulling.cpp` |

### Componentes ausentes
- GPU HiZ readback
- Temporal reprojection (8 frames de historico)
- Masked SW Occlusion (Intel MOC) com SIMD (AVX2 / SSE4.1)
- Multi-view merge (stereo VR)
- Near clip plane configuravel
- Depth combine (SW raster + GPU depth -> unico mip chain)

### Componentes simplificados
- Tucano rasteriza apenas AABBs. Dagor rasteriza quads e triangulos.
- Tucano nao tem SIMD. Dagor tem AVX2 path (4-8x mais rapido).
- Tucano nao tem componente temporal. Dagor tem 8 frames de historico.

### Diferencas de performance
- Tucano: CPU-side linear scan de pixels -> O(N*M) onde N=objetos, M=pixels por bounding box
- Dagor: GPU downsample (quase gratuito) + SIMD SW raster
- Dagor: temporal reprojection evita re-rasterizar objetos estaticos

### Plano para atingir 100%
1. Implementar GPU HiZ readback
2. Portar Intel MOC para Zig com SIMD (usar `@Vector` do Zig)
3. Combinar HiZ readback + SW raster num mip chain unico
4. Adicionar suporte a multi-view (stereo)
5. Implementar temporal reprojection com 8 frames de historico

---

## Shadows

**Paridade: 30%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| 4-cascade CSM (1024px, lambda = 0.7) | Atlas-based dynamic shadows com LRU |
| Texel snapping | Binary-tree atlas allocator (rbp) |
| Pull-back + frustum slice fitting | Adaptive quality scaling (0.85x step) |
| Point shadow cubemap (512px, 6 faces) | Octahedral shadow packing |
| PCSS-ready (radii armazenados) | Static / dynamic split por light |
| 303 LOC em `shadow.zig` | `shadowSystem.cpp` + `clipmapShadow.cpp` + `depthShadows.cpp` |

### Componentes ausentes
- Atlas packing: todas as lights dinamicas compartilham 1 atlas
- LRU eviction quando atlas overflow
- Adaptive quality: downgrade / upgrade baseado em screen occupancy
- Octahedral shadows
- Static / dynamic split
- Approximate ray-traced shadows (`trace_shadow_depth_region`)
- Clipmap shadows (toroidal ring-buffer)
- Per-light frame counters para update frequency

### Componentes simplificados
- Tucano tem SO 1 directional light CSM + 1 point light cubemap. Dagor suporta N lights dinamicas com atlas compartilhado.
- Tucano usa resolucao fixa. Dagor tem qualidade adaptativa.
- Tucano sem clipmap shadows (especifico para open world).

### Diferencas de performance
- Dagor: atlas packing reduz uso de VRAM (1 atlas compartilhado vs N shadow maps individuais)
- Dagor: adaptive quality reduz custo GPU para lights distantes
- Dagor: clipmap shadows mais eficientes que CSM para open-world (update parcial)

### Plano para atingir 100%
1. Implementar atlas-based shadow allocator com binary-tree packing
2. Adicionar LRU eviction e adaptive quality scaling
3. Implementar octahedral shadow packing
4. Implementar clipmap shadows para terrain
5. Adicionar approximate ray-traced shadows para static geometry
6. Static / dynamic split

---

## Bloom

**Paridade: 35%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Half-res ping-pong (2 texturas) | 7-8 mip downsample chain |
| Extract (threshold + soft knee) | `bloom_downsample_hq` + `bloom_downsample_lq` |
| Horizontal blur -> vertical blur | Separable Gaussian 15x15 (7-half kernel) |
| Tonemap composite | Upsample chain com tint per-mip |
| 70 LOC em `bloom.zig` | `bloomCore.cpp` + shaders via frame graph |

### Componentes ausentes
- Multi-mip chain (7-8 niveis vs 2)
- Upsample compositing (composite bloom back up through mips)
- Halation effect (tint colorido nos mips inferiores)
- R11G11B10F texture format
- ESRAM console support

### Componentes simplificados
- Tucano: 1 blur horizontal + 1 blur vertical no half-res
- Dagor: 7 blurs horizontais + 7 blurs verticais + upsampling
- Tucano sem halation

### Diferencas de performance
- Dagor: multi-mip chain produz bloom de qualidade muito superior
- Dagor: halation adiciona realismo cinematografico

### Plano para atingir 100%
1. Expandir para 7-mip downsample chain
2. Implementar separable Gaussian 15x15 por mip
3. Implementar upsample chain com halation tinting
4. Usar R11G11B10F para reduzir VRAM

---

## Exposure / Auto-Exposure

**Paridade: 40%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Log-luminance pyramid (64x64 -> 1x1) | Histogram-based metering (compute shader) |
| Ping-pong 1x1 temporal adaptation | GPU readback ring-buffer para CPU access |
| Params: key, adapt speed, min / max | `GenerateHistogramCenterWeightedFromSourceCS` |
| 60 LOC em `exposure.zig` | `exposureCompute.cpp` + compute shaders |

### Componentes ausentes
- Histogram metering (mais robusto que log-average)
- Non-linear distribution (center-weighted sampling)
- GPU readback para CPU access do exposure value
- Albedo-based luminance option (Dagor: ignora albedo para evitar feedback loop)
- Instant adaptation mode
- `seedExposure()` para transicoes suaves entre cenas

### Plano para atingir 100%
1. Substituir log-average por histogram-based metering
2. Implementar GPU readback ring-buffer para CPU access
3. Adicionar center-weighted non-linear distribution
4. Adicionar albedo-based luminance option

---

## IBL / Sky / Environment

**Paridade: 10%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Cubemap 64x64 HDR procedural | Bruneton atmospheric scattering (GPU) |
| 7 GGX prefiltered mips (importance sampling) | Volumetric clouds (multi-layer) |
| DFG LUT 128x128 | Star field + moon |
| SH L2 (9 coeffs) diffuse irradiance | Fog (single scattering) |
| 308 LOC em `ibl.zig` | `daSkies2/daSkies.cpp` (41 arquivos) |

### Componentes ausentes
- Atmospheric scattering (Rayleigh + Mie)
- Volumetric clouds: multi-layer, density / coverage per layer, wind animation, cloud shadows
- Cloud tracing via compute shader
- Star field com coordenadas celestiais, moon com fases
- Strata clouds (2D overlay)
- Panorama system (pre-baked reflection probes)
- Sky detail levels (0-3)
- Cloud detail levels (0-4)
- CPU transmittance / irradiance queries

### Diferencas arquiteturais
- Tucano: cubemap procedural fixo (clear-sky gradient + sun disk + horizon glow)
- Dagor: simulacao fisica de atmosfera com scattering em tempo real
- Tucano: IBL fixo. Dagor: IBL derivado do scattering em tempo real.

### Diferencas de performance
- Tucano: cubemap pre-computado na CPU (rapido, mas estatico)
- Dagor: scattering GPU em tempo real (dinamico com hora do dia, clima)

### Plano para atingir 100%
1. Portar `daSkies2` inteiro: Bruneton scattering + volumetric clouds + stars + fog
2. Substituir IBL procedural por scattering-based IBL
3. Implementar cloud tracing compute shader
4. Adicionar suporte a weather-driven parameters
5. CPU queries para game logic

---

## Material System

**Paridade: 35%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| ZON-based PBR definition (MaterialDef) | Shader Material Properties (scriptSMat.h) |
| 4 GPU textures: albedo, normal, ORM, emissive | MAXMATTEXNUM textures + VarValues |
| DDS / ASTC / Basis / PNG loading | Bindumps (shader binary dumps) para fast switching |
| Procedural fallback (checkerboard) | ShaderClass binding (material -> compiled shader variant) |
| 356 LOC em `material.zig` | `scriptSMat.h` + `materialGameRes.cpp` |

### Componentes ausentes
- Shader class binding (material atrelado a shader variant compilado)
- Material inheritance / template system
- Shader parameter system (VarValues) com scriptable defaults
- Bindump cache para fast material switching
- Texture substitution / legacy compatibility
- Patchable data para dynamic updates

### Diferencas arquiteturais
- Tucano: layout PBR fixo. Data-driven via ZON.
- Dagor: layout flexivel definido pelo shader script. Material e shader acoplados.

### Plano para atingir 100%
1. Implementar shader variant system
2. Adicionar suporte a material templates / inheritance
3. Suporte a VarValues (parametros de shader definidos no material)
4. Bindump cache para fast material switching

---

## GPU-Driven Rendering

**Paridade: 10%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| CPU-packed indirect draws (512 inst, 2 mesh kinds) | Compute-scatter placement (CELL_TILE x CELL_TILE threads) |
| Batch per mesh kind | Toroidal grid (ring-buffer) ao redor da camera |
| Separate gbuffer + shadow buffers | Multi-LOD (ate 4) baseado em distancia |
| 170 LOC em `gpu_driven.zig` | `gpuObjects.cpp` + `genRender.cpp` (1854 linhas) |

### Componentes ausentes
- Compute shader placement (`gpu_objects_cs`)
- Toroidal grid update (`toroidal_update`)
- CPU readback: per-cell counts + bboxes para visibility culling
- Multi-LOD (ate 4) por tipo de objeto
- Biome masks, slope factor, coast range, bomb-hole masking
- BVH integration para occlusion-aware placement
- Impostor textures para LOD distante
- Rotation palette para instance variation
- Conditional rendering
- Render layers: opaque, decal, transparent, distortion
- Per-instance visibility

### Diferencas de performance
- Tucano: CPU faz tudo (batch, sort, indirect args) -> limitado a ~512 instancias
- Dagor: GPU faz placement + render. Suporta centenas de milhares de instancias.

### Plano para atingir 100%
1. Portar `gpuObjects/` compute-shader placement + toroidal grid
2. Implementar multi-LOD (4 niveis) com impostors
3. Adicionar biome masks, slope factor, coast range
4. Integrar com BVH
5. Implementar per-instance visibility + conditional rendering

---

## Frustum Culling

**Paridade: 55%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Gribb-Hartmann plane extraction | Frustum plane extraction |
| `containsAabb()` com 6 planos | `containsAabb()` com otimizacoes |
| `containsSphere()` | `containsSphere()` |
| 60 LOC em `frustum.zig` | `frustumCulling.cpp` |

### Componentes ausentes
- SIMD plane testing
- Hierarchical culling (Dagor: sky sphere details hierarchy)
- Batched AABB culling
- Occlusion integration no mesmo loop

### Diferencas de performance
- Tucano: 6-planos sequencial
- Dagor: pode usar SIMD para testar 4 planos por vez

### Plano para atingir 100%
1. SIMD-ify plane tests usando `@Vector(4, f32)` do Zig
2. Integrar com occlusion culling no mesmo loop
3. Adicionar hierarchical culling

---

## Mesh / Geometry

**Paridade: 25%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Vertex struct (pos, normal, color, uv) | Packed int16 vertices (x, y, z + cellIndex) |
| `createGpuMesh()` upload direto | Decoded no vertex shader: `worldPos = vert / 32767 * scale + offset` |
| Procedural: cube, plane | LandMesh geometry: dumps binarios |
| 147 LOC em `mesh.zig` | `lmeshManager.cpp` + `lmeshRenderer.cpp` |

### Componentes ausentes
- Packed vertex format (economiza 50% VRAM)
- Decoding matrix no vertex shader
- Cell index embedding (6 bits X, 6 bits Y no vertice)
- ShaderMesh abstraction (aglutina VB + IB + material por cell)
- Combined mesh (LOD alto unificado para distancia)
- Patches geometry
- LOD_COUNT = 2 geometria

### Diferencas arquiteturais
- Tucano: vertices float32, geometria procedural simples
- Dagor: vertices int16 packed + decode matrix

### Plano para atingir 100%
1. Implementar packed int16 vertex format
2. Implementar vertex shader decoding matrix
3. Portar ShaderMesh abstraction
4. Adicionar suporte a LOD geometry (2 niveis)
5. Portar GlobalVertexData (VB / IB combinados)

---

## Terrain Splat Rendering

**Paridade: 40%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| 4 detail layers com weight mask | LandClass detail textures (ate 7 layers) |
| GPU terrain rendering via `terrain_gbuffer.wgsl` | Splatting via `renderLandclasses()` |
| Per-chunk weight mask (up to 64 GpuChunks) | DetailMap: per-cell pair of DDS textures |
| Procedural detail textures (64x64 hashed) | Land classes: albedo, normal, reflectance arrays |
| 180 LOC em `terrain_splat.zig` | `lmeshManager.cpp` splatting section |

### Componentes ausentes
- 7 detail texture indices por cell (Tucano tem 4)
- Tex1 (RGB color) + Tex2 (secondary) pair por cell
- Vertical textures (cliffs / steep terrain)
- Tile texture (large-scale color map)
- Mega details (3 carrays de TEXTUREID)
- Mirroring: 9 estados (3x3 XZ) para wrapping
- Cell state: per-cell texture bindings, posToWorld, detMapTc transforms

### Plano para atingir 100%
1. Expandir para 7 detail layers
2. Adicionar vertical textures para cliffs
3. Implementar tile texture (large-scale map)
4. Adicionar mega details (3 arrays)
5. Implementar mirroring (3x3 estados)

---

## Game Loop

**Paridade: 50%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Fixed-timestep (60Hz) com accumulator | Work cycle com split act / render |
| max_steps anti spiral-of-death | `workCycle.cpp` + `idleCycle.cpp` |
| Tracy zones por fase | `gameSceneRenderer.cpp` |
| 92 LOC em `game_loop.zig` | `workCycle/` (24 arquivos) |

### Componentes ausentes
- Act / Render split explicito
- Game scene lifecycle (load / unload / act / render transition)
- Idle cycle
- Platform-specific main loops
- Joystick / keyboard / mouse initialization no game loop
- Delayed actions system

### Diferencas arquiteturais
- Tucano: loop simples com fixedUpdate + frameUpdate callbacks
- Dagor: work cycle com multiplas fases (init, act, render, idle, shutdown) e transicoes de cena

### Plano para atingir 100%
1. Separar act / render em fases explicitas
2. Implementar game scene lifecycle
3. Adicionar idle cycle para background tasks

---

## Log

**Paridade: 55%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| 6 levels (trace..fatal) | Debug levels: debug, log, warning, error, fatal |
| 8 channels (core, render, scene, assets, audio, physics, net, editor) | Timestamped log com source file / line |
| Format string Zig comptime | `debug()` / `logerr()` / `fatal()` macros |
| Global min_level + SinkFn callback | Multiple sinks: file, debugger output, visual console |
| 98 LOC em `log.zig` | `debug.cpp` + `logimpl.cpp` |

### Componentes ausentes
- File sink com rotacao de arquivo
- Visual console mirror
- Timestamp no formato de data / hora real
- Stack trace no fatal error
- Crash reporting (breakpad / crashpad)
- Memory reporting no fatal

### Plano para atingir 100%
1. Adicionar file sink com rotacao
2. Adicionar timestamp real
3. Integrar com debug console (output mirror)
4. Adicionar stack trace no fatal

---

## Debug Console

**Paridade: 30%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| ImGui overlay (zgui) | `consoleProcessor` (689 LOC) + visual driver |
| Ring buffer 256 linhas | Command processor pipeline com prioridade |
| Basic commands: help, clear, fps, quit, log | Auto-completion + fuzzy matching com ranking |
| Extensible handler callback | History ring buffer com deduplication |
| 220 LOC em `debug_console.zig` | Batch file execution |
| | Console variables registradas com get / set |
| | Pinned commands (F-key shortcuts) |
| | Output listener multiplexing |
| | Prefix-based command routing |

### Componentes ausentes
- Command history com save / load
- Auto-completion system (fuzzy match, ranking, namespace agrupamento)
- Console variables (typed, registered vars)
- Command processor plugin architecture
- Batch file execution
- Pinned / favorite commands
- Output listener multiplexing
- Prefix-based command routing

### Plano para atingir 100%
1. Implementar command history com ring buffer + dedup + save to file
2. Implementar auto-completion com fuzzy matching
3. Adicionar console variables
4. Implementar command processor pipeline com prioridades
5. Adicionar batch file execution
6. Adicionar pinned commands

---

## ECS (scene/world.zig)

**Paridade: 2%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| EntityId = enum(u32) counter | daECS: ~38 arquivos, 10K+ LOC |
| World HashMap(EntityId, void) | EntityId generation + index (reuse-safe) |
| createEntity / destroyEntity / isAlive | Archetypes + component migration |
| 64 LOC em `world.zig` | Templates + patching / reloading |
| | ChildComponent (small-value-optimized 8-byte buffer) |
| | Event queue + immediate dispatch |
| | Entity Systems com topological sort |
| | Queries: RO / RW / RQ / NO components, auto-resolved |
| | Constrained MT mode (parallel ES execution) |
| | Singletons |
| | Replication tracking para networking |

### Componentes ausentes
- Tudo. World atual e apenas um alocador de IDs.
- Components, archetypes, templates, queries, ES, events, networking, serialization, MT mode.

### Plano para atingir 100%
1. Portar `daECS/core/` para Zig: EntityManager, ComponentRegistry, Archetype storage
2. Portar `daECS/net/` para networking (replication, serialization)
3. OU usar zig-ecs adaptando API para matching daECS

---

## Resources / Asset Management

**Paridade: 3%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Ref-counted handle registry | gameResSystem: 2012 LOC + 27 arquivos |
| acquire(path) / release(handle) | .grp package format com header + data |
| path-to-handle mapping | 22+ GameResourceFactory subclasses |
| 90 LOC em `manager.zig` | Lazy loading |
| | RRL (Resource Restriction Lists) para preload |
| | Patching / DLC override |
| | Thread safety (dual CS registry + load) |
| | Range-optimized I/O |

### Componentes ausentes
- Package format (.grp binary)
- Factory system (pluggable per resource class)
- Lazy loading pipeline
- Dependency tracking (transitive closure)
- RRL preload lists
- Patching / DLC resource override
- Thread-safe loading
- File scanning
- Texture pack (.dxp.bin) integration
- Range-optimized I/O

### Plano para atingir 100%
1. Implementar package format
2. Implementar factory system (trait Zig comptime por tipo de resource)
3. Implementar lazy loading
4. Implementar RRL dependency closure
5. Adicionar thread safety
6. Implementar range-optimized I/O

---

## Audio

**Paridade: 5%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| zaudio (miniaudio) declarado como dependencia | soundSystem (29 arquivos, FMOD Studio) |
| **Nao integrado ao codigo da engine** | GPU sound occlusion |
| | Steam Audio integration |
| | 3D audio, HRTF, mixing, events, banks |
| | ECS sound systems (daNetGame / sound/) |
| | Networked sound |

### Plano para atingir 100%
1. Integrar zaudio no game loop
2. Implementar audio sources (point, ambient)
3. Implementar spatial audio
4. Implementar audio occlusion

---

## Physics

**Paridade: 5%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| zphysics (Jolt) declarado como dependencia | physBullet/ + physJolt/ + physCommon/ + fastPhys/ |
| **Nao integrado ao codigo da engine** | Rigid bodies, colliders, character controller |
| | Vehicle physics (vehiclePhys/ - 17 arquivos) |
| | Ragdoll physics |
| | Particle physics |

### Plano para atingir 100%
1. Integrar zphysics no game loop
2. Implementar rigid bodies + colliders
3. Implementar character controller
4. Implementar vehicle physics

---

## Animation

**Paridade: 0%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Nada implementado | animGraph (13 arquivos), animChar2 (6 arquivos) |
| | ozz-animation + ACL compression |
| | IK (FABRIK, foot locking) |
| | Animation state machine |
| | Skeletal mesh skinning (shSkinMesh) |

### Plano para atingir 100%
1. Integrar ozz-animation via FFI
2. Implementar skeletal mesh skinning no shader
3. Implementar animation state machine
4. Implementar IK (FABRIK)

---

## Scripting

**Paridade: 0%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| Nada implementado | daScript (AOT + JIT, custom language) |
| | Quirrel / Squirrel |
| | daScript bindings para engine |
| | Hot-reload de scripts |

### Plano para atingir 100%
1. Embed Lua via FFI (ou portar daScript)
2. Criar bindings automaticos Zig -> Lua via comptime reflection
3. Implementar hot-reload

---

## Editor

**Paridade: 2%**

### Componentes presentes
| Tucano | Dagor |
|--------|-------|
| ImGui debug console (zgui, 220 LOC) | daEditorX: scene editor, 21 plugins, 34 services (75K+ LOC) |
| | AssetViewer: material / texture / FX / animation viewer |
| | EditorCore: viewport, gizmos, outliner, undo (73 arquivos) |
| | PropPanel: 27 arquivos de property panel |
| | Blender + 3ds Max plugins |

### Plano para atingir 100%
1. Portar EditorCore (viewport, gizmos, outliner, selection, commands, undo)
2. Portar PropPanel para property editing
3. Implementar terrain editing no editor
4. Implementar asset browser

---

## Zbasis (Texture Transcoding)

**Paridade: N/A (exclusivo do Tucano)**

### Componentes
- Basis Universal transcoding (BC7, ASTC 4x4, RGBA8) via FFI C
- Encoder: RGBA8 -> UASTC .basis / .ktx2
- `upload()` direto para zgpu texture
- Dagor nao tem suporte nativo a Basis Universal (usa DDS / DDSx)

### Diferenca
- Tucano suporta Basis Universal (formato moderno, melhor compressao que BCx puro)
- Dagor usa DDS / DDSx (formato legado, battle-tested)
- Feature unica do Tucano — sem equivalente na Dagor

---

## Resumo: Scores de Paridade

| # | Sistema | Paridade | LOC Tucano | LOC Dagor | Gap |
|---|---------|----------|------------|-----------|-----|
| 1 | **Streamer** | **65%** | 492 | 815 | 1.7x |
| 2 | **Procedural** | **60%** | 100 | 200+ | 2x |
| 3 | **Log** | **55%** | 98 | 500+ | 5x |
| 4 | **Frustum** | **55%** | 60 | 200+ | 3x |
| 5 | **Game Loop** | **50%** | 92 | 2K+ | 22x |
| 6 | **Heightfield** | **45%** | 160 | 800+ | 5x |
| 7 | **Exposure** | **40%** | 60 | 500+ | 8x |
| 8 | **Terrain Splat** | **40%** | 180 | 3K+ | 17x |
| 9 | **Bloom** | **35%** | 70 | 2K+ | 28x |
| 10 | **Holes** | **35%** | 90 | 300+ | 3x |
| 11 | **Material** | **35%** | 356 | 3K+ | 8x |
| 12 | **Shadows** | **30%** | 303 | 8K+ | 26x |
| 13 | **Splat Map** | **30%** | 95 | 1K+ | 10x |
| 14 | **Terrain Mesh** | **30%** | 105 | 3K+ | 28x |
| 15 | **Debug Console** | **30%** | 220 | 1.5K+ | 7x |
| 16 | **Renderer** | **25%** | 1400 | 50K+ | 40x |
| 17 | **Terrain Edit** | **25%** | 83 | 2K+ | 24x |
| 18 | **Mesh / Geometry** | **25%** | 147 | 5K+ | 34x |
| 19 | **Occlusion** | **15%** | 175 | 3K+ | 17x |
| 20 | **IBL / Sky** | **10%** | 308 | 10K+ | 33x |
| 21 | **GPU-Driven** | **10%** | 170 | 5K+ | 30x |
| 22 | **Frame Graph** | **5%** | 30 | 33K | 1000x |
| 23 | **Audio** | **5%** | 0 | 5K+ | — |
| 24 | **Physics** | **5%** | 0 | 8K+ | — |
| 25 | **Resources** | **3%** | 90 | 3K+ | 33x |
| 26 | **Editor** | **2%** | 220 | 75K+ | 340x |
| 27 | **ECS** | **2%** | 64 | 10K+ | 156x |
| 28 | **Animation** | **0%** | 0 | 5K+ | — |
| 29 | **Scripting** | **0%** | 0 | 10K+ | — |
| 30 | **Zbasis** | **N/A** | 357 | 0 | Unico |

**Media ponderada: ~18%**

---

## Top 10 Regressoes Criticas

| # | Regressao | Impacto |
|---|-----------|---------|
| 1 | Frame Graph placeholder (sem scheduling / barriers / aliasing) | 40-60% mais VRAM, stalls GPU |
| 2 | ECS vazio (sem componentes / queries / systems) | Incapaz de rodar gameplay |
| 3 | Editor ausente (75K+ LOC faltando) | Sem ferramenta de criacao de conteudo |
| 4 | Occlusion apenas CPU HiZ (sem GPU readback / MOC SIMD / temporal) | 10x mais lento que Dagor |
| 5 | GPU-Driven apenas CPU batch (sem compute-scatter / toroidal grid) | Limitado a 512 instancias |
| 6 | Heightmap f32 raw (sem compressao BC5 8:1 / diamond interpolation / SIMD) | 4x mais memoria, 4x mais lento |
| 7 | IBL procedural fixo (sem Bruneton scattering / volumetric clouds) | Ceu estatico, sem clima dinamico |
| 8 | Shadows apenas 1 CSM + 1 point (sem atlas / adaptive quality / clipmap) | Sem suporte N lights, custo GPU fixo |
| 9 | Resources placeholder (sem packages / factories / lazy loading / RRL) | Sem pipeline de assets |
| 10 | Animation / Scripting inexistentes | Sem personagens animados ou logica scriptada |
