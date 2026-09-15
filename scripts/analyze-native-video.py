"""Extract change/key-event frames from a native UI recording; never infer UI success from a log."""
import argparse
from datetime import datetime
import hashlib
import html
import json
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageDraw


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def analyze(video, events_path, output):
    if output.exists():
        raise ValueError("Use a new output directory to preserve prior evidence.")
    output.mkdir(parents=True)
    info = json.loads(run("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,avg_frame_rate,nb_frames:format=duration", "-of", "json", str(video)))
    stream = info["streams"][0]
    num, den = map(int, stream["avg_frame_rate"].split("/"))
    fps = num / den
    duration = float(info["format"]["duration"])
    timeline = json.loads(events_path.read_text(encoding="utf-8-sig"))
    start = datetime.fromisoformat(timeline["captureProcessStartedAt"].replace("Z", "+00:00"))
    events = [{"event": e["event"], "seconds": (datetime.fromisoformat(e["at"].replace("Z", "+00:00")) - start).total_seconds()}
              for e in timeline["events"]]
    outside = [e for e in events if not 0 <= e["seconds"] < duration]
    # Event times are approximate wall-clock anchors. Keep nearby frames for visual review.
    anchors = {round(min(duration - 1 / fps, max(0, e["seconds"] + delta)) * fps)
               for e in events if e not in outside for delta in (-0.5, 0.5)}
    width = 320
    height = round(stream["height"] * width / stream["width"])
    process = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(video), "-vf", f"scale={width}:{height}",
                                "-f", "rawvideo", "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    reference = None
    previous = None
    kept = []
    anomalies = []
    duplicates = 0
    index = 0
    frame_bytes = width * height
    while True:
        data = process.stdout.read(frame_bytes)
        if not data:
            break
        while len(data) < frame_bytes:
            extra = process.stdout.read(frame_bytes - len(data))
            if not extra:
                raise ValueError("Truncated decoded frame.")
            data += extra
        current = np.frombuffer(data, dtype=np.uint8).reshape(height, width).astype(np.int16)
        changed = reference is None
        fraction = 1.0 if reference is None else float(np.mean(np.abs(current - reference) > 18))
        tile_change = 1.0 if reference is None else max(float(np.mean(np.abs(a - b) > 18))
            for row_a, row_b in zip(np.array_split(current, 4), np.array_split(reference, 4))
            for a, b in zip(np.array_split(row_a, 4, axis=1), np.array_split(row_b, 4, axis=1)))
        changed = changed or fraction > .01 or tile_change > .06
        flash = previous is not None and float(np.mean(np.abs(current - previous) > 60)) > .4
        if flash:
            anomalies.append({"seconds": index / fps, "kind": "large-frame-transition-review-required"})
        at_anchor = index in anchors
        # Never use duplicate removal to claim no flashes: retain large transitions separately.
        gap = not kept or (index - kept[-1]["frame"]) / fps >= .5
        if not kept or flash or (changed and gap) or at_anchor:
            # A button label/time change can be tiny. Event anchors use near-exact
            # comparison instead of the broader scene threshold used between events.
            similar = reference is not None and (float(np.mean(np.abs(current - reference) > 2)) < .00005
                                                  if at_anchor else fraction < .001 and tile_change < .012)
            if similar and not flash:
                duplicates += 1
            else:
                kept.append({"frame": index, "seconds": round(index / fps, 3), "eventAnchor": at_anchor,
                             "changedFraction": round(fraction, 5), "maxTileChange": round(tile_change, 5)})
                reference = current.copy()
        else:
            duplicates += 1
        previous = current
        index += 1
    error = process.stderr.read().decode(errors="replace")
    if process.wait() != 0:
        raise RuntimeError(error)
    expected = int(stream.get("nb_frames", index))
    if index != expected:
        raise ValueError(f"Decoded {index} frames, expected {expected}.")
    # Decode selected frame indices in one pass. Rounded time seeks can select
    # the following frame, or no frame at all when the retained frame is last.
    selection = output / "selection.filter"
    selection.write_text("select=" + "+".join(f"eq(n\\,{frame['frame']})" for frame in kept), encoding="utf-8")
    run("ffmpeg", "-v", "error", "-i", str(video), "-filter_script:v", str(selection),
        "-fps_mode", "vfr", "-start_number", "0", str(output / "selected-%06d.png"))
    extracted = sorted(output.glob("selected-*.png"))
    if len(extracted) != len(kept):
        raise ValueError(f"Extracted {len(extracted)} selected frames, expected {len(kept)}.")
    for number, frame in enumerate(kept):
        name = f"key-{number:03d}-{frame['seconds']:07.3f}.png"
        extracted[number].rename(output / name)
        frame["image"] = name
    with video.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    report = {"video": str(video.resolve()), "sha256": digest,
              "durationSeconds": duration, "fps": fps, "decodedFrames": index, "retainedFrames": len(kept),
              "suppressedFrames": duplicates, "eventsOutsideVideo": outside, "events": events, "keyframes": kept,
              "transitionCandidates": anomalies, "visualAcceptance": "requires-frame-review",
              "limits": ["No audio was recorded by this UI capture.", "Wall-clock event alignment is approximate.",
                         f"{fps:g} fps cannot exclude sub-frame flashes.", "Pixel differences cannot determine semantic UI correctness or occlusion."]}
    (output / "analysis.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    cols, cell_w, cell_h = 3, 480, 344
    sheet = Image.new("RGB", (cols * cell_w, ((len(kept) + cols - 1) // cols) * cell_h), "#e6e9ee")
    draw = ImageDraw.Draw(sheet)
    for number, frame in enumerate(kept):
        with Image.open(output / frame["image"]) as picture:
            picture.thumbnail((470, 310))
            x, y = number % cols * cell_w, number // cols * cell_h
            sheet.paste(picture, (x + 5, y + 25))
            draw.text((x + 8, y + 5), f"{number:03d}  {frame['seconds']:.3f}s", fill="black")
    sheet.save(output / "contact-sheet.jpg", quality=90)
    cards = "".join(f'<figure><a href="{f["image"]}"><img src="{f["image"]}"></a><figcaption>{f["seconds"]:.3f}s</figcaption></figure>' for f in kept)
    page = f'<!doctype html><meta charset="utf-8"><title>Native UI video evidence</title><style>body{{font-family:system-ui;margin:24px;background:#f3f5f8}}main{{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}}figure{{margin:0;background:white;padding:8px}}img{{width:100%}}</style><h1>Native UI video evidence</h1><p>{html.escape(video.name)} · {duration:.2f}s · {index} frames → {len(kept)} keyframes</p><p>Visual verdict requires reviewing these frames; event logs alone do not prove success.</p><main>{cards}</main>'
    (output / "index.html").write_text(page, encoding="utf-8")
    print(json.dumps({"output": str(output), "frames": index, "keyframes": len(kept), "eventsOutside": len(outside)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    analyze(args.video, args.events, args.output)
