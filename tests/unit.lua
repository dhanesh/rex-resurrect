-- Unit tests for the pure parts of rex-resurrect.
-- Run with: rex do tests/unit.lua   (uses Rex's own Lua 5.1 runtime)
local here = debug.getinfo(1, "S").source:gsub("^@", "")
local root = here:match("^(.*)/tests/[^/]+$") or "."
package.path = root .. "/?.lua;" .. package.path

local util = require("resurrect.util")
local config = require("resurrect.config")
local programs = require("resurrect.programs")
local snapshot = require("resurrect.snapshot")
local plan = require("resurrect.plan")
local restore = require("resurrect.restore")

-- Counters live in a table: Rex's Lua runtime can detach a local that a
-- closure assigns to once a Lua error has been caught by pcall.
local R = { passed = 0, failed = {} }
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then R.passed = R.passed + 1 else R.failed[#R.failed + 1] = name .. ": " .. tostring(err) end
end
local function eq(a, b, msg)
  local ea, eb = rex.json.encode(a), rex.json.encode(b)
  if ea ~= eb then error((msg or "") .. " expected " .. eb .. " got " .. ea, 2) end
end

local cfg = config.merge({})

test("shell_quote leaves plain words and quotes the rest", function()
  eq(util.shell_quote("nvim"), "nvim")
  eq(util.shell_quote("src/main.go"), "src/main.go")
  eq(util.shell_quote("my file"), "'my file'")
  eq(util.shell_quote("it's"), "'it'\\''s'")
  eq(util.shell_quote("$(rm -rf ~)"), "'$(rm -rf ~)'")
  eq(util.shell_quote(""), "''")
end)

test("file_url_to_path decodes OSC 7 URLs", function()
  eq(util.file_url_to_path("file://host.local/Users/me/a%20b"), "/Users/me/a b")
  eq(util.file_url_to_path("/plain/path"), "/plain/path")
  eq(util.file_url_to_path(nil), nil)
end)

test("short_time shows the real weekday (GopherLua %a is always 'mon')", function()
  -- 1970-01-01 was a Thursday; use noon so any timezone keeps the date.
  local s = util.short_time(12 * 3600)
  assert(s:sub(1, 3) == "Thu", "got " .. s)
end)

test("default window labels are recognised", function()
  eq(util.is_default_window_label("Window 72c5e6bb"), true)
  eq(util.is_default_window_label("editor"), false)
  eq(util.is_default_window_label(nil), true)
end)

test("config clamps numbers and rejects wrong types", function()
  local warnings = {}
  local c = config.merge({ min_save_interval = 0, resync_interval = "5", on_restart = "yolo", bogus = 1 },
    function(w) warnings[#warnings + 1] = w end)
  eq(c.min_save_interval, 1)
  eq(c.resync_interval, 300)
  eq(c.on_restart, "ask")
  eq(#warnings, 3)
end)

test("config extra/exclude programs", function()
  local c = config.merge({ extra_programs = { "ssh" }, exclude_programs = { "claude" } })
  eq(c.programs.ssh, true)
  eq(c.programs.claude, nil)
  eq(c.programs.nvim, true)
end)

local function proc(fg, shell_cwd)
  return { foreground = fg, ancestors = { { name = "zsh", argv0 = "-zsh", cwd = shell_cwd or "/home/u" } } }
end

test("identify: idle login shell", function()
  local id = programs.identify(proc({ name = "zsh", argv0 = "-zsh", cwd = "/w", pid = 5 }), cfg.programs)
  eq(id.idle, true); eq(id.cwd, "/w")
end)

test("identify: versioned binary matched by argv0", function()
  local id = programs.identify(proc({ name = "2.1.322", argv0 = "claude", path = "/x/versions/2.1.322", cwd = "/p", pid = 9 }), cfg.programs)
  eq(id.key, "claude"); eq(id.pid, 9); eq(id.cwd, "/p")
end)

test("identify: non-allowlisted program is not restorable", function()
  local id = programs.identify(proc({ name = "make", argv0 = "make", cwd = "/b", pid = 3 }), cfg.programs)
  eq(id.other, "make"); eq(id.key, nil)
end)

test("identify: missing foreground falls back to shell cwd", function()
  local id = programs.identify(proc(nil, "/s"), cfg.programs)
  eq(id.idle, true); eq(id.cwd, "/s")
end)

test("restore_argv: strategies", function()
  eq(programs.restore_argv({ key = "claude", argv = { "claude", "fix the bug" } }, "/p", cfg), { "claude", "--continue" })
  eq(programs.restore_argv({ key = "codex", argv = { "codex" } }, "/p", cfg), { "codex", "resume", "--last" })
  eq(programs.restore_argv({ key = "nvim", argv = { "nvim", "a.go" } }, "/nonexistent", cfg), { "nvim", "a.go" })
  eq(programs.restore_argv({ key = "tail", argv = { "tail", "-n", "5", "x.log" } }, "/", cfg), nil)
  eq(programs.restore_argv({ key = "tail", argv = { "tail", "-F", "x.log" } }, "/", cfg), { "tail", "-F", "x.log" })
end)

test("restore_argv: safety limits", function()
  eq(programs.restore_argv({ key = "make", argv = { "make", "deploy" } }, "/", cfg), nil, "not allowlisted")
  eq(programs.restore_argv({ key = "less", argv = { "less", "a\nrm -rf /" } }, "/", cfg), nil, "newline")
  local long = { "less" }
  for i = 1, 100 do long[#long + 1] = "f" .. i end
  eq(programs.restore_argv({ key = "less", argv = long }, "/", cfg), nil, "too many args")
  local off = config.merge({ restore_programs = false })
  eq(programs.restore_argv({ key = "less", argv = { "less", "x" } }, "/", off), nil, "disabled")
  local nostrat = config.merge({ strategies = { claude = false } })
  eq(programs.restore_argv({ key = "claude", argv = { "claude" } }, "/", nostrat), nil, "strategy=false")
  local broken = config.merge({ strategies = { less = function() error("boom") end } })
  eq(programs.restore_argv({ key = "less", argv = { "less", "x" } }, "/", broken), nil, "failing strategy")
end)

-- A window with a horizontal split whose right side is split vertically, and
-- one non-terminal block that must be dropped.
local view = {
  session_id = "session:1", label = "work", active_window_id = "window:2",
  windows = {
    { window_id = "window:1", label = "Window 0011aabb", focused_block_id = "block:b",
      layers = { { kind = "tiled", blocks = {
        { block_id = "block:a", creator_name = "com.superlogical.terminal", label = "shell" },
        { block_id = "block:b", creator_name = "com.superlogical.terminal", label = "logs" },
        { block_id = "block:c", creator_name = "com.superlogical.terminal", label = "shell" } },
        layout = { split = { direction = "horizontal", ratio = 0.6,
          before = { block_id = "block:a" },
          after = { split = { direction = "vertical", ratio = 0.5, before = { block_id = "block:b" }, after = { block_id = "block:c" } } } } } } } },
    { window_id = "window:2", label = "editor", focused_block_id = "block:d",
      layers = { { kind = "tiled", blocks = {
        { block_id = "block:d", creator_name = "com.superlogical.terminal", label = "shell" },
        { block_id = "block:x", creator_name = "com.superlogical.onboarding" } },
        layout = { split = { direction = "horizontal", ratio = 0.5, before = { block_id = "block:d" }, after = { block_id = "block:x" } } } } } },
    { window_id = "window:3", label = "only-onboarding",
      layers = { { kind = "tiled", blocks = { { block_id = "block:y", creator_name = "com.superlogical.onboarding" } },
        layout = { block_id = "block:y" } } } },
  },
}
local blocks = {
  ["block:a"] = { label = "shell", cwd = "/a" },
  ["block:b"] = { label = "logs", cwd = "/b", program = { key = "tail", argv = { "tail", "-f", "app.log" } } },
  ["block:c"] = { label = "shell", cwd = "/c" },
  ["block:d"] = { label = "shell", cwd = "/d", program = { key = "nvim", argv = { "nvim", "main.go" } } },
}

test("session_from_view keeps tree, drops non-terminal blocks and default labels", function()
  local s = snapshot.session_from_view(view, blocks)
  eq(#s.windows, 2, "window with only non-terminal blocks is dropped")
  eq(s.windows[1].label, nil)
  eq(s.windows[2].label, "editor")
  eq(s.windows[1].layout.split.ratio, 0.6)
  eq(s.windows[1].layout.split.after.split.before.block.cwd, "/b")
  eq(s.windows[2].layout.block.block_id, "block:d", "split around onboarding collapses")
  local n = 0
  snapshot.each_leaf(s.windows[1].layout, function() n = n + 1 end)
  eq(n, 3)
end)

test("create_request mirrors the layout and orders leaves like Rex", function()
  local s = snapshot.session_from_view(view, blocks)
  local req, leaves = restore.create_request(s, "work")
  eq(req.label, "work")
  eq(#req.initial_windows, 2)
  local w1 = req.initial_windows[1].layout
  eq(w1.split.direction, "horizontal")
  eq(w1.split.before.block.options.cwd, "/a")
  eq(w1.split.before.block.flavor, "com.superlogical.terminal.shell")
  eq(w1.split.after.split.after.block.options.cwd, "/c")
  eq(req.initial_windows[1].window_label, nil)
  eq(req.initial_windows[2].window_label, "editor")
  eq({ leaves[1].leaves[1].block_id, leaves[1].leaves[2].block_id, leaves[1].leaves[3].block_id }, { "block:a", "block:b", "block:c" })
end)

test("create_request never sends program commands as the pane process", function()
  local s = snapshot.session_from_view(view, blocks)
  local req = restore.create_request(s, "work")
  local text = rex.json.encode(req)
  eq(text:find("command") == nil, true)
  eq(text:find("nvim") == nil, true)
end)

test("plan: missing sessions and relaunch candidates", function()
  local s = snapshot.session_from_view(view, blocks)
  local gone = { session_id = "session:2", label = "gone", windows = s.windows }
  local snap = { saved_at = 1000, sessions = { s, gone } }
  local live = { { session_id = "session:1", label = "work", block_ids = { ["block:b"] = true, ["block:d"] = true } } }
  local probes = {}
  local function probe(_, bid)
    probes[#probes + 1] = bid
    if bid == "block:d" then return { idle = true } end
    return { key = "tail" } -- still running: must not be offered
  end
  local p = plan.build(snap, live, probe, cfg)
  eq(#p.missing, 1); eq(p.missing[1].label, "gone")
  eq(p.natively_restored, 1); eq(p.total, 2)
  eq(#p.relaunch, 1)
  eq(p.relaunch[1].block_id, "block:d")
  eq(p.relaunch[1].argv, { "nvim", "main.go" })
  eq(#probes, 2, "only allowlisted panes are probed")
  local text = plan.describe(p, 1000 + 7200)
  eq(text:find("gone", 1, true) ~= nil, true)
  eq(text:find("nvim main.go", 1, true) ~= nil, true)
  eq(text:find("2 h ago", 1, true) ~= nil, true)
end)

test("plan: matching by label when IDs changed", function()
  local s = snapshot.session_from_view(view, blocks)
  local p = plan.build({ sessions = { s } }, { { session_id = "session:new", label = "work", block_ids = {} } },
    function() return { idle = true } end, cfg)
  eq(#p.missing, 0); eq(#p.relaunch, 0)
  eq(plan.is_empty(p), true)
end)

test("plan: positional fallback when block IDs changed", function()
  local s = snapshot.session_from_view(view, blocks)
  local function tiled(layout) return { layers = { { kind = "tiled", layout = layout } } } end
  local live_view = { windows = {
    tiled({ split = { before = { block_id = "n:a" }, after = { split = { before = { block_id = "n:b" }, after = { block_id = "n:c" } } } } }),
    tiled({ block_id = "n:d" }),
  } }
  local live = { { session_id = "session:9", label = "work", block_ids = {}, view = live_view } }
  local p = plan.build({ sessions = { s } }, live, function() return { idle = true } end, cfg)
  eq(#p.relaunch, 2)
  eq(p.relaunch[1].block_id, "n:b"); eq(p.relaunch[1].argv, { "tail", "-f", "app.log" })
  eq(p.relaunch[2].block_id, "n:d"); eq(p.relaunch[2].session_id, "session:9")
  -- A window whose pane count changed is not guessed at.
  live_view.windows[1] = tiled({ split = { before = { block_id = "n:a" }, after = { block_id = "n:b" } } })
  p = plan.build({ sessions = { s } }, live, function() return { idle = true } end, cfg)
  eq(#p.relaunch, 1); eq(p.relaunch[1].block_id, "n:d")
end)

test("content_key ignores timestamps", function()
  local a = { saved_at = 1, sessions = { { session_id = "s", windows = {} } } }
  local b = { saved_at = 2, sessions = { { session_id = "s", windows = {} } } }
  eq(snapshot.content_key(a), snapshot.content_key(b))
end)

test("regression: runtime keeps table state across caught errors", function()
  local st = { n = 0 }
  local function inc() st.n = st.n + 1 end
  for i = 1, 5 do pcall(function() inc(); if i == 2 then pcall(error, "x") end end) end
  eq(st.n, 5)
end)

print(string.format("%d passed, %d failed", R.passed, #R.failed))
for _, f in ipairs(R.failed) do print("FAIL " .. f) end
if #R.failed > 0 then rex.stop(1) end
return { passed = R.passed, failed = #R.failed }
