"""
transcribe.py - Referenz-Version (large-v3-turbo, 10-Min-Chunks)

Diese Datei dient als Backup/Referenz. Die produktive Datei liegt unter
C:\\Videocalls\\transcribe.py und MUSS vom User manuell mit dem Inhalt
dieser Datei aktualisiert werden.

Aufruf:
    C:\\Python314\\python.exe C:\\Videocalls\\transcribe.py <audio.mp3>

Output: <basename>.txt neben Input-Audio.
Zusatz-stdout: Zeilen "PROGRESS:<0.0..1.0>" pro Whisper-Segment (für Toast-UI).
"""

import sys
import os
import json
import subprocess
import tempfile
import shutil
from faster_whisper import WhisperModel

audio_path = sys.argv[1]
output_path = os.path.splitext(audio_path)[0] + ".txt"

# Modell large-v3-turbo (DE-Fine-Tune), CPU + int8 fuer AMD-Surface
model = WhisperModel("TheChola/whisper-large-v3-turbo-german-faster-whisper", device="cpu", compute_type="int8")

# Gesamt-Dauer via ffprobe fuer monotonen Fortschritt ueber Chunks hinweg.
# Fallback: Per-Chunk-Progress (resettet pro Chunk, schlechtere UX, aber kein Crash).
total_duration = 0.0
try:
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", audio_path],
        check=True, capture_output=True, text=True
    )
    total_duration = float(probe.stdout.strip())
except Exception:
    total_duration = 0.0

# Audio in 10-Min-Chunks splitten um Speicher konstant zu halten
tmpdir = tempfile.mkdtemp(prefix="whisper_chunks_")
try:
    subprocess.run([
        "ffmpeg", "-y", "-i", audio_path,
        "-f", "segment", "-segment_time", "600",
        "-c", "copy", os.path.join(tmpdir, "chunk_%03d.mp3")
    ], check=True, capture_output=True)

    chunks = sorted(os.path.join(tmpdir, f) for f in os.listdir(tmpdir))

    chunk_offset = 0.0
    with open(output_path, "w", encoding="utf-8") as out:
        for i, chunk in enumerate(chunks):
            print(f"Transkribiere Chunk {i+1}/{len(chunks)}...", file=sys.stderr)
            segments, info = model.transcribe(chunk, language="de", beam_size=5)
            for seg in segments:
                if total_duration > 0:
                    progress = min((chunk_offset + seg.end) / total_duration, 1.0)
                elif info.duration:
                    progress = min(seg.end / info.duration, 1.0)
                else:
                    progress = 0.0
                print(f"PROGRESS:{progress:.4f}", flush=True)
                out.write(seg.text.strip() + " ")
            out.write("\n")
            chunk_offset += info.duration or 0.0
            os.remove(chunk)

    print(f"OK: {output_path}")
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
