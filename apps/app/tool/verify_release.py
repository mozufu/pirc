#!/usr/bin/env python3
"""Verify a built pirc Android release APK without using signing secrets.

Checks the production manifest, the ML Kit reflected constructors that R8 must
retain, and that every signer certificate matches the configured identity. Only
public values (package name, version and certificate digest) are printed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
from pathlib import Path

APP_IDS = {
    "standard": "org.mozufu.pirc",
    "tailscale": "org.mozufu.pirc.tailscale",
}
ML_KIT_REGISTRARS = [
    "com.google.mlkit.common.internal.CommonComponentRegistrar",
    "com.google.mlkit.vision.common.internal.VisionCommonRegistrar",
]


def fail(message: str) -> None:
    raise SystemExit(message)


def run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if result.returncode:
        fail(f"{' '.join(command)} failed:\n{output}")
    return output


def build_tool(sdk_root: Path, name: str) -> Path:
    build_tools = sdk_root / "build-tools"
    if not build_tools.is_dir():
        fail(f"Missing Android build-tools under {sdk_root}")
    versions = sorted(
        (path for path in build_tools.iterdir() if path.is_dir()),
        key=lambda path: [
            int(part) if part.isdigit() else 0 for part in re.split(r"[.-]", path.name)
        ],
    )
    for version in reversed(versions):
        tool = version / name
        if tool.is_file():
            return tool
    fail(f"Android build-tools has no {name} under {sdk_root}")


def verify_signing(apksigner: Path, apk: Path, cert_der: Path) -> str:
    expected = hashlib.sha256(cert_der.read_bytes()).hexdigest()
    output = run([str(apksigner), "verify", "--print-certs", str(apk)])
    actual = {
        digest.lower()
        for digest in re.findall(r"certificate SHA-256 digest: ([0-9a-fA-F]+)", output)
    }
    if actual != {expected}:
        fail(
            "APK signing certificate does not match configured identity:\n"
            + output
            + "expected certificate SHA-256: "
            + expected
        )
    return expected


def verify_manifest(aapt2: Path, apk: Path, flavor: str) -> tuple[str, str, str]:
    badging = run([str(aapt2), "dump", "badging", str(apk)])
    package = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    version_code = re.search(r"^package: .* versionCode='([^']+)'", badging, re.MULTILINE)
    version_name = re.search(r"^package: .* versionName='([^']+)'", badging, re.MULTILINE)
    if not package or package.group(1) != APP_IDS[flavor]:
        fail(f"Expected package {APP_IDS[flavor]}, got {package.group(1) if package else 'none'}")
    if re.search(r"^application-debuggable$", badging, re.MULTILINE):
        fail("Release APK is debuggable")

    manifest = run([str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)])
    if "android:debuggable" in manifest:
        fail("Release manifest declares android:debuggable")
    if "DebugOverlayReceiver" in manifest or "org.mozufu.pirc.debug.OVERLAY" in manifest:
        fail("Release manifest contains the debug-only overlay receiver")
    if "com.google.mlkit.vision.DEPENDENCIES" not in manifest or "barcode_ui" not in manifest:
        fail("Release manifest is missing the ML Kit barcode_ui dependency")

    return (
        package.group(1),
        version_name.group(1) if version_name else "unknown",
        version_code.group(1) if version_code else "unknown",
    )


def verify_mapping(mapping: Path) -> None:
    if not mapping.is_file():
        fail(f"Missing R8 mapping file: {mapping}")
    text = mapping.read_text()
    for name in ML_KIT_REGISTRARS:
        match = re.search(
            r"^" + re.escape(name) + r" -> [^\n]+\n((?:[ #].*\n)*)", text, re.MULTILINE
        )
        if not match or "<init>()" not in match.group(1):
            fail(f"Missing reflected ML Kit constructor in mapping: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--mapping", required=True, type=Path)
    parser.add_argument("--cert-der", required=True, type=Path)
    parser.add_argument("--flavor", required=True, choices=sorted(APP_IDS))
    args = parser.parse_args()

    for file in (args.apk, args.cert_der):
        if not file.is_file():
            fail(f"Missing file: {file}")
    sdk_root = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or "")
    if not sdk_root.is_dir():
        fail("ANDROID_HOME or ANDROID_SDK_ROOT must point at the Android SDK")

    apksigner = build_tool(sdk_root, "apksigner")
    aapt2 = build_tool(sdk_root, "aapt2")
    verify_mapping(args.mapping)
    digest = verify_signing(apksigner, args.apk, args.cert_der)
    package, version_name, version_code = verify_manifest(aapt2, args.apk, args.flavor)
    apk_digest = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    print(f"Verified {args.flavor} release APK: {package} {version_name} ({version_code})")
    print(f"APK SHA-256: {apk_digest}")
    print(f"Signing certificate SHA-256: {digest}")


if __name__ == "__main__":
    main()
