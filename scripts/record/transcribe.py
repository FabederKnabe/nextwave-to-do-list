"""
transcribe.py - Referenz-Version (large-v3-turbo, 10-Min-Chunks)

Diese Datei dient als Backup/Referenz. Die produktive Datei liegt unter
C:\\Videocalls\\transcribe.py und MUSS vom User manuell mit dem Inhalt
dieser Datei aktualisiert werden.

Aufruf:
    C:\\Python314\\python.exe C:\\Videocalls\\transcribe.py <audio.mp3>

Output: <basename>.txt neben Input-Audio.
"""

import sys
import os
import subprocess
import tempfile
import shutil
from faster_whisper import WhisperModel

audio_path = sys.argv[1]
output_path = os.path.splitext(audio_path)[0] + ".txt"

# Modell large-v3-turbo, CPU + int8 fuer AMD-Surface
model = WhisperModel("large-v3-turbo", device="cpu", compute_type="int8")

# Audio in 10-Min-Chunks splitten um Speicher konstant zu halten
tmpdir = tempfile.mkdtemp(prefix="whisper_chunks_")
try:
    subprocess.run([
        "ffmpeg", "-y", "-i", audio_path,
        "-f", "segment", "-segment_time", "600",
        "-c", "copy", os.path.join(tmpdir, "chunk_%03d.mp3")
    ], check=True, capture_output=True)

    chunks = sorted(os.path.join(tmpdir, f) for f in os.listdir(tmpdir))

    with open(output_path, "w", encoding="utf-8") as out:
        for i, chunk in enumerate(chunks):
            print(f"Transkribiere Chunk {i+1}/{len(chunks)}...", file=sys.stderr)
            segments, _ = model.transcribe(chunk, language="de", beam_size=5)
            for seg in segments:
                out.write(seg.text.strip() + " ")
            out.write("\n")
            os.remove(chunk)

    print(f"OK: {output_path}")
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
