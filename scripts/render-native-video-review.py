"""Render AI-reviewed frame observations, with file/time evidence gates, as a local report."""
import argparse
from collections import Counter
import hashlib
import html
import json
from pathlib import Path


def render(root, review_path):
    review = json.loads(review_path.read_text(encoding="utf-8"))
    clips = {}
    for name, folder in review["clips"].items():
        report = json.loads((root / folder / "analysis.json").read_text(encoding="utf-8"))
        video = Path(report["video"])
        with video.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != report["sha256"]:
                raise ValueError("Video changed after frame analysis.")
        clips[name] = (folder, report, video.relative_to(root).as_posix())
    cards = []
    for case in review["cases"]:
        evidence = []
        invalid = not case.get("evidence")
        for item in case.get("evidence", []):
            folder, report, video = clips[item["clip"]]
            frame = next((f for f in report["keyframes"] if f["image"] == item["image"]), None)
            if frame is None or not (root / folder / item["image"]).is_file() or not 0 <= frame["seconds"] < report["durationSeconds"]:
                invalid = True
                continue
            image = f'{folder}/{item["image"]}'
            evidence.append(f'<figure><a href="{html.escape(image)}"><img loading="lazy" src="{html.escape(image)}" alt="{html.escape(case["title"])}"></a><figcaption><a href="{video}#t={frame["seconds"]}">{html.escape(item["clip"])} · {frame["seconds"]:.3f}s</a></figcaption></figure>')
        if case["status"] == "通过" and invalid:
            case["status"] = "证据不足"
            case["evidenceGate"] = "missing-or-invalid-video-frame"
        else:
            case["evidenceGate"] = "valid-frame-references" if not invalid else "not-claimed-as-passed"
        cards.append(f'<article><span class="badge">{html.escape(case["status"])}</span><h2>{html.escape(case["title"])}</h2><p>{html.escape(case["finding"])}</p><div class="frames">{"".join(evidence)}</div></article>')
    counts = dict(Counter(c["status"] for c in review["cases"]))
    videos = "".join(f'<section><h2>{html.escape(name)}</h2><video controls preload="metadata" src="{video}"></video><p>{report["durationSeconds"]:.2f}s · {report["decodedFrames"]} 原始帧 → {report["retainedFrames"]} 关键帧 · <a href="{folder}/index.html">全部关键帧</a></p></section>' for name, (folder, report, video) in clips.items())
    review["counts"] = counts
    review["method"] = "AI visual review of extracted frames; automated hash, timestamp and evidence-reference checks. Pixel differences alone do not judge UI correctness."
    (root / "acceptance.json").write_text(json.dumps(review, ensure_ascii=False, indent=2), encoding="utf-8")
    content = f'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Recappi 原生 UI 视频验收</title><style>body{{font:16px/1.6 system-ui;margin:0;background:#f3f5f8;color:#202936}}header,main{{max-width:1160px;margin:auto;padding:24px}}h1{{margin:0}}article,section{{background:white;border:1px solid #dee3eb;border-radius:12px;padding:20px;margin:20px 0}}video{{width:100%;max-height:560px;background:#15171a}}.frames{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}}img{{width:100%;border:1px solid #dee3eb}}.badge{{font-weight:700;color:#175cd3}}a{{color:#175cd3}}@media(max-width:700px){{.frames{{display:block}}}}</style><header><h1>Recappi 原生 UI 视频验收</h1><p>{html.escape(review["scope"])}</p><p>{html.escape(" · ".join(f"{k} {v} 项" for k,v in counts.items()))}</p><p>{html.escape(review["limits"])}</p></header><main>{videos}{"".join(cards)}</main></html>'
    (root / "acceptance.html").write_text(content, encoding="utf-8")
    print(json.dumps(counts))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--review", type=Path, required=True)
    args = parser.parse_args()
    render(args.root.resolve(), args.review)
