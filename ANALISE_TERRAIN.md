# Terrain vs Terrain: TucanoEngine vs DagorEngine

---

## 1. Height Encoding (CompressedHeightmap)

### Arquitetura geral

**Dagor** (`CompressedHeightmap`):
- Non-owning struct sobre buffer linear externo
- Layout: `[BlockInfo[] | variance_bytes[] | HeightRangeBlock hierarchy]`
- Block: `u16 mn + u16 delta + [N]u8 variance` (4 bytes header + N pixels)
- Decode: `height = mn + (v * delta + 127) / 255`
- **Segundo estagio de compressao**: delta encoding nos bytes de variance + Zstd/Oodle por chunk
- **Hierarquia completa**: quadtree multi-nivel (ate 14 niveis), flat-packed via `sHierGridOffsets[]`
- **Downsample**: re-encode com 2x box filter
- **Parallel chunked loading**: decompressao em threadpool com `IJob`
- **Incremental update**: `updateHierHeightRangeBlocksForPoint/Rect` update so blocos afetados

**Tucano** (`Compressed`):
- Owning struct com `blocks: []Block`, `hier_min: []f32`, `hier_max: []f32`
- Block: `u16 mn + u16 delta + [64]u8 variance` (8x8 fixo, `block_shift=3`)
- Decode identico: `mn + (v*delta + 127)/255`
- **Sem segundo estagio**: variance bytes crus, sem Zstd/Oodle
- **Hierarquia simples**: 1 nivel (2x2 blocos -> hier_min/hier_max)
- **Sem downsample**: nao ha reducao de resolucao
- **Serial**: rebuild single-threaded
- **Incremental update**: `updateDirty()` re-encode blocos no dirty rect + `rebuildHierarchy()`

### Tabela de funcionalidades

| Feature | Dagor | Tucano | Status |
|---------|-------|--------|--------|
| Block compression BC5-style | u16 mn+delta + u8 indices | identico | Igual |
| Block size | Configuravel 4x4..32x32 | Fixo 8x8 | Simplificado |
| 2-stage compression | Zstd/Oodle + delta encode | Nenhum | Ausente |
| Hierarchy levels | Multi-nivel (ate 14) | 1 nivel (2x2 blocks) | Simplificado |
| Downsample | 2x box + re-encode | Ausente | Ausente |
| Parallel loading | threadpool multi-chunk | Serial | Ausente |
| Incremental hierarchy update | Point/Rect selective | Full rebuild dirty region | Simplificado |
| Pixel decode | `mn + (v*delta+127)/255` | `mn + (v*delta+127)/255` | Igual |
| SIMD decode | `decodeInsideBlock4HeightsRaw` (4 corners) | Scalar | Ausente |

### Diferencas arquiteturais

- **Dagor**: non-owning (opera sobre buffer alocado externamente). Ideal para streaming de disco direto para memoria sem copia extra.
- **Tucano**: owning (aloca `blocks`, `hier_min`, `hier_max` no heap). Mais seguro em Zig (lifetime tracking), mas requer copia no stream.

- **Dagor**: hierarquia e um quadtree completo flat-packed com offsets pre-computados. Suporta query de range em O(log N).
- **Tucano**: hierarquia e 1 nivel de 2x2 blocos. Range query usa hier cells quando >= 2x2 blocos, fallback block-level. O(N) no pior caso.

### Diferencas de performance

- **Tucano perde 8-16x de compressao**: sem segundo estagio (Zstd/Oodle), dados ocupam ~1.125 bytes/pixel vs ~0.14 bytes/pixel do Dagor apos compressao final
- **Tucano perde 4x em decode**: sem SIMD, cada decode e 1 pixel vs 4 pixels por chamada no Dagor
- **Tucano perde O(log N) em range query**: hierarquia so tem 1 nivel vs quadtree completo do Dagor

### Plano para atingir 100%

1. **Prioridade Alta**: Implementar segundo estagio de compressao (delta encoding nos bytes variance + Zstd via `std.compress.zstd` do Zig)
2. **Prioridade Media**: Adicionar SIMD decode (`@Vector(4, u8)` -> `@Vector(4, f32)`) para 4 corners simultaneos
3. **Prioridade Media**: Hierarquia multi-nivel flat-packed (portar `sHierGridOffsets` do Dagor)
4. **Prioridade Baixa**: Downsample + parallel chunked loading

