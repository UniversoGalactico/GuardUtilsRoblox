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
local typeof = function(value)
    if type(value) == "table" and rawget(value, "_fakeInstance") then return "Instance" end
    return type(value)
end
local http = {GenerateGUID = function() serial += 1; return "guid-" .. serial end}
local game = {GetService = function(_, name)
    if name == "Players" then return players end
    if name == "HttpService" then return http end
    error("unexpected service " .. name)
end}
-- Deterministic cooperative watchdog scheduler. Not Roblox's real task scheduler.
local scheduled = {}
local function resumeScheduled(thread)
    local ok, delay = coroutine.resume(thread)
    assert(ok, delay)
    if coroutine.status(thread) == "suspended" then
        assert(type(delay) == "number" and delay > 0, "invalid simulated wait")
        table.insert(scheduled, {thread = thread, wake = clock + delay})
    end
end
local function resetScheduler()
    for _, job in ipairs(scheduled) do
        if coroutine.status(job.thread) == "suspended" then coroutine.close(job.thread) end
    end
    table.clear(scheduled)
end
local function advanceScheduler(target)
    assert(target >= clock)
    while true do
        local best
        for i, job in ipairs(scheduled) do
            if job.wake <= target and (not best or job.wake < scheduled[best].wake) then best = i end
        end
        if not best then break end
        local job = table.remove(scheduled, best)
        clock = math.max(clock, job.wake)
        resumeScheduled(job.thread)
    end
    clock = target
end
local task = {
    spawn = function(fn)
        local thread = coroutine.create(fn)
        resumeScheduled(thread)
        return thread
    end,
    cancel = function(thread)
        for i = #scheduled, 1, -1 do
            if scheduled[i].thread == thread then table.remove(scheduled, i) end
        end
        if coroutine.status(thread) == "suspended" then coroutine.close(thread) end
    end,
    wait = function(duration) return coroutine.yield(duration) end,
}
local warn = function(...) end
local Guard = (function()
'''
source = (root / "GuardUtilsRoblox.lua").read_text(encoding="utf-8")
tests = (root / "tests/regression.luau").read_text(encoding="utf-8")
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / "guardutils-test.luau"
    script.write_text(prefix + source + "\nend)()\n" + tests, encoding="utf-8")
    subprocess.run([args.luau, str(script)], check=True)
