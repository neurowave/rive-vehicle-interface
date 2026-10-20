#!/usr/bin/env python3
"""Renders a scripted tour of the showroom to build/tour.mp4 (headless, one screenshot per frame).

Each frame is a fresh deterministic run: advance to the frame, replaying the key presses on the way.
Frames render one at a time (parallel headless renders can trip the script watchdog) and are kept in
build/tour/, so an interrupted run resumes where it stopped.

Usage: python3 tools/tour.py [--size 1920x1080] [--fps 30] [--start 0] [--end TOTAL] [--rive rive]
"""
import argparse, os, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
# (frame, key) presses at 60 fps: intro, then each panel in turn, boost, welcome light, back to Status
EVENTS = [(450, "right"), (660, "right"), (870, "right"), (1080, "right"), (1180, "b"), (1290, "d"), (1420, "key1")]
TOTAL = 1620


def args_for(frame):
    a, t = [], 0
    for f, key in EVENTS:
        if f >= frame:
            break
        a += [f"--advance={f - t}", f"--key={key}"]
        t = f
    a.append(f"--advance={max(1, frame - t)}")
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--fps", type=int, default=30, choices=[15, 20, 30, 60])
    ap.add_argument("--start", type=int, default=0, help="first sim frame (60 fps)")
    ap.add_argument("--end", type=int, default=TOTAL, help="last sim frame (60 fps), exclusive")
    ap.add_argument("--rive", default="rive", help="CLI binary")
    ap.add_argument("--frames", default=os.path.join(ROOT, "build", "tour"), help="png frame directory")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "tour.mp4"))
    o = ap.parse_args()
    step = 60 // o.fps
    os.makedirs(o.frames, exist_ok=True)
    frames = list(range(max(1, o.start), o.end, step))
    for n, f in enumerate(frames):
        png = os.path.join(o.frames, f"f{n:05d}.png")
        if os.path.exists(png):
            continue
        for attempt in range(3):
            cmd = [o.rive, ".", "--aot", f"--screenshot={png}", f"--viewport={o.size}"] + args_for(f)
            if os.environ.get("RIVE_CAPTURE_LOCK"):
                # serialise with other headless captures on this machine (macOS lockf waits for the lock)
                cmd = ["/usr/bin/lockf", "-k", os.environ["RIVE_CAPTURE_LOCK"]] + cmd
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            log = r.stdout + r.stderr
            if os.path.exists(png) and "trapped" not in log and "exceeded" not in log:
                break
            if os.path.exists(png):
                os.remove(png)
            print(f"frame {f}: bad capture, retrying", flush=True)
        if n % 25 == 0:
            print(f"{n}/{len(frames)}", flush=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(o.fps), "-i", os.path.join(o.frames, "f%05d.png"),
                    "-frames:v", str(len(frames)), "-c:v", "libx264", "-preset", "slow", "-pix_fmt", "yuv420p",
                    "-crf", "20", "-movflags", "+faststart", o.out], check=True)
    print("wrote", o.out)


if __name__ == "__main__":
    sys.exit(main())
