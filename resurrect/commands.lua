-- Operations shared by the daemon, `rex do ctl.lua` and the init.lua actions.
local util = require("resurrect.util")
local config = require("resurrect.config")
local Store = require("resurrect.store")
local snapshot = require("resurrect.snapshot")
local plan_mod = require("resurrect.plan")
local restore = require("resurrect.restore")
local programs = require("resurrect.programs")

local M = {}
M.PROMPT_LABEL = "rex-resurrect"

function M.context()
  local cfg = config.load()
  local store = Store.new(cfg.state_dir)
  local ok, err = store:ensure()
  if not ok then util.log("error", err) end
  return cfg, store
end

local function session_ids(snap)
  local ids = {}
  for _, s in ipairs(snap.sessions or {}) do ids[s.session_id] = true end
  return ids
end

local function lost_sessions(prev, snap)
  local now = session_ids(snap)
  for id in pairs(session_ids(prev)) do
    if not now[id] then return true end
  end
  return false
end

-- Writes snap as last.json when its content differs from last_key.
-- Returns the new key and whether anything was written.
--   * An empty capture never replaces a saved one: a server that is
--     shutting down, or has just started, must not wipe the snapshot.
--   * Before a save that drops a session, the previous snapshot is archived,
--     so a session closed by accident can still be brought back.
function M.commit(cfg, store, snap, last_key)
  if #(snap.sessions or {}) == 0 then return last_key, false end
  local key = snapshot.content_key(snap)
  if key == last_key then return key, false end
  local prev = store:read_json("last.json")
  local st = store:state()
  if prev and #(prev.sessions or {}) > 0 and lost_sessions(prev, snap) then
    store:archive(prev, cfg.history_keep, "before-close")
  elseif not st.last_archive_at or os.time() - st.last_archive_at >= cfg.history_interval then
    store:archive(snap, cfg.history_keep)
  end
  local ok, err = store:write_json("last.json", snap)
  if not ok then
    util.log("error", "writing snapshot: " .. tostring(err))
    return last_key, false
  end
  return key, true
end

-- The daemon re-reads the server often, but rewrites last.json only when
-- something changed, so saved_at alone makes an unchanged snapshot look
-- stale. checked.json records when a capture last matched it (at most every
-- confirm_interval), tied to that snapshot by its saved_at. It is a separate
-- file so these writes never race the read-modify-write of state.json.
function M.note_checked(store, saved_at, now)
  return store:write_json("checked.json", { at = now or os.time(), saved_at = saved_at })
end

-- The time a snapshot was last confirmed current, or nil.
function M.checked_at(store, snap)
  local c = snap and store:read_json("checked.json")
  if c and c.saved_at == snap.saved_at and type(c.at) == "number" and c.at > (snap.saved_at or 0) then
    return c.at
  end
  return nil
end

function M.build_plan(cfg, snap)
  local live, err = plan_mod.live_sessions()
  if not live then return nil, err end
  local probe = function(sid, bid)
    local proc = snapshot.probe_process(sid, bid)
    return proc and programs.identify(proc, cfg.programs) or nil
  end
  return plan_mod.build(snap, live, probe, cfg), live
end

-- The snapshot awaiting a decision is archived and cleared.
local function resolve_pending(cfg, store, tag)
  local pending = store:read_json("pending.json")
  if pending then
    store:archive(pending, cfg.history_keep, tag)
    if tag == "declined" then
      local st = store:state()
      st.declined_key = snapshot.content_key(pending)
      store:save_state(st)
    end
  end
  store:remove("pending.json")
  store:remove("prompt.txt")
end

