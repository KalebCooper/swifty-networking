#!/usr/bin/env python3
"""Check WebSocket source guards, dependency conditions and shared Swift safety settings."""

import copy
import json
from pathlib import Path
import re
import subprocess
import sys


def check(manifest, files):
    errors = []
    products = {p["name"] for p in manifest["products"]}
    required = {"WebSocketCore", "WebSocketHummingbird", "WebSocketPortable", "WebSocketURLSession"}
    if not required <= products:
        errors.append("Missing WebSocket products")
    traits = {t["name"]: t for t in manifest["traits"]}
    for name in ["default", "HTTPPortable", "Logging", "WebSocketHummingbird", "WebSocketPortable"]:
        if name not in traits or traits[name]["enabledTraits"]:
            errors.append(f"{name}: traits must be independent and default off")
    if manifest.get("swiftLanguageVersions") != ["6"]:
        errors.append("Swift 6 language mode is required")
    safety = [
        {"kind": {"defaultIsolation": {"_0": "nonisolated"}}, "tool": "swift"},
        {"kind": {"enableUpcomingFeature": {"_0": "NonisolatedNonsendingByDefault"}}, "tool": "swift"},
        {"kind": {"strictMemorySafety": {}}, "tool": "swift"},
    ]
    targets = {t["name"]: t for t in manifest["targets"]}
    if not required | {"WebSocketCoreTests", "WebSocketTestSupport"} <= targets.keys():
        errors.append("Missing WebSocket targets")
    for name, target in targets.items():
        if any(setting not in target.get("settings", []) for setting in safety):
            errors.append(f"{name}: missing unconditional safety setting")
        for dependency in target["dependencies"]:
            if "product" in dependency:
                product, package, _, condition = dependency["product"]
                expected = None
                if package == "async-http-client":
                    expected = "HTTPPortable"
                elif package in {"hummingbird", "hummingbird-websocket", "swift-websocket"}:
                    expected = "WebSocketHummingbird"
                elif package in {"swift-nio", "swift-nio-ssl"}:
                    expected = ("HTTPPortable" if name.startswith("HTTPPortable") else
                                "WebSocketHummingbird" if name.startswith("WebSocketHummingbird") else
                                "WebSocketPortable")
                if expected and (condition or {}).get("traits") != [expected]:
                    errors.append(f"{name}/{product}: missing independent {expected} guard")
                if name == "WebSocketHummingbird" and package.startswith("hummingbird"):
                    if set((condition or {}).get("platformNames", [])) != {"linux", "macos"}:
                        errors.append("Server framework edges must be Linux/macOS only")
            else:
                edge = next(iter(dependency.values()))[0]
                if name == "HTTPCore" and edge.startswith("WebSocket"):
                    errors.append("HTTPCore must not depend on WebSocket targets")
                if name.startswith("WebSocketHummingbird") and edge == "WebSocketPortable":
                    errors.append("The server adapter must not depend on the portable client")
    for product in manifest["products"]:
        if "WebSocketTestSupport" in product["targets"]:
            errors.append("Shared test support must not be a product")

    for directory, guard in [
        ("WebSocketHummingbird", "WebSocketHummingbird"),
        ("WebSocketPortable", "WebSocketPortable"),
        ("WebSocketURLSession", "canImport(Darwin)"),
    ]:
        paths = [p for p in files if p.startswith(f"Sources/{directory}/")]
        if not paths:
            errors.append(f"{directory}: missing guard subject")
        paths += [p for p in files if p.startswith(f"Tests/{directory}Tests/")]
        for path in paths:
            if not enclosed(files[path], guard):
                errors.append(f"{path}: entire file must be guarded by {guard}")
    core = {p: c for p, c in files.items() if p.startswith("Sources/WebSocketCore/")}
    if not core or not any("#if canImport(FoundationEssentials)" in c for c in core.values()):
        errors.append("WebSocketCore: missing portable Foundation import subject")
    for path, contents in core.items():
        lines = contents.splitlines()
        for index, line in enumerate(lines):
            if re.match(r"\s*import Foundation$", line):
                if index == 0 or lines[index - 1] != "#else" or "#if canImport(FoundationEssentials)" not in contents:
                    errors.append(f"{path}: unguarded Foundation import")
    for path, contents in files.items():
        if not path.startswith("Tests/WebSocketTestSupport/"):
            continue
        if re.search(r"^\s*(?:@testable )?import (?:NIO\w*|Hummingbird\w*|WSCore)\b", contents, re.M):
            guard = "WebSocketHummingbird" if re.search(r"import (?:Hummingbird\w*|WSCore)\b", contents) else "WebSocketPortable"
            if not enclosed(contents, guard):
                errors.append(f"{path}: fixture imports need {guard}")
    return errors


