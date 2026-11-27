#!/usr/bin/env python3
"""Run actual module with deterministic Roblox service doubles."""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--luau", default="luau")
args = parser.parse_args()
prefix = r'''
local clock = 0
local os = {clock = function() return clock end}
local serial = 0
local players = {}
local http = {GenerateGUID = function() serial += 1; return "guid-" .. serial end}
local game = {GetService = function(_, name)
    if name == "Players" then return players end
    if name == "HttpService" then return http end
    error("unexpected service " .. name)
end}
local task = {spawn = function(_) end, wait = function() error("unexpected wait") end}
local warn = function(...) end
local Guard = (function()
'''
source = (root / "GuardUtilsRoblox.lua").read_text(encoding="utf-8")
tests = (root / "tests/regression.luau").read_text(encoding="utf-8")
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / "guardutils-test.luau"
    script.write_text(prefix + source + "\nend)()\n" + tests, encoding="utf-8")
    subprocess.run([args.luau, str(script)], check=True)
