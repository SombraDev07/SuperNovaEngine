# Sponza (Khronos glTF Sample Assets)

Indoor PBR stress test for TucanoEngine.

## Setup

```powershell
powershell -File tools/fetch_sponza.ps1
```

Or ensure `Sponza.gltf`, `Sponza.bin`, and all texture URIs from the glTF sit in this folder.

## Run

```powershell
zig build run -- --sponza
```

Controls: WASD / QE fly, RMB look, `` ` `` / F1 console. Terrain streaming and sculpt are disabled in this mode.
