-- Builds snapshots of the server's sessions, windows, panes and folders.
--
-- The Tracker keeps the last view of every session and the last known
-- folder/program of every terminal pane, and refreshes only what events
-- marked dirty. A burst of activity in one pane costs one small RPC, not a
-- re-read of the whole server.
local util = require("resurrect.util")
local programs = require("resurrect.programs")

local M = {}
M.FORMAT = "rex-resurrect/1"
local TERMINAL = "com.superlogical.terminal"

local Tracker = {}
Tracker.__index = Tracker

function M.tracker(cfg)
  return setmetatable({
    cfg = cfg,
    order = {},          -- session ids in server order
    views = {},          -- session id -> session.view result
    blocks = {},         -- block id -> { session_id, label, cwd, program, running, pid }
    dirty_sessions = {},
    dirty_blocks = {},
    need_list = true,
  }, Tracker)
end

function Tracker:mark_all()
  self.need_list = true
  for _, sid in ipairs(self.order) do self.dirty_sessions[sid] = true end
  for bid in pairs(self.blocks) do self.dirty_blocks[bid] = true end
end

function Tracker:mark_list() self.need_list = true end
-- An event about a session or block the tracker hasn't seen also re-reads the
-- session list: the session may have been created while the saver was
-- starting, before it listened for session_created.
function Tracker:mark_session(sid)
  if not sid then return end
  self.dirty_sessions[sid] = true
  if not self.views[sid] then self.need_list = true end
end
function Tracker:mark_block(bid)
  if not bid then return end
  self.dirty_blocks[bid] = true
  if not self.blocks[bid] then self.need_list = true end
end

function Tracker:is_dirty()
  return self.need_list or next(self.dirty_sessions) ~= nil or next(self.dirty_blocks) ~= nil
end

-- Looked up on each call, so tests can stand in for the Rex API.
local function call(method, params) return util.call(method, params) end

local function is_gone(err)
  return err and (err:find("not_found") or err:find("not found")) ~= nil
end

