"""Check the reflection entry points that broke the 0.3 release APK."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
mapping = (root / "build/app/outputs/mapping/release/mapping.txt").read_text()
for name in ["com.google.mlkit.common.internal.CommonComponentRegistrar", "com.google.mlkit.vision.common.internal.VisionCommonRegistrar"]:
    match = re.search(r"^" + re.escape(name) + r" -> [^\n]+\n((?:[ #].*\n)*)", mapping, re.M)
    assert match and "<init>()" in match.group(1), f"Missing reflected constructor: {name}"
print("ML Kit registrar constructors retained in release")