**Paridade atual: 70%** (era 45%)

---

## 2. Height Queries

### Arquitetura geral

**Dagor** (`HeightmapPhysHandler`):
- `getHeight(Point2, &float, Point3*)` - world space 2D altura
- `getHeightBelow(Point3, &float, Point3*)` - altura abaixo de ponto 3D
- `getHeightMax(Point2, Point2, float, &float)` - altura maxima entre 2 pontos
- `getHeightmapCell5Pt()` - diamond 5-point (4 corners + center)
- `getHeightmapCell5PtMinMax()` - 5-point com early-out range check
- `traceray(Point3, Point3, &real, Point3*, bool)` - ray vs terrain
- `traceDownMultiRay(bbox3f, vec4f*, vec4f*, int)` - multi-ray SIMD
- `rayhitNormalized()` / `rayUnderHeightmapNormalized()` - ray tests
- `getMinMaxHtInGrid()` - hierarquia range query O(1)

**Tucano** (`Heightfield`):
- `sampleWorld(wx, wz)` - bilinear interpolation
- `sampleWorldDiamond(wx, wz)` - Dagor-style 5-point diamond filter
- `traceRay(ox,oy,oz,dx,dy,dz,max_t)` - 64-step raymarch + linear refinement
- `rangeMinMax(min_x,min_z,max_x,max_z)` - usa hierarquia compressed quando disponivel
- `minMax()` - full scan (fallback)

### Tabela

| Feature | Dagor | Tucano | Status |
|---------|-------|--------|--------|
| Bilinear sample | Sim | `sampleWorld` | Igual |
| Diamond 5-point | `getHeightmapCell5Pt` | `sampleWorldDiamond` (6-point avg) | Similar |
| Cell 5pt + range cull | `getHeightmapCell5PtMinMax` | Ausente | Ausente |
| Height below 3D point | `getHeightBelow` | Ausente | Ausente |
| Height max between 2 points | `getHeightMax` | Ausente | Ausente |
| Ray trace single | `traceray` | `traceRay` (64-step + linear refine) | Similar |
| Ray trace multi (SIMD) | `traceDownMultiRay` | Ausente | Ausente |
| Ray hit test | `rayhitNormalized` | Ausente | Ausente |
| Range query hierarchy | O(1) via hier multi-nivel | O(N) via 1-level hier | Simplificado |

### Diferencas arquiteturais

- **Tucano** diamond filter usa media ponderada 6-point (centro*2 + vizinhos)/6. **Dagor** usa 4 corners + center com interpolacao de diamante dividido em 4 triangulos.
- **Tucano** traceRay faz 64 steps uniformes com linear refinement. Funcional mas menos preciso que o `traceray` do Dagor que usa `WooRay2d` com 2D traversal otimizado por celula.

### Plano para atingir 100%

1. `getHeightBelow` - queda de objeto ao chao (trivial: `getHeight(pos.x, pos.z) + pos.y` comparison)
2. `getHeightMax` entre 2 pontos (usar compressed hierarchy para acelerar)
3. Ray trace via cell-by-cell traversal (portar logica de `WooRay2d` do Dagor)
4. Multi-ray SIMD para physics queries em lote

**Paridade atual: 60%** (era 40%)

---

## 3. Deformation / Editing (Terraform)

### Arquitetura geral

