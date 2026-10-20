# Rive Vehicle Interface

https://github.com/user-attachments/assets/d0886e18-e0cb-4250-94d4-0a2f42ebbcb9

A car showroom and in-vehicle interface built entirely with the [Rive CLI](https://rive.app/docs/cli/overview):
a photoreal 3D scene rendered with Rive's GPU canvas and WGSL shaders, with the vehicle UI (status, vehicle,
navigation, media and climate panels, the top bar, the dock and the hotspot pins) made of live Rive artboards
with layouts, state machines and data binding.

The whole project is plain source files: RML markup for the artboards (`scene.rml`), AnimaScript for the
camera, input and renderer, and WGSL for the shaders. The UI lives in `scene.rml` itself, so you can edit it by
hand, or push it to the Rive Editor, let designers work on it there, and pull their changes back.

The car, "CNCPT R1", is a fictional concept: the Khronos glTF sample "Car Concept" (CC BY 4.0, see Credits)
with the showroom's own paint and materials.

## Run it

1. Install the Rive CLI:

   ```bash
   curl -fsSL https://releases.rive.app/cli/install.sh | sh
   ```

2. From this folder:

   ```bash
   rive . --aot
   ```

   This builds `build/rive-vehicle-interface.riv` and opens the preview window. `--aot` compiles the scripts
   ahead of time (much faster at runtime).

The car pack (`car.bin`) and the plate texture (`t_plate.bin`) are checked in, so nothing else is needed to
run it. Tested with Rive CLI 1.5.1, 1.6.0 and the 1.7 previews.

### Troubleshooting

- **`script tier: interp, no wamrc`** in the log means the ahead-of-time compiler wasn't found, so scripts
  run in the interpreter. Everything still works, just at a lower frame rate. Point `RIVE_WAMRC` at a
  `wamrc` binary to enable it.
- A headless frame for checking a change:
  `rive . --screenshot=build/x.png --viewport=1600x900 --data=section=0 --advance=1300`.

## Controls

| Input | Action |
|---|---|
| ← / → | previous / next panel |
| 1 to 5 | Status, Vehicle, Navigate, Media, Climate |
| L | headlights |
| B | boost (the wheels spin up) |
| G | welcome light (a light carpet under the car) |
| N | day / night |
| Q | graphics quality: high, balanced, fast |
| K or / | show / hide the keyboard shortcuts |
| R | replay the intro |
| drag | orbit the car |
| scroll | zoom |
| click | panels, dock buttons and hotspot pins |

## Edit it in the Rive Editor

The project is laid out the way `rive pull` writes it (`scene.rml`, with every script, shader and asset as a
file next to it), so it round-trips cleanly between the CLI and the Rive Editor:

```bash
rive login
rive push            # first push: creates a file in your Rive account and records the link in rive.yaml
```

Designers open that file in the Rive Editor and change layouts, colors, text, animations and state machines.
Bring their work back with:

```bash
rive pull            # writes the Editor's version over scene.rml and the asset files
git diff             # review what changed
```

Keep the project in Git: a pull overwrites the local files with the Editor's version, and a push replaces the
Editor's content with yours, so commit before either one. Edits made on both sides at once are not merged.

Two things are tied to the artboards by code. `world.as` reads and writes the `Garage` view model by property
name, so keep those names. The leader lines on the Vehicle panel start from fixed panel coordinates
(`CO_AX` / `CO_AY` in `world.as`): if a designer moves those chips, update the numbers.

## How it's built

| Piece | Where |
|---|---|
| Artboards (garage HUD, five glass panels, visor bars, LED wall), view model, state machines | `scene.rml` |
| Animated Rive wordmark | `logo.rml` |
| Camera director, panels on the visor lens, input, environment cube, render passes, graphics settings | `world.as` |
| Car mesh pack loader (streams a few meshes per frame) | `carpack.as` |
| Texture decode and GPU mip chains | `tex.as` |
| Shaders | `env.wgsl` (sky, mountains, lake, rocks, light wall, environment cube), `car.wgsl` (car paint, glass, tyres, floor, glass UI, visor), `post.wgsl` (bloom, frost, tone mapping) |
| Car mesh pack | `car.bin`, exported by `tools/export_car.py` (Blender, headless) |
| Number plate texture | `t_plate.bin` (a PNG), drawn by `tools/make_plate.py` |
| Album cover, city map, font | `album.jpeg`, `map.jpeg`, `Inter.ttf` |
| Tour video | `tools/tour.py` -> `build/tour.mp4` |

The car pack is one binary file: the meshes merged per material, quantised vertices (position, octahedral
normal, uv, baked ambient occlusion) and the four wheel pivots. `world.as` shades each mesh by its material
name (`matFor`), so changing the paint or a trim colour is a one-line edit there.

### Rebuilding the car and the plate

Only needed if you change the car or the plate. The car exporter needs [Blender](https://www.blender.org)
(tested with 5.2) and the model from the Khronos glTF Sample Assets. The plate needs Pillow.

```bash
curl -fsSL -o CarConcept.glb \
  https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/CarConcept/glTF-Binary/CarConcept.glb
blender -b --factory-startup -P tools/export_car.py -- CarConcept.glb car.bin --ao 64 --scale 1.08

python3 -m venv .venv && .venv/bin/pip install pillow
.venv/bin/python tools/make_plate.py           # t_plate.bin

rive . --aot
```

`export_car.py` squares up the model's steered front wheels, maps its materials onto the renderer's names,
bakes ambient occlusion with Cycles (`--ao` samples; leave it out for a fast export) and scales the car
(`--scale`, 1.08 fits the showroom's framing). It uses none of the model's textures: the Khronos logos live in
those, so they never reach the pack.

## Credits

- **Car model:** [Car Concept](https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/CarConcept)
  by Eric Chadwick, © 2024 Darmstadt Graphics Group GmbH, from the Khronos glTF Sample Assets. Licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). It started from the public domain
  [Free Concept Car 004](https://sketchfab.com/3d-models/free-concept-car-004-public-domain-cc0-4cba124633eb494eadc3bb0c4660ad7e)
  by Unity Fan (CC0). Changes: wheels squared up, materials replaced, model textures and logos removed,
  converted to the `car.bin` pack.
- **Fonts:** [Inter](https://github.com/rsms/inter) by The Inter Project Authors, under the
  [SIL Open Font License 1.1](https://openfontlicense.org) (license text in `licenses/`).
- **Album cover and city map** (`album.jpeg`, `map.jpeg`) are AI-generated for this project.
- The CNCPT R1 name and the vehicle data in the UI are fictitious.

## License

The code and generators are released under the [MIT License](LICENSE). Third-party content keeps its own
license as listed under Credits (car model: CC BY 4.0; fonts: SIL OFL 1.1). The Rive name and logo are
trademarks of Rive Inc.
