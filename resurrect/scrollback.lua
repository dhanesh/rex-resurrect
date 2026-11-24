-- Saves the recent output of terminal blocks, so the shell hook
-- (resurrect/shell/) can print it again after Rex restarts.
--
-- Only blocks whose shell sourced the hook are saved: the hook creates
-- blocks/<id>/history, and that file is the opt-in. A block is captured only
-- after an event for it (a command started or finished, a cd), or on the
-- periodic resync while a command is still running in it, so an idle server
-- does no work. Full-screen programs (editors, pagers, TUIs) are skipped:
-- their screen is not output worth replaying.
--
-- Files in state_dir/blocks/<block id>/:
--   history               commands typed in the block (written by the shell hook)
--   scrollback            latest output (written here; first line is a header)
--   *.restore             history/output handed over to a block rebuilt with a new id
--   scrollback.shown      being printed by the shell hook (deleted after)
local util = require("resurrect.util")

local M = {}
M.HEADER = "rex-resurrect-scrollback"
M.BANNER_START = "── output from before Rex restarted"  -- printed by resurrect/shell/*
M.BANNER_END = "── end of restored output ──"
M.HOLD_SECONDS = 600
local ALT_SCREEN = { [47] = true, [1047] = true, [1049] = true }

function M.root(cfg) return cfg.state_dir .. "/blocks" end

-- "block:01a1…" -> "01a1…"; nil for anything that isn't a plain id, so an id
-- can never turn into a path outside blocks/.
function M.block_id(bid)
  local id = tostring(bid or ""):gsub("^block:", "")
  if id:match("^[0-9a-f][0-9a-f%-]*$") then return id end
  return nil
end

function M.block_dir(cfg, bid)
  local id = M.block_id(bid)
  return id and (M.root(cfg) .. "/" .. id) or nil
end

-- Plain text only: control characters, including escape sequences, are
-- removed so replaying can never change titles, the clipboard or modes.
-- Keeps the last max_lines lines; drop_last removes the final non-blank line
-- (the prompt, when the capture was taken at an idle shell).
function M.clean(text, max_lines, drop_last)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("[%z\1-\8\11-\31\127]", ""):gsub("\194[\128-\159]", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("%s+$", "")
    -- The hook's own banners around replayed output: the output stays, so it
    -- carries over the next restart, but the banners must not pile up.
    if not (line:find(M.BANNER_START, 1, true) == 1 or line == M.BANNER_END) then lines[#lines + 1] = line end
  end
  local function trim_blank()
    while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  end
  trim_blank()
  if drop_last and #lines > 0 then
    table.remove(lines)
    trim_blank()
  end
  local first = math.max(1, #lines - max_lines + 1)
  return table.concat(lines, "\n", first, #lines)
end

-- The last max_bytes of a block's output as plain text. format returns the
-- start of a long output, so the tail is read from the result it leaves
-- behind, and the first, partial line is dropped.
function M.read_tail(sid, bid, max_bytes)
  local r, err = util.block_call(sid, bid, "format", { format = "text", trim = true, unwrap = true, max_bytes = max_bytes })
  if not r then return nil, err end
  if not r.id then return r.content or "" end
  local total = tonumber(r.total) or 0
  local t, terr = util.block_call(sid, bid, "blob_read", { id = r.id, offset = math.max(0, total - max_bytes), max_bytes = max_bytes })
  if not t then return nil, terr end
  return ((t.data or ""):match("\n(.*)$")) or ""
end

function M.full_screen(sid, bid)
  local r = util.block_call(sid, bid, "modes")
  local list = r and (r.modes or r) or {}
  for _, m in ipairs(list) do
    if type(m) == "table" and ALT_SCREEN[m.number] and m.set then return true end
  end
  return false
end

local Saver = {}
Saver.__index = Saver

function M.saver(cfg, store)
  return setmetatable({ cfg = cfg, store = store, dirty = {}, cache = {}, sizes = {}, hold = {}, hold_until = 0, all = true }, Saver)
end

function Saver:enabled() return self.cfg.scrollback_lines > 0 end
function Saver:mark(bid) if bid then self.dirty[bid] = true end end

-- On the periodic resync: blocks still running a command may have printed
-- more without any event saying so.
function Saver:mark_running(tracker)
  for bid, entry in pairs(tracker.blocks) do
    if entry.running then self.dirty[bid] = true end
  end
end

-- Rex sends no event for a quick command (echo, ls, git status), but the
-- shell hook appends every command to the block's history file. A block
-- whose history file grew has run something since the last look. Costs one
-- open and seek per hooked block, and no writes. Returns true if any grew.
function Saver:poll(tracker)
  if not self:enabled() then return false end
  local any = false
  for bid in pairs(tracker.blocks) do
    local dir = M.block_dir(self.cfg, bid)
    local f = dir and io.open(dir .. "/history", "r")
    if f then
      local size = f:seek("end")
      f:close()
      if size ~= self.sizes[bid] then
        -- Includes the first look at a block: commands may already have run.
        self.dirty[bid], any = true, true
        self.sizes[bid] = size
      end
    end
  end
  return any
end

-- After a server restart, output saved before it must survive until the
-- block's shell has replayed it (the shell renames the file), even if the
-- saver starts first and sees the block's new, nearly empty screen.
function Saver:hold_existing()
  local ok, res = pcall(rex.exec, { "ls", M.root(self.cfg) })
  if not ok or type(res) ~= "table" or res.code ~= 0 then return end
  for id in tostring(res.stdout or ""):gmatch("[^\n]+") do
    if M.block_id(id) == id and util.file_exists(M.root(self.cfg) .. "/" .. id .. "/scrollback") then
      self.hold[id] = true
    end
  end
  self.hold_until = os.time() + M.HOLD_SECONDS
end

function Saver:capture(bid, entry)
  local id, dir = M.block_id(bid), M.block_dir(self.cfg, bid)
  if not dir or not util.file_exists(dir .. "/history") then return end -- no shell hook here
  local file = dir .. "/scrollback"
  if self.hold[id] then
    if util.file_exists(file) and os.time() < self.hold_until then return end
    self.hold[id] = nil
  end
  if entry.program then return end -- an allowlisted editor/pager/TUI
  local idle = not entry.running
  if not idle and M.full_screen(entry.session_id, bid) then return end
  local max_lines = self.cfg.scrollback_lines
  local raw = M.read_tail(entry.session_id, bid, math.min(983040, max_lines * 256))
  if not raw then return end
  local text = M.clean(raw, max_lines, idle)
  if text == self.cache[bid] then return end
  self.cache[bid] = text
  if text == "" then
    os.remove(file)
    return
  end
  local now = os.time()
  local ok, err = self.store:write_raw(file, string.format("%s %d %s\n%s\n", M.HEADER, now, util.short_time(now), text))
  if not ok then util.log("warn", "saving output of " .. id .. ": " .. tostring(err)) end
end

-- Called after each save, once the tracker is up to date.
function Saver:after_save(tracker)
  if not self:enabled() then self.dirty = {} return end
  local todo = self.dirty
  if self.all then
    todo = {}
    for bid in pairs(tracker.blocks) do todo[bid] = true end
    self.all = false
  end
  self.dirty = {}
  for bid in pairs(todo) do
    local entry = tracker.blocks[bid]
    if entry then
      local ok, err = pcall(self.capture, self, bid, entry)
      if not ok then util.log("warn", "capturing output: " .. tostring(err)) end
    end
  end
end

-- Block ids referenced by a saved snapshot.
local function snapshot_ids(snap, keep)
  for _, s in ipairs((snap and snap.sessions) or {}) do
    for _, w in ipairs(s.windows or {}) do
      local function walk(node)
        if type(node) ~= "table" then return end
        if node.block then
          local id = M.block_id(node.block.block_id)
          if id then keep[id] = true end
        elseif node.split then
          walk(node.split.before)
          walk(node.split.after)
        end
      end
      walk(w.layout)
    end
  end
end

-- Removes saved files of blocks that are gone: not live, not in any saved
-- snapshot (so they could still be restored), and untouched for a day.
function M.gc(cfg, store, tracker)
  local ok, res = pcall(rex.exec, { "find", M.root(cfg), "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-mtime", "+1" })
  if not ok or type(res) ~= "table" or res.code ~= 0 then return 0 end
  local keep = {}
  for bid in pairs(tracker.blocks) do
    local id = M.block_id(bid)
    if id then keep[id] = true end
  end
  snapshot_ids(store:read_json("pending.json"), keep)
  snapshot_ids(store:read_json("last.json"), keep)
  for _, name in ipairs(store:state().history) do
    snapshot_ids(store:read_json(store.history_dir .. "/" .. name), keep)
  end
  local removed = 0
  for path in tostring(res.stdout or ""):gmatch("[^\n]+") do
    local id = path:match("/([^/]+)$")
    if id and M.block_id(id) == id and not keep[id] then
      pcall(rex.exec, { "rm", "-rf", "--", path })
      removed = removed + 1
    end
  end
  return removed
end

-- A session rebuilt by restore.lua gets new block ids: move each old block's
-- files to the new id as *.restore files. The new shell may already be at its
-- first prompt, so the hook picks these up at any prompt, merging the history
-- into its own file. Returns true when there was something to hand over.
function M.handover(cfg, old_bid, new_bid)
  local from, to = M.block_dir(cfg, old_bid), M.block_dir(cfg, new_bid)
  if not from or not to or not util.file_exists(from .. "/history") then return false end
  pcall(rex.exec, { "mkdir", "-p", to })
  os.rename(from .. "/history", to .. "/history.restore")
  os.rename(from .. "/scrollback", to .. "/scrollback.restore")
  pcall(rex.exec, { "rm", "-rf", "--", from })
  return true
end

return M