**Dagor** (`Terraform` + `TerraformDig` + `TerraformComponent`):
- **3 camadas**: raw cell edit -> visual override (flat_hash_map) -> Terraform patch system
- **Patch system**: 256x256 uint8 patches (sparse), `cellsPerMeter=4`, `MAX_CELLS=65536`
- **4 PrimModes**: DYN_REPLACE, DYN_ADDITIVE, DYN_MIN, DYN_MAX
- **Quad primitives**: `QuadData` (4 vertices + delta), `submitQuad`, rasterizado para patches
- **Soil spreading**: `advanceDigging` consome solo + cria heap com `submitQuad`
- **Bomb craters**: `makeBombCraterPart` - inner depression + mid falloff + outer uplift
- **Area tools**: `makeAreaPlate` / `makeAreaCylinder` com edge smoothing + noise
- **Network serialization**: `BitStream` run-length encoded delta patches
- **Generation tracking**: `uint32 generation` para deteccao de mudancas
- **Dirty tracking**: `heightChangesIndex` (flat_hash_set) -> `fillHmapRegion()` upload GPU parcial (32x32 blocos)
- **Observers**: `Renderer` + `Listener` interfaces para notificacao de mudancas

**Tucano** (`terrain_edit.zig`):
- **1 camada**: edicao direta no Heightfield f32
- **5 brushes**: raise, lower, smooth (3x3 average), flatten (target height), hill (gaussian peak)
- **Paint brush** para splat (4 layers)
- **Brush falloff**: `pow(1 - dist/radius, falloff) * strength`
- **Undo/redo**: `EditorSession` com stack max 32, snapshots do dirty rect (height + splat opcional)
- **Incremental compressed rebuild**: `commitEdit()` -> `rebuildCompressedDirty()`

### Tabela

| Feature | Dagor | Tucano | Status |
|---------|-------|--------|--------|
| Raise/lower | `storeSphereAlt` + `setHeightmapHeightUnsafe` | `raise()`/`lower()` | Igual |
| Smooth | via `queueElevationChange` | `smooth()` (3x3 average) | Igual |
| Flatten | `makeAreaPlate` com smoothing | `flatten()` (target lerp) | Simplificado |
| Hill | Ausente (usa raise) | `hill()` (gaussian peak) | Exclusivo Tucano |
| Patch system 256x256 | `Terraform::Patch` uint8 | Ausente (edita f32 direto) | Ausente |
| Quad primitives | `QuadData` + `submitQuad` | Ausente | Ausente |
| Soil spreading | `advanceDigging` + `submitQuad` | Ausente | Ausente |
| Bomb craters | `makeBombCraterPart` | Ausente | Ausente |
| Area tools | `makeAreaPlate`/`makeAreaCylinder` | Ausente | Ausente |
| Undo/redo | Ausente (externo ao Terraform) | `EditorSession` max 32 | Exclusivo Tucano |
| Network serialization | `TerraformComponent` BitStream RLE | Ausente | Ausente |
| Generation tracking | `uint32 generation` | `gpu_generation` no TerrainTile | Similar |
| GPU partial upload | `fillHmapRegion` 32x32 blocks | `rebuildCompressedDirty` (bloco 8x8) | Similar |
| Visual overrides | `visualHeights` flat_hash_map | Ausente | Ausente |

### Diferencas arquiteturais

- **Dagor**: sistema de patches esparsos com uint8 (8-bit precision, alta resolucao). Edicao nao modifica o heightmap diretamente - o Terraform e uma overlay que e composta com o heightmap base no momento do sample.
- **Tucano**: edita o heightmap f32 diretamente. Mais simples, mas perde resolucao de edicao (limitado a resolucao do heightfield).
- **Dagor**: soil physics (digging consome solo, cria heap). Tucano nao tem simulacao de solo.
- **Tucano**: undo/redo integrado (Dagor depende de sistema externo). Vantagem: snapshots precisas com dirty rect.

### Diferencas de performance

- **Tucano perde resolucao de edicao**: limitado a resolucao do heightfield (ex: 33x33 para chunk 64m com 16 res = cells de 2m). Dagor: cellsPerMeter=4 = cells de 0.25m.
- **Tucano ganha em simplicidade**: sem overhead de patch lookup, sem composicao de overlay. Edicao direta = 1 memcpy.
- **Tucano rebuild e mais caro**: re-encode de blocos 8x8 a cada commitEdit vs Dagor que so faz upload de textura para blocos 32x32.

### Plano para atingir 100%

