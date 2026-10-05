"""Re-sign reviewable templates with Apple's Shortcuts CLI; no dependency install."""
import pathlib
import plistlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
for mode in ("打字", "语音"):
    name = "小当家截图" + mode
    source = plistlib.loads((root / "scripts/shortcuts" / (name + ".plist")).read_bytes())
    with tempfile.TemporaryDirectory() as temporary:
        unsigned = pathlib.Path(temporary) / (name + ".shortcut")
        unsigned.write_bytes(plistlib.dumps(source, fmt=plistlib.FMT_BINARY))
        subprocess.run([
            "shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned),
            "--output", str(root / "Butler/Resources" / (name + ".shortcut")),
        ], check=True)
