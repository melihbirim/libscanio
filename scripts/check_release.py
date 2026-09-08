"""Require matching stable package versions before release builds start."""
import json
import os
import re
import tomllib
from pathlib import Path


def check(python_project, node_package, tag=""):
    if python_project["name"] != "libscanio" or node_package["name"] != "libscanio":
        raise ValueError("Both package names must be libscanio")
    version = python_project["version"]
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Release workflow supports stable X.Y.Z versions only")
    if version != node_package["version"]:
        raise ValueError("Python and npm package versions must match")
    if tag and tag != f"v{version}":
        raise ValueError(f"Release tag must be v{version}, got {tag!r}")
    return version


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    python_project = tomllib.loads((root / "python/pyproject.toml").read_text())["project"]
    node_package = json.loads((root / "node/package.json").read_text())
    tag = os.environ.get("RELEASE_TAG", "")
    if os.environ.get("GITHUB_EVENT_NAME") == "release":
        if not tag:
            raise ValueError("Release event is missing its tag")
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        if event["release"]["prerelease"]:
            raise ValueError("Prerelease publication is not configured")
    version = check(python_project, node_package, tag)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"version={version}\n")
    print(f"Validated libscanio {version}")
