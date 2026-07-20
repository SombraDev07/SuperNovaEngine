# TucanoEngine - AAA Open-World Game Engine (Zig)

## Stack de Bibliotecas Existentes (Prioridade Máxima)

| Sistema | Biblioteca | Origem | Maturidade |
|---------|-----------|--------|------------|
| **Render** | [zgpu](https://github.com/zig-gamedev/zgpu) | Dawn/WebGPU (Vulkan/Metal/DX12) | Usável, ativo |
| **Janela/Input** | [zglfw](https://github.com/zig-gamedev/zglfw) | GLFW 3.x | Maduro |
| **Matematica** | [zmath](https://github.com/zig-gamedev/zmath) | SIMD math (zig-gamedev) | Maduro |
| **ECS** | World placeholder → zig-ecs / flecs | zig-ecs ainda em Zig 0.14 | Em andamento |
| **Fisica** | [zphysics](https://github.com/zig-gamedev/zphysics) | Jolt Physics (multi-threaded) | Usável |
| **Audio** | [zaudio](https://github.com/zig-gamedev/zaudio) | miniaudio (cross-platform) | Usável |
| **UI / Editor** | [zgui](https://github.com/zig-gamedev/zgui) | Dear ImGui + ImPlot + ImGuizmo | Maduro |
| **Assets** | [zstbi](https://github.com/zig-gamedev/zstbi) | stb_image (imagens) | Usável |
| **Malhas** | [zmesh](https://github.com/zig-gamedev/zmesh) | cgltf + par_shapes + meshoptimizer | Usável |
| **Noise** | [znoise](https://github.com/zig-gamedev/znoise) | FastNoiseLite | Usável |
| **Profiling** | [ztracy](https://github.com/zig-gamedev/ztracy) | Tracy (CPU+GPU) | Usável |
| **Rede** | [zig-network](https://github.com/ikskuh/zig-network) | TCP/UDP/multicast | Maduro |
| **Jobs** | [zjobs](https://github.com/zig-gamedev/zjobs) | Job queue multithread | Usável |
| **Pool** | [zpool](https://github.com/zig-gamedev/zpool) | Pool/Handle allocator | Usável |

## Bibliotecas a Criar (não existem no ecossistema)

| Sistema | Abordagem |
|---------|-----------|
| **Navegacao** | Bindings Recast/Detour (C++) -> `znav` |
| **Animacao Esqueletica** | Runtime próprio ou bindings ozz-animation |
| **Compressao Textura** | Bindings Basis Universal -> `zbasis` |
| **Scripting** | Embed LuaJIT via C interop -> `zlua` |
| **Serializacao Binaria** | Comptime Zig + schema generator |

---

## FASE 1: Fundacao (Meses 1-6)

### 1.1 Setup do Projeto
- [x] `build.zig` com todas as dependencias
- [x] Sistema de build multi-plataforma (Windows/Linux/Mac)
- [x] CI/CD com GitHub Actions
- [x] Estrutura de diretorios padronizada

### 1.2 Core Runtime
- [x] Game loop com delta time fixo
- [x] Sistema de cenas (Scene/World/Level)
- [ ] GameObject + Component model (zig-ecs) — *placeholder World até ECS compatível com Zig 0.15*
- [x] Sistema de eventos
- [x] Resource manager (carregamento/descarga de assets)

### 1.3 Renderer Base
- [x] Inicializacao zgpu + zglfw
- [x] Swapchain e render loop
- [x] Clear screen + apresentacao
- [x] Shader loading (WGSL)
- [x] Camera basica (perspective + lookAt via zmath)
- [x] Desenho de geometria simples (triangulo/cubo)

### 1.4 Ferramentas
- [x] Logger estruturado (canais, niveis)
- [x] Sistema de asserts
- [x] Integracao ztracy (profiling zones)
- [x] Console de debug in-game

> **Toolchain:** Zig **0.15.2** (ver `.zigversion`). zig-gamedev ainda nao suporte Zig 0.16/0.17.
---

## FASE 2: Renderer Avancado (Meses 6-12)

### 2.1 PBR Pipeline
- [x] PBR deferred rendering (albedo, normal, metallic-roughness, AO)
- [x] Iluminacao direcional, ponto, spot
- [x] Environment maps (IBL diffuse + specular)
- [x] HDR tonemapping (ACES)
- [x] Bloom post-process

### 2.2 Sombras
- [x] Shadow maps direcionais (cascaded para open world)
- [x] Shadow maps omnidirecionais (point lights)
- [x] PCSS soft shadows

### 2.3 Otimizacoes de Render
- [ ] Frustum culling (CPU)
- [ ] GPU-driven indirect drawing
- [ ] Occlusion culling (software raster ou HZB)
- [ ] Render graph (compila pipeline declarativa -> comandos GPU)

### 2.4 Materiais
- [ ] Sistema de materiais (JSON/ZON definidos)
- [ ] Pipeline de shaders (hot reload)
- [ ] Texturas: albedo, normal, metallic-roughness, AO, emissive, height
- [ ] Suporte a texturas comprimidas (BC1-7, ASTC via zbasis + nativos)

---

## FASE 3: Mundo Aberto - Core (Meses 12-24)

### 3.1 World Streaming
- [ ] Grid de chunks 2D (coordenadas mundiais)
- [ ] Load/unload assincrono de chunks baseado em distancia
- [ ] Streaming pool com prioridade (LOD 0 > 1 > 2)
- [ ] Double-buffered chunk data (evita stalls na thread principal)

### 3.2 Terreno
- [ ] Heightmap import/export
- [ ] Terreno procedural (znoise: Perlin, Simplex, domain warping)
- [ ] GPU tessellation adaptation (distancia -> resolucao)
- [ ] Splat mapping (multi-textura com blend mask)
- [ ] Holes (cavernas, tunels) via density field
- [ ] Edicao de terreno no editor (raise/lower/smooth/paint)

### 3.3 Sistema de LOD
- [ ] Mesh LOD (simplificacao automatica via zmesh/meshopt)
- [ ] Material LOD (reducao de texturas)
- [ ] Shader LOD (simplificacao de iluminacao a distancia)
- [ ] Hierarchical LOD (HLOD) para objetos distantes

### 3.4 Vegetacao
- [ ] GPU instancing massivo (indirect draw)
- [ ] Distribuicao procedural baseada em regras (slope, altura, bioma)
- [ ] Impostors para distancia extrema
- [ ] Sway/wind na GPU (vertex shader)

### 3.5 Ceu e Clima
- [ ] Sky atmosphere scattering (Rayleigh/Mie)
- [ ] Nuvens volumetricas (raymarching)
- [ ] Sistema de clima (chuva, neve, neblina)
- [ ] Ciclo dia/noite com transicao suave
- [ ] Estrelas + lua a noite

---

## FASE 4: Gameplay Systems (Meses 18-30)

### 4.1 Fisica (zphysics / Jolt)
- [ ] Corpos rigidos (static, dynamic, kinematic)
- [ ] Colliders (box, sphere, capsule, convex, mesh, heightfield)
- [ ] Character controller (open-world ready)
- [ ] Veiculos (raycast wheels + suspension)
- [ ] Constraints e joints
- [ ] Raycasting e queries espaciais

### 4.2 Animacao
- [ ] Skeletal animation runtime (import glTF via zmesh)
- [ ] Animation blending (crossfade, additive)
- [ ] Animation state machine
- [ ] IK (CCD, FABRIK)
- [ ] Ragdoll (integra com Jolt Physics)
- [ ] Blend shapes / morph targets

### 4.3 Audio (zaudio / miniaudio)
- [ ] Audio sources (point, ambient)
- [ ] Spatial audio (HRTF ou panning stereo)
- [ ] Streaming de audio (musica, dialogos)
- [ ] Mixer com grupos e efeitos
- [ ] Reverb/occlusion baseado em geometria

### 4.4 AI / Navegacao
- [ ] Navmesh generation (znav via Recast)
- [ ] Pathfinding (Detour)
- [ ] Crowd simulation (DetourCrowd)
- [ ] Behaviour trees
- [ ] Sistema de percepcao (visao, audicao)

### 4.5 Scripting
- [ ] Embed LuaJIT via C interop (zlua)
- [ ] Bindings automaticos Zig -> Lua (comptime reflection)
- [ ] Hot-reload de scripts
- [ ] Sandbox de seguranca

---

## FASE 5: Editor (Meses 24-36)

### 5.1 Framework do Editor (zgui)
- [ ] Janela dockable multi-viewport
- [ ] Menu bar, toolbar, status bar
- [ ] Undo/redo system
- [ ] Command pattern para todas as operacoes
- [ ] Asset browser com thumbnails

### 5.2 Scene Editor
- [ ] Viewport 3D com gizmos (ImGuizmo: translate/rotate/scale)
- [ ] Outliner hierarquico (arvore de entidades)
- [ ] Inspector de componentes (dinamico via reflection)
- [ ] Drag & drop de assets para a cena
- [ ] Snap to grid/surface

### 5.3 Terrain Editor
- [ ] Sculpting tools (raise, lower, smooth, flatten)
- [ ] Paint layers (splat map)
- [ ] Foliage placement tool
- [ ] Heightmap import/export

### 5.4 Material Editor
- [ ] Preview sphere/plane/mesh
- [ ] Parametros PBR editaveis
- [ ] Visualizacao de texturas individuais
- [ ] Live preview na cena

### 5.5 Animation Editor
- [ ] Timeline de animacao
- [ ] Curve editor (bezier, linear, step)
- [ ] Animation state machine visual
- [ ] Blend space 1D/2D

### 5.6 Outras Ferramentas
- [ ] Console de log integrado
- [ ] Profiler visual (dados do ztracy)
- [ ] Memory tracker
- [ ] Build pipeline configuracao

---

## FASE 6: Launcher e Distribuicao (Meses 30-42)

### 6.1 Launcher
- [ ] Autenticacao (OAuth2, login social)
- [ ] Painel de noticias/updates
- [ ] Gerenciador de versoes do jogo
- [ ] Download incremental (delta patches)
- [ ] Verificacao de integridade (SHA256)
- [ ] Anti-cheat client-side (basico)

### 6.2 Backend
- [ ] API REST (Zig http server)
- [ ] CDN para assets
- [ ] Analytics (opt-in)
- [ ] Crash reporting
- [ ] Telemetria de performance

### 6.3 Build Pipeline
- [ ] Asset cooking (texturas -> BC7, mesh -> otimizado)
- [ ] Data baking (navmesh, lightmaps, reflection probes)
- [ ] Empacotamento (pak files com compressao)
- [ ] Versionamento de assets (diferencas binarias)
- [ ] Integracao CI/CD para builds automaticas

---

## FASE 7: Polimento e Console (Meses 36-48)

### 7.1 Otimizacao
- [ ] GPU frame timing e reducao de bubbles
- [ ] Memory pooling e reducao de alocacoes
- [ ] Async loading sem stalls
- [ ] Otimizacao de shaders por plataforma
- [ ] LOD chains completas (malha + material + shader)

### 7.2 Plataformas
- [ ] Abstracoes de plataforma (render, input, fs, threading)
- [ ] Suporte a controles (XInput, DualSense, Switch Pro)
- [ ] Achievements / trophies
- [ ] Save system cloud-synced

### 7.3 Qualidade
- [ ] Testes automatizados (ECS systems, math, serialization)
- [ ] Testes de render (captura de frame e comparacao)
- [ ] Testes de performance (benchmarks automatizados)
- [ ] Documentacao da API pública
- [ ] Samples e templates de projeto

---

## FASE 8: Futuro (Alem de 48 Meses)

- [ ] Nanite-style geometry (meshlets + software raster)
- [ ] Ray tracing (DXR/Vulkan RT via zgpu quando suportado)
- [ ] GI em tempo real (probes irradiance + DDGI)
- [ ] AI-driven content generation (ML inference on-GPU)
- [ ] Multiplayer networking (replication, prediction, rollback)
- [ ] VR/AR suporte (zopenvr + OpenXR)
- [ ] Destruicao procedural
- [ ] Sistema de modding (user-generated content)

---

## Principios Tecnicos

1. **Zig-first**: Toda a engine em Zig. Bindings C/C++ so quando nao houver alternativa Zig nativa.
2. **Data-driven**: Sistemas configurados via dados (JSON/ZON), nao hardcoded.
3. **Multithread desde o dia 1**: ECS paralelo, asset loading async, render em thread separada.
4. **Cache-friendly**: ECS archetypal (zig-ecs), SoA onde fizer sentido, evitar pointer chasing.
5. **Comptime ao maximo**: Reflection, serializacao, asset pipelines usando comptime Zig.
6. **Editor first**: Toda feature da engine deve ser editavel visualmente. Nada de editar JSON na mao.
7. **Sem garbage collection**: Memory arenas, pools (zpool), lifetime explicito.
