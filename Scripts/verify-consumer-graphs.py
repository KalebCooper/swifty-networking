#!/usr/bin/env python3
"""Resolve fresh consumers and check optional stack isolation without changing the root lockfile."""

import argparse
import hashlib
import itertools
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    original_lock = (root / "Package.resolved").read_bytes()
    args.output.mkdir(parents=True, exist_ok=False)
    package = args.output / "swifty-networking"
    package.mkdir()
    shutil.copy2(root / "Package.swift", package / "Package.swift")
    shutil.copytree(root / "Sources", package / "Sources")
    shutil.copytree(root / "Tests", package / "Tests")
    cases = []
    traits = ["HTTPPortable", "Logging", "WebSocketPortable"]
    for size in range(4):
        for selected in itertools.combinations(traits, size):
            products = ["HTTPCore", "HTTPTesting", "WebSocketCore"]
            products += [name for name in selected if name != "Logging"]
            cases.append(("-".join(selected) or "default", selected, products))
    cases += [
        ("apple", [], ["HTTPURLSession", "WebSocketURLSession"]),
        ("server", ["WebSocketHummingbird"], ["WebSocketHummingbird"]),
        ("combined", traits + ["WebSocketHummingbird"],
         ["HTTPPortable", "HTTPTesting", "WebSocketHummingbird", "WebSocketPortable"]),
    ]
    reports = []
    try:
        for name, selected, products in cases:
            consumer = args.output / name
            (consumer / "Sources" / "Consumer").mkdir(parents=True)
            dependency = f'.package(path: {json.dumps(str(package))}, traits: {json.dumps(list(selected))})'
            edges = ", ".join(f'.product(name: "{p}", package: "swifty-networking")' for p in products)
            (consumer / "Package.swift").write_text(
                '// swift-tools-version:6.2\nimport PackageDescription\n'
                'let package = Package(name: "Consumer", platforms: [.macOS(.v26)], '
                f'dependencies: [{dependency}], targets: [.target(name: "Consumer", '
                f'dependencies: [{edges}])])\n'
            )
            (consumer / "Sources" / "Consumer" / "Consumer.swift").write_text(
                "".join(f"import {p}\n" for p in sorted(products))
            )
            with (consumer / "resolve.log").open("w") as log:
                subprocess.run(["swift", "package", "--package-path", str(consumer), "resolve"],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
            pins = json.loads((consumer / "Package.resolved").read_text())["pins"]
            identities = {pin["identity"] for pin in pins}
            has_http = "HTTPPortable" in selected
            has_server = "WebSocketHummingbird" in selected
            has_ws = "WebSocketPortable" in selected
            # Hummingbird's upstream resolution includes AsyncHTTPClient independently of our client.
            if not has_server:
                assert ("async-http-client" in identities) == has_http, (name, identities)
            elif has_http:
                assert "async-http-client" in identities, (name, identities)
            assert ("swift-nio" in identities) == (has_http or has_server or has_ws), (name, identities)
            assert ("swift-nio-ssl" in identities) == (has_http or has_server or has_ws), (name, identities)
            assert ("hummingbird" in identities) == has_server, (name, identities)
            assert ("hummingbird-websocket" in identities) == has_server, (name, identities)
            assert ("swift-log" in identities) == (has_http or has_server or "Logging" in selected), (name, identities)
            if not selected:
                assert identities == {"swift-http-types"}, (name, identities)
            reports.append({"case": name, "pins": pins, "products": products, "traits": list(selected)})
            print(f"PASS {name}: {len(pins)} resolved packages", flush=True)
    finally:
        assert (root / "Package.resolved").read_bytes() == original_lock, "Root lockfile changed"
        (args.output / "results.json").write_text(json.dumps({
            "cases": reports,
            "rootLockSHA256": hashlib.sha256(original_lock).hexdigest(),
        }, indent=2) + "\n")


if __name__ == "__main__":
    main()
