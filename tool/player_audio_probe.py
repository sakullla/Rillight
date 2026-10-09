"""Compare owned IEC bursts against FFmpeg using disposable generated audio."""
import argparse
import json
from pathlib import Path
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=Path("build/audio-passthrough"))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    ffprobe = args.ffmpeg.with_name("ffprobe.exe" if args.ffmpeg.suffix == ".exe" else "ffprobe")
    for codec in ("ac3", "eac3", "dts", "truehd"):
        for rate in ((44100, 48000) if codec != "truehd" else (48000, 96000)):
            for channels in (2, 6):
                stem = args.out / f"{codec}-{rate}-{channels}"
                media = stem.with_suffix("." + codec)
                encoder = "dca" if codec == "dts" else codec
                subprocess.run([str(args.ffmpeg), "-v", "error", "-y", "-f", "lavfi",
                                "-i", f"sine=frequency=440:sample_rate={rate}:duration=0.25",
                                "-ac", str(channels), "-c:a", encoder, "-strict", "-2", "-f", codec, str(media)], check=True)
                packets = json.loads(subprocess.check_output([
                    str(ffprobe), "-v", "error", "-f", codec, "-show_packets", "-show_data", "-of", "json", str(media)]))["packets"]
                records = stem.with_suffix(".packets")
                with records.open("wb") as output:
                    for packet in packets:
                        data = bytes.fromhex("".join(
                            line.split(":", 1)[1].split("  ")[0].replace(" ", "")
                            for line in packet["data"].splitlines() if ":" in line))
                        assert len(data) == int(packet["size"])
                        output.write(struct.pack("<I", len(data)))
                        output.write(data)
                actual, reference = stem.with_suffix(".actual"), stem.with_suffix(".reference")
                subprocess.run([str(args.probe), codec, str(records), str(actual)], check=True)
                subprocess.run([str(args.ffmpeg), "-v", "error", "-y", "-f", codec, "-i", str(media),
                                "-c:a", "copy", "-f", "spdif", str(reference)], check=True)
                assert actual.read_bytes() == reference.read_bytes(), f"IEC mismatch: {stem.name}"
                print(f"{stem.name}: {actual.stat().st_size} bytes match FFmpeg", flush=True)


if __name__ == "__main__":
    main()