def enclosed(contents, guard):
    lines = [line.strip() for line in contents.splitlines() if line.strip() and not line.strip().startswith("//")]
    if not lines or lines[0] != f"#if {guard}" or lines[-1] != "#endif":
        return False
    depth = 0
    for index, line in enumerate(lines):
        if line.startswith("#if "):
            depth += 1
        elif line == "#endif":
            depth -= 1
            if depth == 0 and index != len(lines) - 1:
                return False
        elif depth == 1 and (line == "#else" or line.startswith("#elseif")):
            return False
    return depth == 0


def main():
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=root))
    files = {str(p.relative_to(root)): p.read_text() for base in ["Sources", "Tests"]
             for p in (root / base).rglob("*.swift")}
    errors = check(manifest, files)
    if errors:
        raise SystemExit("\n".join(errors))
    if "--self-test" in sys.argv:
        cases = []
        for name in ["WebSocketPortable", "WebSocketHummingbird", "WebSocketTestSupport"]:
            broken = copy.deepcopy(manifest)
            target = next(t for t in broken["targets"] if t["name"] == name)
            target["dependencies"].append({"product": ["NIOCore", "swift-nio", None, None]})
            cases.append((f"unguarded {name} dependency", broken, files))
        broken = copy.deepcopy(manifest)
        next(t for t in broken["traits"] if t["name"] == "default")["enabledTraits"] = ["WebSocketPortable"]
        cases.append(("default-on trait", broken, files))
        broken = copy.deepcopy(manifest)
        next(t for t in broken["traits"] if t["name"] == "WebSocketHummingbird")["enabledTraits"] = ["WebSocketPortable"]
        cases.append(("coupled server trait", broken, files))
        broken = copy.deepcopy(manifest)
        next(t for t in broken["targets"] if t["name"] == "WebSocketCore")["settings"].pop()
        cases.append(("weakened safety", broken, files))
        broken = copy.deepcopy(manifest)
        broken["products"] = [p for p in broken["products"] if p["name"] != "WebSocketCore"]
        cases.append(("missing product", broken, files))
        for name in ["WebSocketPortable", "WebSocketHummingbird", "WebSocketURLSession"]:
            for base in [f"Sources/{name}", f"Tests/{name}Tests"]:
                changed = dict(files, **{f"{base}/Unguarded.swift": "import WebSocketCore\n"})
                cases.append((f"unguarded {base}", manifest, changed))
            changed = {p: c for p, c in files.items() if not p.startswith(f"Sources/{name}/")}
            cases.append((f"missing {name} source subject", manifest, changed))
        for path, contents in [
            ("Sources/WebSocketCore/Bad.swift", "import Foundation\n"),
            ("Tests/WebSocketTestSupport/Bad.swift", "import NIOCore\n"),
            ("Tests/WebSocketTestSupport/Bad.swift", "@testable import Hummingbird\n"),
            ("Sources/WebSocketPortable/Bad.swift", "#if WebSocketPortable\n#endif\nimport NIOCore\n"),
            ("Sources/WebSocketPortable/Bad.swift", "#if WebSocketPortable\n#else\nimport NIOCore\n#endif\n"),
        ]:
            cases.append((path, manifest, dict(files, **{path: contents})))
        for name, broken, changed in cases:
            if not check(broken, changed):
                raise SystemExit(f"Self-test missed {name}")
        print(f"PASS WebSocket guard self-test: clean tree and {len(cases)} planted violations")
    else:
        print("PASS WebSocket source guards, dependency conditions and safety settings")


if __name__ == "__main__":
    main()