1. **Prioridade Alta**: Adicionar patch system esparso (256x256 uint8) como overlay sobre o heightmap. Portar `storeSphereAlt` com PrimModes.
2. **Prioridade Media**: Bomb crater generation (portar `makeBombCraterPart`)
3. **Prioridade Media**: Area plate/cylinder com edge smoothing + noise
4. **Prioridade Baixa**: Soil spreading + quad primitives
5. **Prioridade Baixa**: Network serialization (BitStream RLE)

**Paridade atual: 50%** (era 25%)

---

## 4. Holes / Caves

### Arquitetura geral

**Dagor** (`LandMeshHolesManager`):
- Cell-based grid: `holeCellsCount x holeCellsCount` cells
- Cada cell: lista de holes com `TMatrix` (TM33 2D ou TM 3D)
- **Projection holes** (2D): teste de intersecao XZ
- **Shape intersection holes** (3D): teste de volume completo

**Tucano** (`HoleField`):
- Density field: `[]f32` (0=solid, 1=open), threshold=0.5
- 3D volumes: `disk`, `capsule`, `box`
- **Spatial cell grid**: 8x8 cells com per-cell lists de volume indices
- `isHole(x,z)` - density threshold test (surface)
- `isHoleWorld(wx,wy,wz)` - 3D volume test via cell grid
- `approximateCheckBBox(min_x,min_z,max_x,max_z)` - fast reject AABB overlap
- `stampDisk()` - hole circular com quadratic falloff + auto-register volume
- `stampTunnelDensity()` - capsule tunnel + auto-register volume
- `bakeGpuMask()` - bake density + volume flag into RGBA8

### Tabela

| Feature | Dagor | Tucano | Status |
|---------|-------|--------|--------|
| Cell grid | `holeCellsCount x holeCellsCount` | 8x8 fixo | Igual |
| Per-cell volume lists | Sim | Sim | Igual |
| Projection holes (2D) | TM33 matrix test | `stampDisk` circle | Similar |
| Shape intersection (3D) | Full TM matrix test | `isHoleWorld` (disk/capsule/box) | Similar |
| Density field | Nao (binario) | Sim (0-1 gradient) | Exclusivo Tucano |
| Capsule tunnels | Nao | `stampTunnelDensity` | Exclusivo Tucano |
| Box volumes | Nao | `box` kind | Exclusivo Tucano |
| Mesh culling | Remove vertices via hole list | Skip quads with any corner hole + center 3D test | Similar |
| GPU mask bake | Nao | `bakeGpuMask` RGBA8 | Exclusivo Tucano |
| Fast reject AABB | Ausente | `approximateCheckBBox` | Exclusivo Tucano |

### Diferencas arquiteturais

- **Tucano** tem 3 tipos de volume (disk/capsule/box) vs Dagor que usa matrix generica. Tucano e mais limitado em formas mas mais performatico (testes geometricos diretos vs matrix multiply).
- **Tucano** tem density field com gradiente (0-1) permitindo bordas suaves. Dagor e binario (hole ou nao).
- **Tucano** bake para GPU como RGBA8 (density em R, volume flag em G). Dagor nao tem equivalente de bake.

### Diferencas de performance

- **Tucano ganha em queries 3D**: cell grid + geometric tests sao mais rapidos que matrix multiply
- **Tucano ganha em mesh culling**: approximateCheckBBox + isHole sao early-outs baratos

### Plano para atingir 100%

- Nenhum gap critico. Tucano ja e superior em features (3D volumes, density gradient, GPU bake).
- Manter implementacao atual.

**Paridade atual: 55%** (era 35%) (Tucano tem features que Dagor nao tem, mas perde no numero de shapes via matrix)

---

## 5. LOD & Mesh Generation

### Arquitetura geral

**Dagor** (`LandMeshManager` + `LandMeshRenderer` + `HeightmapHandler`):
- **Geometria**: 2 LODs pre-computados offline por cell (`LOD_COUNT=2`)
- **Heightmap**: 8 LODs via GPU mip chain (`BASE_HMAP_LOD_COUNT=8`)
- **Combined mesh**: geometria simplificada unificada para distancia extrema
- **Patches**: geometria irregular (nao usada para grid terrain)
- **LOD switch**: `invGeomLodDist` (distancia inversa), `lod1_switch_radius`
- **Culling**: frustum + `HeightmapHeightCulling` (usa hierarquia de altura)
- **Tessellation**: GPU displacement via `maxUpwardDisplacement`/`maxDownwardDisplacement`
- **Packed vertices**: int16 (4 shorts = x,y,z + cellIndex), decode no VS
- **Bitmask visibility**: `VisibilityData` para merged adjacent draws
- **Cell bounding**: `cellBoundings` + `cellBoundingsRadius` pre-computados

