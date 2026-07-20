# TucanoEngine

AAA open-world game engine written in [Zig](https://ziglang.org/), built on the [zig-gamedev](https://github.com/zig-gamedev) stack (WebGPU/Dawn, GLFW, Jolt, …).

## Requirements

- **Zig 0.15.2** (required by zig-gamedev libraries)
- Windows 10+, Linux, or macOS
- GPU with Vulkan / Metal / DirectX 12

> Rider/ZigBrains may default to a newer Zig. Point the toolchain at `0.15.2` for this project.

## Quick start

```bash
zig build          # build engine + install to zig-out/bin
zig build run      # launch (clear-screen window, Esc to quit)
zig build test     # unit tests
```

Optional Tracy profiling:

```bash
zig build -Denable-tracy=true
```

## Layout

```
src/
  core/        logger, asserts, fixed timestep loop, events
  scene/       Scene / World (entity registry placeholder)
  render/      zgpu renderer + camera
  resources/   ref-counted asset handles
  main.zig     boot executable
assets/        shaders, meshes, textures (cooked at install)
```

## Roadmap

See [ROADMAP.md](ROADMAP.md).
