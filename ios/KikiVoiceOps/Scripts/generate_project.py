#!/usr/bin/env python3
"""Synchronize files in the existing KikiVoiceOps project without rebuilding it.

Run after adding/removing files under Sources, Tests, Resources or Configuration.
Existing targets, UUIDs, build settings, versions and signing capabilities remain
unchanged. Requires Python 3 and macOS plutil; no third-party Python packages.
Use --check to verify project membership without writing any files.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "KikiVoiceOps.xcodeproj" / "project.pbxproj"
MANAGED_ROOTS = ("Sources", "Tests", "Resources", "Configuration", "Scripts")


def read_project() -> dict:
    if not PROJECT.is_file():
        raise ValueError("The existing KikiVoiceOps.xcodeproj is required; this tool does not recreate targets or signing settings.")
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(PROJECT)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def synchronize(project: dict) -> tuple[dict, dict[str, int]]:
    objects = project["objects"]
    root = objects[project["rootObject"]]
    main_group = objects[root["mainGroup"]]
    targets = {objects[key]["name"]: objects[key] for key in root["targets"]}
    app = targets["KikiVoiceOps"]
    tests = targets["KikiVoiceOpsTests"]
    groups: dict[str, str] = {}
    files: dict[str, str] = {}

    def walk(group_id: str, prefix: Path = Path()) -> None:
        group = objects[group_id]
        for child_id in group.get("children", []):
            child = objects[child_id]
            if child.get("sourceTree", "<group>") != "<group>":
                continue
            relative = prefix / child.get("path", "")
            if child["isa"] == "PBXGroup":
                groups[relative.as_posix()] = child_id
                walk(child_id, relative)
            elif child["isa"] == "PBXFileReference":
                files[relative.as_posix()] = child_id

    walk(root["mainGroup"])
    old_build_files = {
        value["fileRef"]: key for key, value in objects.items()
        if value["isa"] == "PBXBuildFile" and "fileRef" in value
    }

    def allocate(kind: str, path: str) -> str:
        suffix = 0
        while True:
            seed = f"kikivoiceops:{kind}:{path}:{suffix}"
            candidate = hashlib.sha256(seed.encode()).hexdigest()[:24].upper()
            if candidate not in objects:
                return candidate
            suffix += 1

    app_sources = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "Sources").rglob("*.swift"))
    test_sources = sorted(
        path.relative_to(ROOT).as_posix() for path in (ROOT / "Tests").rglob("*.swift")
        if not path.is_relative_to(ROOT / "Tests" / "Fixtures")
    )
    fixtures = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "Tests" / "Fixtures").rglob("*") if path.is_file())
    configuration = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "Configuration").rglob("*") if path.is_file() and not path.name.startswith("."))
    resources: list[str] = []
    for path in sorted((ROOT / "Resources").rglob("*")):
        if path.name.startswith(".") or any(part.endswith(".xcassets") for part in path.relative_to(ROOT / "Resources").parts[:-1]):
            continue
        if path.is_file() or path.suffix == ".xcassets":
            resources.append(path.relative_to(ROOT).as_posix())
    if not app_sources or not test_sources:
        raise ValueError("Sources and Tests must both contain Swift files; refusing to clear a target.")
    scripts = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "Scripts").rglob("*") if path.is_file() and path.suffix in {".py", ".swift", ".sh", ".rb"})
    expected = set(app_sources + test_sources + fixtures + configuration + resources + scripts)
    desired_children: dict[str, list[str]] = {}

    def ensure_group(relative: str) -> str:
        if relative == ".":
            return root["mainGroup"]
        if relative in desired_children:
            return groups[relative]
        parent = Path(relative).parent.as_posix()
        parent_id = ensure_group(parent)
        group_id = groups.get(relative)
        if group_id is None:
            group_id = allocate("group", relative)
            groups[relative] = group_id
            objects[group_id] = {"isa": "PBXGroup", "path": Path(relative).name, "sourceTree": "<group>", "children": []}
        desired_children[relative] = []
        if parent != ".":
            desired_children[parent].append(group_id)
        return group_id

    for name in MANAGED_ROOTS:
        ensure_group(name)
    types = {
        ".swift": "sourcecode.swift", ".json": "text.json", ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements", ".xcprivacy": "text.xml",
        ".xcassets": "folder.assetcatalog", ".png": "image.png", ".jpg": "image.jpeg",
        ".jpeg": "image.jpeg", ".xcconfig": "text.xcconfig",
        ".py": "text.script.python", ".sh": "text.script.sh", ".rb": "text.script.ruby",
    }
    expected_refs: dict[str, str] = {}
    for relative in sorted(expected):
        parent = Path(relative).parent.as_posix()
        ensure_group(parent)
        file_id = files.get(relative)
        if file_id is None:
            file_id = allocate("file", relative)
            objects[file_id] = {"isa": "PBXFileReference", "path": Path(relative).name, "sourceTree": "<group>", "lastKnownFileType": types.get(Path(relative).suffix, "file")}
        expected_refs[relative] = file_id
        desired_children[parent].append(file_id)

    for relative, children in desired_children.items():
        objects[groups[relative]]["children"] = sorted(children, key=lambda key: (objects[key]["isa"] != "PBXGroup", objects[key].get("path", objects[key].get("name", "")).casefold()))
    unmanaged = [key for key in main_group["children"] if objects[key].get("path") not in MANAGED_ROOTS]
    main_group["children"] = [groups[name] for name in MANAGED_ROOTS] + unmanaged

    def build_file(relative: str) -> str:
        reference = expected_refs[relative]
        build_id = old_build_files.get(reference)
        if build_id is None:
            build_id = allocate("build", relative)
            objects[build_id] = {"isa": "PBXBuildFile", "fileRef": reference}
        return build_id

    def set_phase(target: dict, kind: str, paths: list[str]) -> None:
        phases = [objects[key] for key in target["buildPhases"] if objects[key]["isa"] == kind]
        if len(phases) != 1:
            raise ValueError(f"Expected exactly one {kind} in {target['name']}")
        phases[0]["files"] = [build_file(path) for path in paths]

    set_phase(app, "PBXSourcesBuildPhase", app_sources)
    set_phase(tests, "PBXSourcesBuildPhase", test_sources)
    set_phase(app, "PBXResourcesBuildPhase", resources)
    set_phase(tests, "PBXResourcesBuildPhase", fixtures)

    # Drop only objects detached by the managed file/group membership update.
    reachable: set[str] = set()
    def visit(value) -> None:
        if isinstance(value, str) and value in objects and value not in reachable:
            reachable.add(value)
            visit(objects[value])
        elif isinstance(value, dict):
            for key, child in value.items():
                visit(key)
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(project["rootObject"])
    project["objects"] = {key: value for key, value in objects.items() if key in reachable}
    return project, {"app_sources": len(app_sources), "test_sources": len(test_sources), "resources": len(resources), "fixtures": len(fixtures)}


def serialize(value, indent: int = 0) -> str:
    if isinstance(value, dict):
        rows = ["{"]
        rows.extend("\t" * (indent + 1) + json.dumps(key, ensure_ascii=False) + " = " + serialize(value[key], indent + 1) + ";" for key in sorted(value))
        rows.append("\t" * indent + "}")
        return "\n".join(rows)
    if isinstance(value, list):
        rows = ["("]
        rows.extend("\t" * (indent + 1) + serialize(child, indent + 1) + "," for child in value)
        rows.append("\t" * indent + ")")
        return "\n".join(rows)
    if isinstance(value, bool):
        value = "1" if value else "0"
    return json.dumps(str(value), ensure_ascii=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check membership without writing the project")
    args = parser.parse_args()
    original = read_project()
    updated, counts = synchronize(deepcopy(original))
    if args.check:
        if original != updated:
            print("Project file membership is stale; run Scripts/generate_project.py to synchronize it.", file=sys.stderr)
            return 1
        print("Project membership is current:", counts)
        return 0
    if original != updated:
        content = "// !$*UTF8*$!\n" + serialize(updated) + "\n"
        temporary = PROJECT.with_suffix(".pbxproj.sync")
        try:
            temporary.write_text(content)
            subprocess.run(["plutil", "-lint", str(temporary)], check=True, capture_output=True)
            temporary.replace(PROJECT)
        finally:
            temporary.unlink(missing_ok=True)
    print("Synchronized existing project; target settings and identities preserved:", counts)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Project synchronization failed: {error}", file=sys.stderr)
        raise SystemExit(1)