**Tucano** (`terrain_mesh.zig`):
- **Geometria**: 3 LODs runtime (geo-mipmap: step 1/2/4)
- **Heightmap**: sem GPU mip-based LOD (usa step para reduzir vertices)
- **Sem combined mesh**: cada chunk e independente
- **LOD switch**: Chebyshev distance thresholds (load_radius/3, 2*load_radius/3)
- **Culling**: frustum no terrain_splat, patchBounds via compressed hierarchy
- **Sem tessellation**: vertices fixos no mesh
- **Vertices**: f32 (44 bytes por vertice)
- **Skirts**: 4 edges com `skirt_depth=2.0` para preencher T-junctions entre LODs
- **Hole culling**: surface density + 3D volume test integrado no mesh builder

### Tabela

| Feature | Dagor | Tucano | Status |
|---------|-------|--------|--------|
| Geometry LODs | 2 (offline) | 3 (geo-mipmap runtime) | Superior Tucano |
| GPU mip LOD | 8 niveis | Ausente | Ausente |
| Combined mesh | Sim (distancia extrema) | Ausente | Ausente |
| Packed vertices | int16 (50% VRAM) | f32 | Perda 2x VRAM |
| LOD skirts | Nao (usa geometry LOD pre-built) | Sim (4 edges, 2m depth) | Exclusivo Tucano |
| Tessellation | GPU displacement | Ausente | Ausente |
| Bitmask visibility | `VisibilityData` merged draws | Ausente (draw por chunk) | Ausente |
| Cell bounding pre-compute | Sim | `patchBounds` usa compressed | Similar |
| Hole culling in mesh | Via hole list | Via isHole + isHoleWorld | Igual |
| PREFETCH_DATA | Sim | Nao | Ausente |

### Diferencas arquiteturais

- **Tucano** gera geometria em runtime com geo-mipmap. Dagor carrega LOD geometry pre-computada de dump binario.
- **Tucano** mesh builder integra hole culling diretamente (skip de quads). Dagor usa hole lists separados.
- **Tucano** skirts resolvem T-junctions entre LODs diferentes. Dagor nao tem skirts porque geometria LOD e pre-avermelhada.

### Diferencas de performance

- **Tucano perde 2x VRAM** em vertices: f32 (44 bytes) vs int16 packed (8 bytes + decode matrix no VS)
- **Tucano ganha em flexibilidade**: 3 LODs runtime vs 2 pre-computados
- **Tucano perde merged draws**: cada chunk e um draw call separado. Dagor faz merge de draws adjacentes via bitmask.

### Plano para atingir 100%

1. **Prioridade Alta**: Packed int16 vertex format com decode no vertex shader (portar `landCellShortDecodeXZ/Y` do Dagor)
2. **Prioridade Media**: Combined mesh para distancia extrema (merge de chunks distantes)
3. **Prioridade Baixa**: Bitmask visibility + merged draws

**Paridade atual: 48%** (era 30%)

---

## 6. Terrain Splat Rendering

### Arquitetura geral

**Dagor** (`LandMeshRenderer` + `lmeshManager.cpp`):
- **7 detail texture IDs** por cell
- **Tex1 + Tex2** DDS pair por cell (DetailMap grid)
- **Land classes**: albedo, normal, reflectance arrays com tiling factors
- **Mega details**: 3 carrays de TEXTUREID arrays por tipo
- **Vertical textures**: `vertTexId`, `vertNmTexId`, `vertDetTexId` para cliffs
- **Tile texture**: large-scale color/roughness map
- **Mirroring**: 9 estados (3x3 XZ) para wrapping de borda
- **Render types**: RENDER_WITH_SPLATTING, RENDER_CLIPMAP, RENDER_WITH_CLIPMAP, RENDER_DEPTH, RENDER_REFLECTION

