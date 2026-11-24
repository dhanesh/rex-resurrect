-- rex-resurrect background saver.
--   rex --autostart=false do ~/.config/rex/resurrect/daemon.lua --all
-- Started by launchd/systemd through resurrectd.sh. Exits when the server
-- goes away; the supervisor starts it again once the server is back.
--
-- Cost model: events only mark things dirty. A save runs at most every
-- min_save_interval seconds, re-reads only dirty sessions/panes, and touches
-- the disk only when the snapshot's content actually changed.
local here = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_dir = here:match("^(.*)/[^/]+$") or "."
package.path = (plugin_dir:match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path

local util = require("resurrect.util")
local commands = require("resurrect.commands")
local snapshot = require("resurrect.snapshot")

local cfg, store = commands.context()
local meta = snapshot.server_meta()
if not meta.instance_id then
  util.log("error", "cannot read server status; exiting so the supervisor retries")
  rex.stop(1)
end

local paths = {
  prompt_sh = plugin_dir .. "/prompt.sh",
  ctl = plugin_dir .. "/ctl.lua",
  rex_bin = os.getenv("REX_RESURRECT_REX") or "rex",
  server = os.getenv("REX_SERVER"),
}

-- 1. Before saving anything, deal with a possible server restart: the
--    snapshot from before it is frozen as pending.json first.
local ok, outcome = pcall(commands.on_server_start, cfg, store, meta, paths)
util.log(ok and "info" or "error", "startup: " .. tostring(outcome))

-- 2. Incremental saving.
-- Mutable state lives in a table on purpose: in Rex's Lua runtime, a Lua
-- error caught by pcall can detach an enclosing function's view of a local
-- that closures assign to. Table fields are not affected.
local tracker = snapshot.tracker(cfg)
local S = { timer = nil, last_save = 0, last_key = nil }
do
  local last = store:read_json("last.json")
  S.last_key = last and snapshot.content_key(last) or nil
end

local function flush()
  S.timer = nil
  S.last_save = os.time()
  local fok, err = pcall(function()
    local rok, rerr = tracker:refresh()
    if not rok then error(rerr) end
    S.last_key = commands.commit(cfg, store, tracker:snapshot(meta), S.last_key)
  end)
  if not fok then util.log("warn", "save skipped: " .. tostring(err)) end
end

local function schedule()
  if S.timer then return end
  local wait = math.max(cfg.save_debounce, S.last_save + cfg.min_save_interval - os.time())
  S.timer = rex.after(wait, flush)
end

local function handler(fn)
  return function(ev)
    local hok, err = pcall(fn, ev or {})
    if not hok then util.log("warn", "event handler: " .. tostring(err)) end
  end
end

rex.on("session_created", handler(function() tracker:mark_list(); schedule() end))
rex.on("session_destroyed", handler(function() tracker:mark_list(); schedule() end))
rex.on("session_moved", handler(function() tracker:mark_list(); schedule() end))
-- Window/pane creation, closing, moves, splits, labels and focus all end in
-- a session_view_changed for that session.
rex.on("session_view_changed", handler(function(ev) tracker:mark_session(ev.session_id); schedule() end))
rex.on("com.superlogical.terminal.pwd_changed", handler(function(ev) tracker:mark_block(ev.block_id); schedule() end))
rex.on("com.superlogical.terminal.process_changed", handler(function(ev) tracker:mark_block(ev.block_id); schedule() end))

-- Safety net for anything an event did not tell us (e.g. dropped events).
rex.every(cfg.resync_interval, handler(function() tracker:mark_all(); schedule() end))

tracker:mark_all()
flush()
util.log("info", string.format("saving to %s (every change, at most every %ds; full resync every %ds)",
  cfg.state_dir, cfg.min_save_interval, cfg.resync_interval))
