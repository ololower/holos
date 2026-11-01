#!/usr/bin/env python3
"""Частка неправильних слів (WER) проти розміченого еталона (reference.jsonl, див. label.py).

    python3 scripts/journal/evaluate.py [--journal <тека>] [варіант.jsonl ...] [--errors 20]

Без файлів порівнює те, що вже є в журналі: Parakeet (як розпізнав застосунок), вставлене (після
моделі ШІ) і whisper (якщо є в еталоні). Кожен файл — ще один варіант: рядки {"id" або "file", "text"},
як друкує `Holos --transcribe-batch`.

Слова порівнюються без регістру й розділових знаків; дефіс — як пробіл; апострофи ’ ʼ — як '.
Записи «без мовлення» в WER не входять — для них окремо: скільки разів варіант щось вигадав.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

WORD = re.compile(r"[^\W_]+(?:'[^\W_]+)*")


def default_journal():
    try:
        result = subprocess.run(["defaults", "read", "local.holos", "journalPath"], capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip())
    except OSError:
        pass
    return Path.home() / "Library/Application Support/Holos/Journal"


def words(text):
    text = (text or "").lower().replace("’", "'").replace("ʼ", "'").replace("`", "'").replace("ё", "е")
    text = re.sub(r"[-‐‑–—]", " ", text)
    return WORD.findall(text)


def align(ref, hyp):
    """Левенштейн по словах: (заміни, пропуски, вставки, пари замін)"""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]))
    s = dl = ins = 0
    pairs = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            if ref[i - 1] != hyp[j - 1]:
                s += 1
                pairs.append((ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            dl += 1
            pairs.append((ref[i - 1], "∅"))
            i -= 1
        else:
            ins += 1
            pairs.append(("∅", hyp[j - 1]))
            j -= 1
    return s, dl, ins, pairs


def entry_id(row):
    if row.get("id"):
        return row["id"]
    return Path(row.get("file", "")).stem


def load_variant(path):
    result = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            result[entry_id(row)] = row.get("text") or ""
    return result


def score(name, hypotheses, reference):
    total = Counter()
    pairs = Counter()
    exact = invented = speech = silent = covered = 0
    for row in reference:
        if row["id"] not in hypotheses:
            continue
        covered += 1
        hyp = words(hypotheses[row["id"]])
        if row["status"] == "no_speech":
            silent += 1
            invented += bool(hyp)
            continue
        if row["status"] != "ok":
            continue
        speech += 1
        ref = words(row["text"])
        s, dl, ins, found = align(ref, hyp)
        total.update(words=len(ref), s=s, d=dl, i=ins)
        exact += (s + dl + ins) == 0
        pairs.update(found)
    wer = (total["s"] + total["d"] + total["i"]) / max(1, total["words"])
    return {
        "name": name, "wer": wer, "words": total["words"], "s": total["s"], "d": total["d"], "i": total["i"],
        "exact": exact, "speech": speech, "invented": invented, "silent": silent, "covered": covered,
        "pairs": pairs,
    }


def main():
    parser = argparse.ArgumentParser(description="WER проти еталона журналу диктувань")
    parser.add_argument("variants", nargs="*", help="файли варіантів (JSONL з id/file і text)")
    parser.add_argument("--journal", help="тека журналу (за замовчуванням — з налаштувань Holos)")
    parser.add_argument("--errors", type=int, default=0, help="показати N найчастіших помилок кожного варіанта")
    parser.add_argument("--no-journal-variants", action="store_true", help="не рахувати Parakeet/вставлене/whisper з журналу")
    args = parser.parse_args()

    directory = Path(args.journal).expanduser() if args.journal else default_journal()
    reference = [json.loads(l) for l in (directory / "reference.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    journal = {r["id"]: r for r in (json.loads(l) for l in (directory / "journal.jsonl").read_text(encoding="utf-8").splitlines() if l.strip())}

    results = []
    if not args.no_journal_variants:
        results.append(score("Parakeet (журнал)", {r["id"]: r.get("parakeet") or "" for r in reference}, reference))
        results.append(score("вставлено (журнал)", {i: journal[i].get("inserted") or "" for i in journal}, reference))
        whisper = {r["id"]: r["whisper"] for r in reference if r.get("whisper") is not None}
        if whisper:
            results.append(score("whisper large-v3", whisper, reference))
    for path in args.variants:
        results.append(score(os.path.basename(path).rsplit(".", 1)[0], load_variant(path), reference))

    width = max(len(r["name"]) for r in results)
    print("%-*s  %6s  %5s  %5s  %5s  %9s  %s" % (width, "варіант", "WER", "зам.", "проп.", "вст.", "без помил.", "вигадав на тиші"))
    for r in results:
        print("%-*s  %5.1f%%  %5d  %5d  %5d  %4d/%-4d  %d/%d%s" % (
            width, r["name"], r["wer"] * 100, r["s"], r["d"], r["i"], r["exact"], r["speech"], r["invented"], r["silent"],
            "" if r["covered"] == len(reference) else "  (записів: %d з %d)" % (r["covered"], len(reference))))
    print("слів в еталоні: %d" % results[0]["words"] if results else "")
    if args.errors:
        for r in results:
            print("\n%s — найчастіші помилки (еталон → варіант):" % r["name"])
            for (ref, hyp), count in r["pairs"].most_common(args.errors):
                print("  %3d  %s → %s" % (count, ref, hyp))


if __name__ == "__main__":
    sys.exit(main())