-- Terminal blocks in a view, keyed by id, with their labels.
local function terminal_blocks(view)
  local out = {}
  for _, win in ipairs(view.windows or {}) do
    for _, layer in ipairs(win.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        if b.creator_name == TERMINAL and b.block_id then out[b.block_id] = b end
      end
    end
  end
  return out
end

function M.probe_process(sid, bid)
  return util.block_call(sid, bid, "process")
end

function Tracker:probe(sid, bid, entry)
  local proc, err = M.probe_process(sid, bid)
  if not proc then return false, err end
  local ident = programs.identify(proc, self.cfg.programs)
  entry.cwd = ident.cwd or entry.cwd
  entry.running = ident.other
  if ident.key then
    -- Same process as last time: reuse its argv instead of running ps again.
    if not (entry.program and entry.pid == ident.pid and entry.program.key == ident.key) then
      local argv = programs.read_argv(ident.pid)
      entry.program = argv and { key = ident.key, argv = argv } or nil
    end
    entry.pid = ident.pid
  else
    entry.program, entry.pid = nil, nil
  end
  if not entry.cwd then
    local pwd = util.block_call(sid, bid, "pwd")
    entry.cwd = pwd and util.file_url_to_path(pwd.pwd) or nil
  end
  return true
end

-- Brings the cache up to date. Errors on individual items are skipped (the
-- previous value is kept) so one odd pane never blocks saving the others.
function Tracker:refresh()
  if self.need_list then
    local list, err = call("session.list", {})
    if not list then return false, err end
    local order, seen = {}, {}
    for _, s in ipairs(list.sessions or {}) do
      order[#order + 1] = s.session_id
      seen[s.session_id] = true
      if not self.views[s.session_id] then self.dirty_sessions[s.session_id] = true end
    end
    for sid in pairs(self.views) do
      if not seen[sid] then self.views[sid] = nil end
    end
    self.order = order
    self.need_list = false
  end

  for sid in pairs(self.dirty_sessions) do
    local view, err = call("session.view", { session_id = sid })
    if view then
      self.views[sid] = view
    elseif is_gone(err) then
      self.views[sid] = nil
      self.need_list = true
    end
  end
  self.dirty_sessions = {}

  -- Reconcile blocks against the views: new panes need a probe, closed ones go.
  local live = {}
  for sid, view in pairs(self.views) do
    for bid, b in pairs(terminal_blocks(view)) do
      live[bid] = true
      local entry = self.blocks[bid]
      if not entry then
        entry = {}
        self.blocks[bid] = entry
        self.dirty_blocks[bid] = true
      end
      entry.session_id, entry.label = sid, b.label
    end
  end
  for bid in pairs(self.blocks) do
    if not live[bid] then self.blocks[bid] = nil end
  end

  for bid in pairs(self.dirty_blocks) do
    local entry = self.blocks[bid]
    if entry then self:probe(entry.session_id, bid, entry) end
  end
  self.dirty_blocks = {}
  return true
end

-- Converts a live layout tree into the saved form, dropping non-terminal
-- blocks and collapsing the splits around them.
local function convert(node, blocks)
  if type(node) ~= "table" then return nil end
  if node.block_id then
    local b = blocks[node.block_id]
    if not b then return nil end
    return { block = { block_id = node.block_id, label = b.label, cwd = b.cwd, program = b.program, running = b.running } }
  end
  local split = node.split
  if type(split) ~= "table" then return nil end
  local before, after = convert(split.before, blocks), convert(split.after, blocks)
  if before and after then
    return { split = { direction = split.direction, ratio = split.ratio, before = before, after = after } }
  end
  return before or after
end

local function tiled_layout(win)
  for _, layer in ipairs(win.layers or {}) do
    if layer.kind == "tiled" then return layer.layout end
  end
  return nil
end

function M.session_from_view(view, blocks)
  local windows = {}
  for _, win in ipairs(view.windows or {}) do
    local layout = convert(tiled_layout(win), blocks)
    if layout then
      windows[#windows + 1] = {
        window_id = win.window_id,
        label = (not util.is_default_window_label(win.label)) and win.label or nil,
        focused_block_id = win.focused_block_id,
        layout = layout,
      }
    end
  end
  if #windows == 0 then return nil end
  return { session_id = view.session_id, label = view.label, active_window_id = view.active_window_id, windows = windows }
end

function Tracker:snapshot(meta)
  local sessions = {}
  for _, sid in ipairs(self.order) do
    local view = self.views[sid]
    local s = view and M.session_from_view(view, self.blocks)
    if s then sessions[#sessions + 1] = s end
  end
  meta = meta or {}
  return {
    format = M.FORMAT,
    saved_at = os.time(),
    instance_id = meta.instance_id,
    host_id = meta.host_id,
    sessions = sessions,
  }
end

-- The part of a snapshot that matters for "did anything change?".
function M.content_key(snap)
  return rex.json.encode(snap.sessions or {})
end

-- Visits every pane in a saved layout, in Rex's block order (before, then after).
function M.each_leaf(node, fn)
  if type(node) ~= "table" then return end
  if node.block then fn(node.block) return end
  if node.split then
    M.each_leaf(node.split.before, fn)
    M.each_leaf(node.split.after, fn)
  end
end

function M.count(snap)
  local sessions, windows, panes = 0, 0, 0
  for _, s in ipairs(snap.sessions or {}) do
    sessions = sessions + 1
    for _, w in ipairs(s.windows or {}) do
      windows = windows + 1
      M.each_leaf(w.layout, function() panes = panes + 1 end)
    end
  end
  return sessions, windows, panes
end

-- One-shot full capture, for manual saves.
function M.capture(cfg, meta)
  local t = M.tracker(cfg)
  local ok, err = t:refresh()
  if not ok then return nil, err end
  return t:snapshot(meta)
end

function M.server_meta()
  local st = call("server.status", {})
  if not st then return {} end
  return { instance_id = st.instance_id, host_id = st.host_id }
end

return M
