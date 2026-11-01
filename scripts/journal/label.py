#!/usr/bin/env python3
"""Розмітка журналу диктувань: що насправді сказано в кожному записі.

    python3 scripts/journal/label.py [--journal <тека>] [--port 8765] [--no-open]

Відкриває в браузері сторінку на 127.0.0.1: слухаєш запис, правиш чернетку, Enter — зберегти й далі.
Сервер лише на цьому Mac; аудіо й текст нікуди не надсилаються, інтернет не потрібен.

У теці журналу (за замовчуванням — та, що в налаштуваннях Holos):
  journal.jsonl    — диктування, пише Holos (лише читається)
  audio/<id>.wav   — що чула модель розпізнавання (лише читається)
  drafts.jsonl     — необов'язково: чернетки еталона {id, draft, note, whisper}; без них чернетка — текст Parakeet
  reference.jsonl  — еталон, пише ця сторінка: рядок на запис, одразу після кожного збереження

Рядок reference.jsonl самодостатній — годиться і для заміру точності, і для донавчання:
  id, audio (шлях відносно теки журналу), text (що сказано; порожньо — без мовлення),
  status: ok | no_speech | unsure, edited (чи правили чернетку), draft, parakeet, gemma, whisper, reviewedAt
"""
import argparse
import json
import os
import re
import subprocess
import tempfile
import threading
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE = HERE / "label.html"
ID = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}$")
STATUSES = {"ok", "no_speech", "unsure"}


def default_journal():
    """Тека з налаштувань Holos, інакше стандартна"""
    try:
        result = subprocess.run(["defaults", "read", "local.holos", "journalPath"], capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip())
    except OSError:
        pass
    return Path.home() / "Library/Application Support/Holos/Journal"


def read_jsonl(path):
    rows = []
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict) and isinstance(row.get("id"), str):
                rows.append(row)
    return rows


class Store:
    def __init__(self, directory):
        self.directory = directory
        self.reference_path = directory / "reference.jsonl"
        self.lock = threading.Lock()
        self.reference = {row["id"]: row for row in read_jsonl(self.reference_path)}

    def journal(self):
        # Щоразу заново: нові диктування з'являються без перезапуску
        return read_jsonl(self.directory / "journal.jsonl")

    def entries(self):
        drafts = {row["id"]: row for row in read_jsonl(self.directory / "drafts.jsonl")}
        result = []
        for row in self.journal():
            draft = drafts.get(row["id"], {})
            inserted = row.get("inserted") or ""
            replaced = row.get("replaced") or ""
            result.append({
                "id": row["id"],
                "date": row.get("date"),
                "seconds": row.get("audioSeconds", 0),
                "parakeet": row.get("recognized") or "",
                # Що вставила модель ШІ — лише якщо вона щось змінила
                "gemma": inserted if row.get("correction") == "виправлено" and inserted != replaced else None,
                "correction": row.get("correction"),
                "whisper": draft.get("whisper"),
                "draft": draft.get("draft"),
                "note": draft.get("note") or "",
                "reference": self.reference.get(row["id"]),
            })
        return result

    def save(self, payload):
        entry_id = payload.get("id")
        status = payload.get("status")
        if not isinstance(entry_id, str) or not ID.match(entry_id) or status not in STATUSES:
            raise ValueError("неправильний запит")
        row = next((r for r in self.entries() if r["id"] == entry_id), None)
        if row is None:
            raise ValueError("такого запису немає в журналі")
        text = " ".join(str(payload.get("text") or "").split())
        if status == "no_speech":
            text = ""
        draft = row["draft"] if row["draft"] is not None else row["parakeet"]
        record = {
            "id": entry_id,
            "audio": "audio/%s.wav" % entry_id,
            "text": text,
            "status": status,
            "edited": text != draft,
            "draft": draft,
            "parakeet": row["parakeet"],
            "gemma": row["gemma"],
            "whisper": row["whisper"],
            "reviewedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        with self.lock:
            self.reference[entry_id] = record
            self._write()
        return record

    def _write(self):
        # Увесь файл заново через тимчасовий: обірваний запис не зіпсує вже розмічене
        lines = [json.dumps(self.reference[key], ensure_ascii=False, sort_keys=True) for key in sorted(self.reference)]
        handle, temporary = tempfile.mkstemp(prefix=".reference.", suffix=".jsonl", dir=str(self.directory))
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            file.write("\n".join(lines) + "\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, self.reference_path)


def handler(store):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, body, content_type):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, code, value):
            self.send(code, json.dumps(value, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                self.send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
            elif path == "/api/entries":
                self.send_json(200, {"journal": str(store.directory), "entries": store.entries()})
            elif path.startswith("/audio/") and path.endswith(".wav"):
                entry_id = path[len("/audio/"):-len(".wav")]
                audio = store.directory / "audio" / (entry_id + ".wav")
                if ID.match(entry_id) and audio.is_file():
                    self.send(200, audio.read_bytes(), "audio/wav")
                else:
                    self.send_json(404, {"error": "аудіо немає"})
            else:
                self.send_json(404, {"error": "немає такої сторінки"})

        def do_POST(self):
            if self.path != "/api/save":
                self.send_json(404, {"error": "немає такої сторінки"})
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                payload = json.loads(self.rfile.read(length) or b"{}")
                record = store.save(payload)
            except (ValueError, json.JSONDecodeError) as error:
                self.send_json(400, {"error": str(error)})
                return
            except OSError as error:
                self.send_json(500, {"error": "не вдалося записати файл: %s" % error})
                return
            self.send_json(200, {"ok": True, "reference": record})

    return Handler


def main():
    parser = argparse.ArgumentParser(description="Розмітка журналу диктувань Holos")
    parser.add_argument("--journal", help="тека журналу (за замовчуванням — з налаштувань Holos)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-open", action="store_true", help="не відкривати браузер")
    args = parser.parse_args()

    directory = Path(args.journal).expanduser() if args.journal else default_journal()
    if not (directory / "journal.jsonl").is_file():
        raise SystemExit("У теці %s немає journal.jsonl — увімкніть журнал у налаштуваннях Holos" % directory)
    store = Store(directory)

    server = None
    for port in range(args.port, args.port + 10):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port), handler(store))
            break
        except OSError:
            continue
    if server is None:
        raise SystemExit("Немає вільного порту від %d до %d" % (args.port, args.port + 9))

    url = "http://127.0.0.1:%d/" % server.server_address[1]
    total = len(store.journal())
    print("Розмітка: %s" % url)
    print("Журнал: %s — записів %d, розмічено %d" % (directory, total, len(store.reference)))
    print("Еталон: %s" % store.reference_path)
    print("Ctrl+C — зупинити")
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