local function pick_source(cfg, store, args)
  local from = args and args.from
  if type(from) == "string" and from ~= "" and from ~= "pending" and from ~= "last" then
    if from == "history" then
      local hist = store:state().history
      if #hist == 0 then return nil, "no history yet" end
      from = store.history_dir .. "/" .. hist[#hist]
    elseif not from:find("/") then
      from = store.history_dir .. "/" .. from
    end
    local snap = store:read_json(from)
    if not snap then return nil, "cannot read " .. from end
    return snap, "file"
  end
  if from ~= "last" then
    local pending = store:read_json("pending.json")
    if pending then return pending, "pending" end
  end
  local last = store:read_json("last.json")
  if last then return last, "last" end
  return nil, "no snapshot has been saved yet"
end

function M.save(cfg, store)
  local snap, err = snapshot.capture(cfg, snapshot.server_meta())
  if not snap then return { ok = false, error = err } end
  local prev = store:read_json("last.json")
  local _, wrote = M.commit(cfg, store, snap, prev and snapshot.content_key(prev) or nil)
  local s, w, p = snapshot.count(snap)
  return { ok = true, changed = wrote, sessions = s, windows = w, panes = p, file = store:path("last.json") }
end

function M.restore(cfg, store, args, say)
  say = say or function() end
  local snap, source = pick_source(cfg, store, args)
  if not snap then
    say("Nothing to restore: " .. tostring(source))
    return { ok = false, error = source }
  end
  local plan, err = M.build_plan(cfg, snap)
  if not plan then
    say("Cannot read live sessions: " .. tostring(err))
    return { ok = false, error = err }
  end
  if plan_mod.is_empty(plan) then
    say("Nothing to restore: everything in the snapshot is already open.")
    if source == "pending" then resolve_pending(cfg, store, "pre-restart") end
    return { ok = true, created = 0, relaunched = 0 }
  end
  local result = restore.execute(plan, cfg, say)
  if source == "pending" then resolve_pending(cfg, store, "pre-restart") end
  result.ok = #result.errors == 0
  return result
end

function M.dismiss(cfg, store)
  local had = store:exists("pending.json")
  resolve_pending(cfg, store, "declined")
  return { ok = true, dismissed = had }
end

function M.status(cfg, store)
  local last = store:read_json("last.json")
  local st = store:state()
  local out = {
    state_dir = cfg.state_dir,
    on_restart = cfg.on_restart,
    pending = store:exists("pending.json"),
    history = #st.history,
    latest_history = st.history[#st.history],
  }
  if last then
    out.saved_at = os.date("%Y-%m-%d %H:%M:%S", last.saved_at)
    out.saved = util.ago(os.time() - (last.saved_at or 0))
    local checked = M.checked_at(store, last)
    if checked then
      out.checked_at = os.date("%Y-%m-%d %H:%M:%S", checked)
      out.checked = util.ago(os.time() - checked)
    end
    out.sessions, out.windows, out.panes = snapshot.count(last)
  end
  return out
end

-- Dispatcher used by ctl.lua and the init.lua actions.
function M.run(cmd, args, say)
  local cfg, store = M.context()
  if cmd == "save" then return M.save(cfg, store) end
  if cmd == "restore" then return M.restore(cfg, store, args, say) end
  if cmd == "dismiss" then return M.dismiss(cfg, store) end
  if cmd == "status" then return M.status(cfg, store) end
  error("unknown command '" .. tostring(cmd) .. "'; use save, restore, dismiss or status")
end

----------------------------------------------------------------------------
-- Server restart handling (daemon only: it needs rex.sleep).

local function prompt_already_open(live)
  for _, s in ipairs(live or {}) do
    for _, win in ipairs((s.view and s.view.windows) or {}) do
      for _, layer in ipairs(win.layers or {}) do
        for _, b in ipairs(layer.blocks or {}) do
          if b.label == M.PROMPT_LABEL then return true end
        end
      end
    end
  end
  return false
end

function M.show_prompt(store, plan, live, paths)
  if prompt_already_open(live) then return "prompt already open" end
  local ok, err = store:write_raw(store:path("prompt.txt"), plan_mod.describe(plan))
  if not ok then return nil, err end
  local leaf = { block = {
    flavor = "com.superlogical.terminal.shell",
    label = M.PROMPT_LABEL,
    options = {
      shell = "none",
      cwd = util.home(),
      command = { "/bin/sh", paths.prompt_sh, paths.rex_bin, paths.ctl, store:path("prompt.txt"), paths.server or "" },
    },
  } }
  local target = live and live[1]
  local res, call_err
  if target and target.view and target.view.active_window_id then
    res, call_err = util.call("session.new_layer", {
      session_id = target.session_id,
      window_id = target.view.active_window_id,
      bounds = { 0.1, 0.15, 0.8, 0.7 },
      layout = leaf,
      focus = true,
    })
  else
    res, call_err = util.call("session.create", {
      label = "resurrect",
      initial_windows = { { window_label = "Restore", layout = leaf } },
    })
  end
  if not res then return nil, call_err end
  return "prompted"
end

-- Called once when the daemon connects. Detects a new server instance,
-- freezes the pre-restart snapshot and asks (or restores, or does nothing).
function M.on_server_start(cfg, store, meta, paths)
  local st = store:state()
  local previous = st.instance_id
  if previous == meta.instance_id then return "same server" end

  if previous and not store:exists("pending.json") then
    local last = store:read_json("last.json")
    local same_host = not (last and last.host_id and meta.host_id and last.host_id ~= meta.host_id)
    if last and same_host and #(last.sessions or {}) > 0 and snapshot.content_key(last) ~= st.declined_key then
      last.checked_at = M.checked_at(store, last) or last.checked_at
      store:write_json("pending.json", last)
    end
  end
  st.instance_id, st.host_id = meta.instance_id, meta.host_id
  store:save_state(st)

  if not previous then return "first run" end
  if not store:exists("pending.json") then return "nothing saved" end
  if cfg.on_restart == "off" then return "on_restart is off" end

  if cfg.settle_delay > 0 and rex.sleep then rex.sleep(cfg.settle_delay) end
  local pending = store:read_json("pending.json")
  if not pending then return "nothing saved" end
  local plan, live = M.build_plan(cfg, pending)
  if not plan then return "could not compare: " .. tostring(live) end
  if plan_mod.is_empty(plan) then
    resolve_pending(cfg, store, "pre-restart")
    return "nothing missing"
  end
  if cfg.on_restart == "auto" then
    local result = restore.execute(plan, cfg, function(line) util.log("info", line) end)
    resolve_pending(cfg, store, "pre-restart")
    return string.format("restored %d sessions, %d programs", result.created, result.relaunched)
  end
  local res, err = M.show_prompt(store, plan, live, paths)
  return res or ("prompt failed: " .. tostring(err))
end

return M
