#!/usr/bin/env python3
"""Type-check production source under strict mode with minimal platform boundaries."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--analyzer", default="luau-analyze")
args = parser.parse_args()
prelude = """--!strict
local game: any = nil
local task: any = nil
local warn = function(...: any) end
"""
source = (root / "GuardUtilsRoblox.lua").read_text(encoding="utf-8")
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / "GuardUtilsRoblox.luau"
    script.write_text(prelude + source, encoding="utf-8")
    subprocess.run([args.analyzer, str(script)], check=True)