**Tucano** (`terrain_splat.zig`):
- **4 detail layers** com weight mask RGBA8 per chunk
- **Procedural detail textures** (128x128 com noise, 4 layers: grass/rock/sand/dirt)
- **Sem mega details**
- **Sem vertical textures**
- **Sem tile texture**
- **Sem mirroring**
- **Single pass**: terrain_gbuffer.wgsl (G-buffer fill direto)
- **GPU instancing**: ate 64 chunks com frustum culling por chunk

### Tabela

| Feature | Dagor | Tucano | Status |
|---------|-------|--------|--------|
| Detail layers | 7 IDs + 2 textures | 4 RGBA8 weights | Simplificado |
| Mega details | 3 texture arrays | Ausente | Ausente |
| Vertical textures | 3 textures (cliffs) | Ausente | Ausente |
| Tile texture | Large-scale map | Ausente | Ausente |
| Mirroring | 9 estados 3x3 | Ausente | Ausente |
| Clipmap rendering | Sim | Ausente | Ausente |
| Decal pass | Sim | Ausente | Ausente |
| Depth-only pass | Sim | Ausente | Ausente |
| Reflection pass | Sim | Ausente | Ausente |
| Procedural detail | Nao (texturas authored) | Sim (128x128 noise) | Exclusivo Tucano |

### Plano para atingir 100%

1. Expandir para 7 detail layers (portar `LandClassDetailTextures`)
2. Adicionar mega details (3 texture arrays)
3. Adicionar vertical textures para cliffs
4. Implementar mirroring (9 estados 3x3)
5. Adicionar clipmap rendering pass

**Paridade atual: 40%** (sem mudanca significativa)

---

## 7. Resumo: Scores do Sistema Terrain

| # | Subsistema | Paridade Anterior | Paridade Atual | Delta |
|---|-----------|-------------------|----------------|-------|
| 1 | Heightfield / CompressedHeightmap | 45% | **70%** | +25% |
| 2 | Height Queries | 40% | **60%** | +20% |
| 3 | Deformation / Editing | 25% | **50%** | +25% |
| 4 | Holes / Caves | 35% | **55%** | +20% |
| 5 | LOD & Mesh Generation | 30% | **48%** | +18% |
| 6 | Splat Rendering | 40% | **40%** | 0% |
| 7 | Streamer | 65% | **65%** | 0% |
| 8 | Procedural | 60% | **60%** | 0% |
| | **Media Terrain** | **42%** | **56%** | **+14%** |

---

## 8. Top 5 Regressoes (ainda nao resolvidas)

| # | Regressao | Impacto |
|---|-----------|---------|
| 1 | **Segundo estagio de compressao ausente** | Dados ocupam ~8x mais espaco em disco/RAM sem Zstd/Oodle |
| 2 | **Hierarquia de 1 nivel vs quadtree completo** | Range query O(N) vs O(log N). Impacto em culling de chunks massivos |
| 3 | **SIMD decode ausente** | 4x mais lento em queries de altura (frustum culling, physics, ray tracing) |
| 4 | **Packed int16 vertices ausentes** | 2x mais VRAM por vertice (f32 vs int16 packed) |
| 5 | **Terraform patch system ausente** | Edicao limitada a resolucao do heightfield (cels de 2m vs 0.25m) |

## 9. Top 5 Features Exclusivas do Tucano

| # | Feature | Diferencial |
|---|---------|-------------|
| 1 | **Undo/Redo integrado** | Dagor nao tem sistema de undo no Terraform |
| 2 | **3D volume types (disk/capsule/box)** | Dagor usa matrix generica (mais lento, menos intuitivo) |
| 3 | **Density field com gradiente** | Dagor e binario. Tucano permite bordas suaves em holes |
| 4 | **3 LODs runtime vs 2 pre-computados** | Mais granularidade de LOD, sem pre-baking necessario |
| 5 | **LOD skirts** | Preenche T-junctions entre LODs diferentes. Dagor depende de geometria pre-merged |
