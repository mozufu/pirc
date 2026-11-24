"""Refresh public, data-only pi-ai catalogs; never install or execute the package."""
import base64
import hashlib
import io
import json
from pathlib import Path
import tarfile
from urllib.request import urlopen
from urllib.parse import urlparse
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
FIELDS = ("id", "name", "api", "provider", "baseUrl", "reasoning", "input",
          "contextWindow", "maxTokens", "headers", "compat", "thinkingLevelMap", "cost")
APIS = {"anthropic-messages", "openai-completions", "openai-responses", "openai-codex-responses"}

def fetch(url):
    with urlopen(url, timeout=30) as response:
        data = response.read(20 * 1024 * 1024 + 1)
    if len(data) > 20 * 1024 * 1024:
        raise ValueError("Public catalog exceeded the download limit")
    return data

def refresh(version="latest"):
    """Pin `version` (a published pi-ai version, or "latest")."""
    metadata_url = f"https://registry.npmjs.org/@earendil-works%2fpi-ai/{version}"
    metadata = json.loads(fetch(metadata_url))
    url = metadata["dist"]["tarball"]
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "registry.npmjs.org":
        raise ValueError("Unexpected package host")
    data = fetch(url)
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode()
    if integrity != metadata["dist"]["integrity"]:
        raise ValueError("Package integrity mismatch")
    existing = json.loads((ROOT / "crates/pirc-providers/catalog.json").read_text())["providers"]
    providers, omitted = {}, {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for provider in existing:
            if provider in ("opencode", "opencode-go"):
                continue  # These use the separately verified live catalog.
            member = archive.extractfile(f"package/dist/providers/data/{provider}.json")
            if member is None:
                raise ValueError(f"Missing catalog for {provider}")
            groups = json.load(member)
            rows = [m for group in groups.values() for m in group.values() if m.get("type") == "chat"]
            selected = {}
            for model in rows:
                if model["api"] not in APIS:
                    omitted.setdefault(provider, []).append({"id": model["id"], "api": model["api"]})
                    continue
                if not model["id"] or model["provider"] != provider:
                    raise ValueError(f"Invalid model identity for {provider}")
                if model["contextWindow"] <= 0 or model["maxTokens"] <= 0:
                    raise ValueError("Invalid model limits")
                selected[model["id"]] = {key: model[key] for key in FIELDS if key in model}
            if not selected:
                raise ValueError(f"No supported models for {provider}")
            providers[provider] = list(selected.values())
    pin = {"package": metadata["name"], "version": metadata["version"],
           "updated": datetime.now(timezone.utc).date().isoformat(),
           "source": url, "integrity": integrity, "providers": providers, "omitted": omitted}
    destination = ROOT / "scripts/catalog/providers.json"
    # Like the embedded catalog, keep machine data compact, not thousands of diff lines.
    destination.write_text(json.dumps(pin, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Updated {len(providers)} provider catalogs from {pin['package']} {pin['version']}")

if __name__ == "__main__":
    import sys
    refresh(sys.argv[1] if len(sys.argv) > 1 else "latest")
