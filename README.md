# TucanoEngine

**AAA open-world engine in Zig** — deferred PBR, streaming terrain, and a modern GI stack on WebGPU/Dawn.

Built on [zig-gamedev](https://github.com/zig-gamedev) (zgpu · zglfw · zmath · zphysics · zgui · …).

---

## Highlights

| Area | What you get |
|------|----------------|
| **Rendering** | Deferred PBR (GGX), CSM + point/spot shadows, IBL, bloom, auto-exposure, ACES / **AgX** tonemap |
| **Atmosphere** | Bruneton sky, clouds, rain / wetness overlays |
| **GI** | GTAO · DDGI volume probes · SSGI · WorldSDF (JFA) · HZB |
| **World** | Heightfield streaming, LODs, terrain sculpt |
| **Assets** | glTF (Sponza), Basis/KTX2/ASTC, HDRI environment |
| **Tooling** | In-game debug console, shader hot-reload, Tracy hooks |

---

## Requirements

- **Zig 0.15.2** (see `.zigversion`)
- Windows 10+, Linux, or macOS
- GPU with **DX12 / Vulkan / Metal**

> Rider / ZigBrains often pick a newer Zig — point the toolchain at **0.15.2**.

---

## Quick start

```bash
zig build              # → zig-out/bin
zig build run          # default outdoor demo
zig build test
```

From the install dir (so assets resolve):

```bash
cd zig-out/bin
./tucano.exe                 # outdoor
./tucano.exe --sponza        # Khronos Sponza (sun + IBL + AgX)
./tucano.exe --base-only     # minimal clear / triangle path
```

Optional Tracy:

```bash
zig build -Denable-tracy=true
```

**Controls:** WASD / QE fly · RMB look · `` ` `` or F1 console · Esc quit

Sponza assets (if missing):

```powershell
powershell tools/fetch_sponza.ps1
```

---

## Layout

```
src/
  core/         loop, events, console
  scene/        scenes + ECS
  render/       deferred, GI, atmosphere, materials
  world/        terrain streaming / heightfield
  resources/    asset handles & packs
  main.zig
assets/
  shaders/      WGSL (cached + hot-reload)
  models/       glTF (Sponza)
  textures/     demo maps / cooked formats
  env/          HDRI
```

---

## Status

Active development toward Dagor-class open-world depth. Visual AAA path (GTAO → DDGI → SSGI → …) is in progress; parity gates live in the project roadmap (local docs).

---

## License

See repository license file when present. Third-party assets (e.g. Sponza) keep their original licenses.
