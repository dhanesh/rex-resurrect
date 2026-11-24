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
local scrollback = require("resurrect.scrollback")

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
local scroll = scrollback.saver(cfg, store)
if outcome ~= "same server" then scroll:hold_existing() end

-- 2. Incremental saving.
-- Mutable state lives in a table on purpose: in Rex's Lua runtime, a Lua
-- error caught by pcall can detach an enclosing function's view of a local
-- that closures assign to. Table fields are not affected.
local tracker = snapshot.tracker(cfg)
local S = { timer = nil, last_save = 0, last_key = nil, saved_at = nil, checked = 0 }
do
  local last = store:read_json("last.json")
  S.last_key = last and snapshot.content_key(last) or nil
  S.saved_at = last and last.saved_at
end

local function flush()
  S.timer = nil
  S.last_save = os.time()
  local fok, err = pcall(function()
    local rok, rerr = tracker:refresh()
    if not rok then error(rerr) end
    local snap = tracker:snapshot(meta)
    local unchanged = #snap.sessions > 0 and snapshot.content_key(snap) == S.last_key
    local key, wrote = commands.commit(cfg, store, snap, S.last_key)
    S.last_key = key
    if wrote then
      S.saved_at, S.checked = snap.saved_at, snap.saved_at
    elseif unchanged and S.saved_at
        and os.time() - S.checked >= cfg.confirm_interval then
      -- Nothing changed: note that the saved snapshot is still current.
      S.checked = os.time()
      commands.note_checked(store, S.saved_at, S.checked)
    end
    scroll:after_save(tracker)
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
-- A command starting or finishing (process_changed) is also when a block's
-- output is worth saving again.
local function block_event(ev) tracker:mark_block(ev.block_id); scroll:mark(ev.block_id); schedule() end
rex.on("com.superlogical.terminal.pwd_changed", handler(block_event))
rex.on("com.superlogical.terminal.process_changed", handler(block_event))

-- Safety net for anything an event did not tell us (e.g. dropped events).
rex.every(cfg.resync_interval, handler(function() tracker:mark_all(); scroll:mark_running(tracker); schedule() end))

-- Quick commands send no event; the shell hook's history file shows them.
rex.every(cfg.scrollback_poll, handler(function()
  if scroll:poll(tracker) then
    for bid in pairs(scroll.dirty) do tracker:mark_block(bid) end
    schedule()
  end
end))

-- Saved output of blocks that are long gone.
local function gc()
  local removed = scrollback.gc(cfg, store, tracker)
  if removed > 0 then util.log("info", string.format("removed saved output of %d closed blocks", removed)) end
end
rex.every(86400, handler(gc))

tracker:mark_all()
flush()
handler(gc)()
util.log("info", string.format("saving to %s (every change, at most every %ds; full resync every %ds)",
  cfg.state_dir, cfg.min_save_interval, cfg.resync_interval))
