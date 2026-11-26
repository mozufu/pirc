#!/usr/bin/env python3
'''Build the self-contained document scripting runtime without npm.

The LinkeDOM worker and its upstream metadata are vendored beside this script.
Running this file verifies the vendored source checksum and emits the Flutter
asset bundle plus separate license and provenance assets.
'''

from __future__ import annotations

import argparse
import hashlib
import json
import re

from generate_document_encoding_data import generate as generate_encoding_data
from build_document_canvas_text import generate as generate_canvas_text
from pathlib import Path


VERSION = "0.18.13"
URL_PONYFILL_SHA256 = (
    "e9b958e8601c9b91176d20e032cf3491048a22cba25d127e26ac0533edb75966"
)
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_VENDOR = (
    REPOSITORY_ROOT
    / "apps/android/tool/parity/vendor/linkedom-0.18.13"
)
WRAPPER = (
    REPOSITORY_ROOT
    / "apps/android/tool/parity/document_script_runtime_source.js"
)
FORM_VALIDATION = (
    REPOSITORY_ROOT
    / "apps/android/tool/parity/document_form_validation_source.js"
)
FETCH_RUNTIME = (
    REPOSITORY_ROOT / "apps/android/tool/parity/document_fetch_source.js"
)
BINARY_RUNTIME = (
    REPOSITORY_ROOT / "apps/android/tool/parity/document_binary_source.js"
)
OBJECT_URL_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_object_url_source.js"
FILE_TEXT_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_file_text_source.js"
FILE_READER_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_file_reader_source.js"
CANVAS_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_canvas_source.js"
POINTER_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_pointer_source.js"
IMAGES_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_images_source.js"
HISTORY_STATE_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_history_state_source.js"
HISTORY_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_history_source.js"
COOKIES_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_cookies_source.js"
STORAGE_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_storage_source.js"
MEDIA_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_media_source.js"
STYLESHEETS_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_stylesheets_source.js"
STORAGE_BRIDGE = REPOSITORY_ROOT / "apps/android/tool/parity/document_storage_bridge_source.js"
XHR_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_xhr_source.js"
URL_PONYFILL = (
    REPOSITORY_ROOT
    / "apps/android/tool/parity/vendor/core-js-url-3.50.0/url-ponyfill.js"
)
URL_VENDOR = REPOSITORY_ROOT / "apps/android/tool/parity/vendor/core-js-url-3.50.0"
ENCODING_VENDOR = REPOSITORY_ROOT / "apps/android/tool/parity/vendor/whatwg-encoding-20240918"
ENCODING_DATA = REPOSITORY_ROOT / "apps/android/tool/parity/document_encoding_data.js"
TEXT_ENCODER = REPOSITORY_ROOT / "apps/android/tool/parity/document_text_encoder_source.js"
TEXT_DECODER = REPOSITORY_ROOT / "apps/android/tool/parity/document_text_decoder_source.js"
MODULE_VENDOR = REPOSITORY_ROOT / "apps/android/tool/parity/vendor/acorn-8.18.0"
IMPORT_MAPS = REPOSITORY_ROOT / "apps/android/tool/parity/document_import_maps_source.js"
RESIZE_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_resize_observer_source.js"
MUTATION_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_mutation_observer_source.js"
LAYOUT_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_layout_source.js"
CLASSIC_IMPORTS = REPOSITORY_ROOT / "apps/android/tool/parity/document_classic_imports_source.js"
MODULE_COMPILER = REPOSITORY_ROOT / "apps/android/tool/parity/document_modules_compiler_source.js"
MODULE_RUNTIME = REPOSITORY_ROOT / "apps/android/tool/parity/document_modules_source.js"
ASSETS = REPOSITORY_ROOT / "apps/android/assets"


def fail(message: str) -> None:
    raise SystemExit("build_document_script_runtime.py: " + message)


