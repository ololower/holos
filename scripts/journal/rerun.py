#!/usr/bin/env python3
"""Розпізнати заново всі розмічені записи журналу — щоб заміряти зміну проти еталона.

    python3 scripts/journal/rerun.py <назва> [--engine parakeet|whisper] [--tune "blankPenalty=1"] [--model <шлях>]
                                     [--journal <тека>] [--app build/Holos.app] [-- інші параметри Holos]

Результат — <тека журналу>/runs/<назва>.jsonl ({"id", "text", "seconds"}); оцінка:
    python3 scripts/journal/evaluate.py "<тека журналу>/runs/<назва>.jsonl"
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from evaluate import default_journal  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Розпізнати заново розмічені записи журналу")
    parser.add_argument("name", help="назва варіанта — ім'я файлу в runs/")
    parser.add_argument("--engine", default="parakeet", choices=["parakeet", "whisper"])
    parser.add_argument("--tune", help="параметри Parakeet: «blankPenalty=1,padSeconds=0.3»")
    parser.add_argument("--model", help="модель (за замовчуванням — як у Holos)")
    parser.add_argument("--journal", help="тека журналу (за замовчуванням — з налаштувань Holos)")
    parser.add_argument("--app", default=str(ROOT / "build/Holos.app"), help="зібраний Holos.app")
    parser.add_argument("extra", nargs=argparse.REMAINDER, help="після «--» — ще параметри Holos")
    args = parser.parse_args()

    directory = Path(args.journal).expanduser() if args.journal else default_journal()
    reference = [json.loads(l) for l in (directory / "reference.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    files = [str(directory / row["audio"]) for row in reference if (directory / row["audio"]).is_file()]
    out = directory / "runs" / (args.name + ".jsonl")
    out.parent.mkdir(exist_ok=True)

    command = [str(Path(args.app) / "Contents/MacOS/Holos"), "--transcribe-batch", None, "--engine", args.engine]
    if args.tune:
        command += ["--tune", args.tune]
    if args.model:
        command += ["--model", args.model]
    command += [a for a in args.extra if a != "--"]

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as listing:
        listing.write("\n".join(files) + "\n")
    command[2] = listing.name
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    finally:
        Path(listing.name).unlink(missing_ok=True)
    if result.returncode != 0:
        sys.exit("Holos завершився з кодом %d: %s" % (result.returncode, result.stderr.strip()[-500:]))

    rows = []
    for line in result.stdout.splitlines():
        if line.startswith("{"):
            row = json.loads(line)
            rows.append({"id": Path(row["file"]).stem, "text": row["text"], "seconds": row["seconds"]})
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    total = sum(r["seconds"] for r in rows)
    print("%s: %d записів, розпізнавання %.1f с (у середньому %.2f с) → %s" % (
        args.name, len(rows), total, total / max(1, len(rows)), out))


if __name__ == "__main__":
    main()