def build(vendor: Path, output_dir: Path) -> tuple[Path, str]:
    package_path = vendor / "package.json"
    provenance_path = vendor / "provenance.json"
    license_path = vendor / "LICENSE"
    worker_path = vendor / "worker.js"

    try:
        package = json.loads(package_path.read_text(encoding="utf-8"))
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        worker = worker_path.read_text(encoding="utf-8")
        module_parser = (MODULE_VENDOR / "acorn.js").read_text(encoding="utf-8")
        module_license = (MODULE_VENDOR / "LICENSE").read_text(encoding="utf-8")
        module_provenance = json.loads((MODULE_VENDOR / "provenance.json").read_text())
        module_compiler = MODULE_COMPILER.read_text(encoding="utf-8")
        classic_imports = CLASSIC_IMPORTS.read_text(encoding="utf-8")
        layout_runtime = LAYOUT_RUNTIME.read_text(encoding="utf-8")
        resize_runtime = RESIZE_RUNTIME.read_text(encoding="utf-8")
        mutation_runtime = MUTATION_RUNTIME.read_text(encoding="utf-8")
        import_maps = IMPORT_MAPS.read_text(encoding="utf-8")
        module_runtime = MODULE_RUNTIME.read_text(encoding="utf-8")
        wrapper = WRAPPER.read_text(encoding="utf-8")
        form_validation = FORM_VALIDATION.read_text(encoding="utf-8")
        binary_runtime = BINARY_RUNTIME.read_text(encoding="utf-8")
        fetch_runtime = FETCH_RUNTIME.read_text(encoding="utf-8")
        object_url_runtime = OBJECT_URL_RUNTIME.read_text(encoding="utf-8")
        file_text_runtime = FILE_TEXT_RUNTIME.read_text(encoding="utf-8")
        file_reader_runtime = FILE_READER_RUNTIME.read_text(encoding="utf-8")
        canvas_runtime = CANVAS_RUNTIME.read_text(encoding="utf-8")
        pointer_runtime = POINTER_RUNTIME.read_text(encoding="utf-8")
        images_runtime = IMAGES_RUNTIME.read_text(encoding="utf-8")
        xhr_runtime = XHR_RUNTIME.read_text(encoding="utf-8")
        history_state_runtime = HISTORY_STATE_RUNTIME.read_text(encoding="utf-8")
        history_runtime = HISTORY_RUNTIME.read_text(encoding="utf-8")
        cookies_runtime = COOKIES_RUNTIME.read_text(encoding="utf-8")
        storage_runtime = STORAGE_RUNTIME.read_text(encoding="utf-8")
        storage_bridge = STORAGE_BRIDGE.read_text(encoding="utf-8")
        stylesheets_runtime = STYLESHEETS_RUNTIME.read_text(encoding="utf-8")
        media_runtime = MEDIA_RUNTIME.read_text(encoding="utf-8")
        encoding_data = ENCODING_DATA.read_text(encoding="utf-8")
        text_encoder = TEXT_ENCODER.read_text(encoding="utf-8")
        text_decoder = TEXT_DECODER.read_text(encoding="utf-8")
        encoding_license = (ENCODING_VENDOR / "LICENSE").read_text(encoding="utf-8")
        encoding_provenance = json.loads((ENCODING_VENDOR / "provenance.json").read_text())
        url_ponyfill = URL_PONYFILL.read_text(encoding="utf-8")
        core_js_license = (URL_VENDOR / "LICENSE.core-js").read_text(encoding="utf-8")
        esbuild_license = (URL_VENDOR / "LICENSE.esbuild").read_text(encoding="utf-8")
        third_party_text = (vendor / "THIRD_PARTY.txt").read_text(encoding="utf-8")
        license_text = license_path.read_text(encoding="utf-8")
    except OSError as error:
        fail("could not read vendored input: " + str(error))
    except json.JSONDecodeError as error:
        fail("invalid vendored metadata: " + str(error))

    if hashlib.sha256(module_parser.encode("utf-8")).hexdigest() != module_provenance.get("acornSha256"):
        fail("vendored Acorn parser checksum does not match provenance")
    if hashlib.sha256(module_license.encode("utf-8")).hexdigest() != module_provenance.get("licenseSha256"):
        fail("vendored Acorn license checksum does not match provenance")
    for label, source in [("module compiler", module_compiler), ("module runtime", module_runtime), ("classic imports", classic_imports), ("import maps", import_maps)]:
        if not source.strip() or re.search(r"(?m)^\s*(import|export)\s", source):
            fail(label + " must be nonempty with no imports or exports")

    if package.get("name") != "linkedom" or package.get("version") != VERSION:
        fail("expected LinkeDOM " + VERSION + " package metadata")
    if package.get("license") != "ISC":
        fail("expected the upstream ISC license")
    if provenance.get("version") != VERSION:
        fail("provenance version does not match " + VERSION)

    digest = hashlib.sha256(worker.encode("utf-8")).hexdigest()
    if digest != provenance.get("workerSha256"):
        fail("vendored worker checksum does not match provenance.json")
    if re.search(r"(?m)^\s*import\s", worker):
        fail("worker.js contains an import; expected the no-import worker build")

    mutation_patch_path = Path(__file__).resolve().parent / "document_linkedom_mutation_patches.json"
    mutation_patches = json.loads(mutation_patch_path.read_text(encoding="utf-8"))
    for patch in mutation_patches["patches"]:
        if worker.count(patch["before"]) != 1:
            fail("LinkeDOM mutation patch does not match: " + patch["name"])
        worker = worker.replace(patch["before"], patch["after"], 1)

    export_position = worker.rfind("\nexport {")
    if export_position < 0:
        fail("could not find the final LinkeDOM export statement")
    export_statement = worker[export_position + 1 :].strip()
    if not export_statement.startswith("export {") or not export_statement.endswith(";"):
        fail("the final LinkeDOM export statement has an unexpected shape")
    if "\n" in export_statement:
        fail("expected one final, single-line export statement")
    # Rollup output can contain comment lines ending in a single space. Strip
    # generated whitespace only after checksum validation so the emitted asset
    # stays clean without changing the recorded upstream artifact digest.
    worker_body = "\n".join(
        line.rstrip() for line in worker[:export_position].splitlines()
    ).rstrip()

    if not wrapper.strip():
        fail("runtime wrapper source is empty")
    if re.search(r"(?m)^\s*import\s", wrapper):
        fail("runtime wrapper must not add imports")
    if not form_validation.strip():
        fail("form validation helper source is empty")
    if re.search(r"(?m)^\s*import\s", form_validation):
        fail("form validation helper must not add imports")
    if re.search(r"(?m)^\s*export\s", form_validation):
        fail("form validation helper must not add exports")
    if not binary_runtime.strip() or re.search(r"(?m)^\s*(import|export)\s", binary_runtime):
        fail("binary runtime helper must be nonempty with no imports or exports")
    if not fetch_runtime.strip() or re.search(r"(?m)^\s*(import|export)\s", fetch_runtime):
        fail("fetch runtime helper must be nonempty with no imports or exports")
    for label, source in [("object URL", object_url_runtime), ("file text", file_text_runtime), ("file reader", file_reader_runtime)]:
        if not source.strip() or re.search(r"(?m)^\s*(import|export)\s", source):
            fail(label + " helper must be nonempty with no imports or exports")
    if not canvas_runtime.strip() or re.search(r"(?m)^\s*(import|export)\s", canvas_runtime):
        fail("canvas runtime helper must be nonempty with no imports or exports")
    for label, source in [("history state", history_state_runtime), ("history", history_runtime), ("cookies", cookies_runtime), ("Storage", storage_runtime), ("Storage bridge", storage_bridge), ("stylesheets", stylesheets_runtime), ("media", media_runtime), ("document layout", layout_runtime), ("resize observer", resize_runtime)]:
        if not source.strip() or re.search(r"(?m)^\s*(import|export)\s", source):
            fail(label + " helper must be nonempty with no imports or exports")
    if hashlib.sha256(url_ponyfill.encode("utf-8")).hexdigest() != URL_PONYFILL_SHA256:
        fail("vendored URL ponyfill checksum does not match provenance")
    if re.search(r"(?m)^\s*import\s", url_ponyfill):
        fail("URL ponyfill must not add imports")

    try:
        if encoding_data != generate_encoding_data():
            fail("generated encoding data is stale")
    except (OSError, ValueError, KeyError) as error:
        fail("could not verify encoding data: " + str(error))
    for label, source in [("encoding data", encoding_data), ("TextEncoder", text_encoder), ("TextDecoder", text_decoder)]:
        if not source.strip() or re.search(r"(?m)^\s*(import|export)\s", source):
            fail(label + " helper must be nonempty with no imports or exports")

    atob_shim = """  {
    if (typeof globalThis.atob !== 'function') {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      globalThis.atob = function(input) {
        const text = String(input).replace(/\\s/g, '');
        let output = '';
        let accumulator = 0;
        let bitCount = 0;
        for (let index = 0; index < text.length; index++) {
          const character = text.charAt(index);
          if (character === '=')
            break;
          const digit = alphabet.indexOf(character);
          if (digit < 0)
            throw new Error('Invalid base64 data');
          accumulator = (accumulator << 6) | digit;
          bitCount += 6;
          if (bitCount >= 8) {
            bitCount -= 8;
            output += String.fromCharCode((accumulator >>> bitCount) & 255);
          }
        }
        return output;
      };
    }
  }
"""

    bundle = (
        "/* Generated from LinkeDOM "
        + VERSION
        + " and core-js-pure 3.50.0; see document-script-runtime.LICENSE.txt and "
        + "document-script-runtime.provenance.json. */\n"
        + "(function (globalThis) {\n\"use strict\";\n"
        + atob_shim
        + url_ponyfill.rstrip()
        + "\n"
        + worker_body
        + "\n"
        + form_validation.rstrip()
        + "\n"
        + binary_runtime.rstrip()
        + "\n"
        + object_url_runtime.rstrip()
        + "\n"
        + fetch_runtime.rstrip()
        + "\n"
        + encoding_data.rstrip()
        + "\n"
        + text_encoder.rstrip()
        + "\n"
        + text_decoder.rstrip()
        + "\n"
        + file_text_runtime.rstrip()
        + "\n"
        + file_reader_runtime.rstrip()
        + "\n"
        + canvas_runtime.rstrip()
        + "\n"
        + pointer_runtime.rstrip()
        + "\n"
        + images_runtime.rstrip()
        + "\n"
        + xhr_runtime.rstrip()
        + "\n"
        + history_state_runtime.rstrip()
        + "\n"
        + history_runtime.rstrip()
        + "\n"
        + cookies_runtime.rstrip()
        + "\n"
        + storage_runtime.rstrip()
        + "\n"
        + storage_bridge.rstrip()
        + "\n"
        + media_runtime.rstrip()
        + "\n"
        + stylesheets_runtime.rstrip()
        + "\n"
        + "const pircModuleParser = (function() { const exports = {}; const module = {exports};\n"
        + module_parser.rstrip()
        + "\nreturn module.exports; })();\n"
        + import_maps.rstrip()
        + "\n"
        + classic_imports.rstrip()
        + "\n"
        + module_compiler.rstrip()
        + "\n"
        + module_runtime.rstrip()
        + "\n"
        + mutation_runtime.rstrip()
        + "\n"
        + resize_runtime.rstrip()
        + "\n"
        + layout_runtime.rstrip()
        + "\n"
        + wrapper.rstrip()
        + "\n})(globalThis);\n"
    )

    generate_canvas_text(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    url_third_party = (
        third_party_text.rstrip()
        + "\n\nURL and URLSearchParams ponyfill\n"
        + "Source: core-js-pure 3.50.0 (MIT), bundled with esbuild 0.28.2 (MIT).\n"
        + "Ponyfill SHA-256: "
        + URL_PONYFILL_SHA256
        + "\n\ncore-js-pure license\n\n"
        + core_js_license.rstrip()
        + "\n\n\nesbuild license (build tool)\n\n"
        + esbuild_license.rstrip()
        + "\n"
    )
    (output_dir / "document-script-runtime.THIRD_PARTY.txt").write_text(
        url_third_party + "\n\nWHATWG Encoding Standard tables\n"
        + "Sources: https://encoding.spec.whatwg.org/encodings.json and index-big5.txt\n"
        + "Generated numeric Big5 table and normalized encoding label map; upstream source portions BSD-3-Clause.\n\n"
        + encoding_license.rstrip() + "\n\nAcorn 8.18.0 (MIT)\n\n" + module_license.rstrip() + "\n", encoding="utf-8", newline="\n"
    )
    bundle_path = output_dir / "document-script-runtime.js"
    bundle_path.write_text(bundle, encoding="utf-8", newline="\n")
    (output_dir / "document-script-runtime.LICENSE.txt").write_text(
        license_text, encoding="utf-8", newline="\n"
    )
    output_provenance = dict(provenance)
    output_provenance["urlPonyfill"] = {
        "source": "core-js-pure@3.50.0 URL and URLSearchParams entry points",
        "builder": "esbuild@0.28.2",
        "sha256": URL_PONYFILL_SHA256,
        "packageLock": "apps/android/tool/parity/vendor/core-js-url-3.50.0/package-lock.json",
    }
    output_provenance["nativeMedia"] = {
        "helperSha256": hashlib.sha256(media_runtime.encode("utf-8")).hexdigest(),
        "browserOracle": "packages/pirc_render/test/fixtures/parity/document-media-chromium153.json",
    }
    output_provenance["nativeStylesheets"] = {
        "helperSha256": hashlib.sha256(stylesheets_runtime.encode("utf-8")).hexdigest(),
        "browserOracle": "packages/pirc_render/test/fixtures/parity/document-stylesheets-chromium153.json",
    }
    output_provenance["nativeStorage"] = {
        "helperSha256": hashlib.sha256(storage_runtime.encode("utf-8")).hexdigest(),
        "bridgeSha256": hashlib.sha256(storage_bridge.encode("utf-8")).hexdigest(),
        "browserOracle": "packages/pirc_render/test/fixtures/parity/document-storage-chrome155.json",
    }
    output_provenance["nativeCookies"] = {
        "source": "apps/android/tool/parity/document_cookies_source.js",
        "sha256": hashlib.sha256(cookies_runtime.encode("utf-8")).hexdigest(),
        "browserOracle": "packages/pirc_render/test/fixtures/parity/document-cookies-chrome155.json",
    }
    output_provenance["nativeMutationObserver"] = {
        "helperSha256": hashlib.sha256(mutation_runtime.encode("utf-8")).hexdigest(),
    }
    output_provenance["nativeMutationPatches"] = {
        "source": "apps/android/tool/parity/document_linkedom_mutation_patches.json",
        "sha256": hashlib.sha256(mutation_patch_path.read_bytes()).hexdigest(),
    }
    output_provenance["nativeResizeObserver"] = {"helperSha256": hashlib.sha256(resize_runtime.encode("utf-8")).hexdigest()}
    output_provenance["nativeLayout"] = {"helperSha256": hashlib.sha256(layout_runtime.encode("utf-8")).hexdigest()}
    output_provenance["nativeModules"] = {
        "parser": module_provenance,
        "compilerSha256": hashlib.sha256(module_compiler.encode("utf-8")).hexdigest(),
        "importMapsSha256": hashlib.sha256(import_maps.encode("utf-8")).hexdigest(),
        "classicImportsSha256": hashlib.sha256(classic_imports.encode("utf-8")).hexdigest(),
        "loaderSha256": hashlib.sha256(module_runtime.encode("utf-8")).hexdigest(),
    }
    output_provenance["encodingData"] = encoding_provenance
    output_provenance["encodingData"]["generatedSha256"] = hashlib.sha256(encoding_data.encode("utf-8")).hexdigest()
    (output_dir / "document-script-runtime.provenance.json").write_text(
        json.dumps(output_provenance, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return bundle_path, hashlib.sha256(bundle.encode("utf-8")).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--vendor-dir",
        type=Path,
        default=DEFAULT_VENDOR,
        help="vendored LinkeDOM 0.18.13 source directory",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ASSETS,
        help="Flutter assets directory",
    )
    args = parser.parse_args()
    bundle_path, digest = build(args.vendor_dir, args.output_dir)
    print("Wrote " + str(bundle_path))
    print("Bundle SHA-256: " + digest)


if __name__ == "__main__":
    main()
