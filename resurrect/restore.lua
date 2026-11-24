-- Carries out a plan. Each missing session is rebuilt with a single
-- session.create call, so it appears complete or not at all. Programs are
-- typed into idle shells, never started as the pane's own process, so
-- quitting them leaves a working shell behind.
local util = require("resurrect.util")
local programs = require("resurrect.programs")
local snapshot = require("resurrect.snapshot")

local M = {}
local SHELL_FLAVOR = "com.superlogical.terminal.shell"

local function create_layout(node, leaves)
  if node.block then
    leaves[#leaves + 1] = node.block
    local block = { flavor = SHELL_FLAVOR, options = {} }
    if type(node.block.cwd) == "string" and node.block.cwd ~= "" then block.options.cwd = node.block.cwd end
    if type(node.block.label) == "string" and node.block.label ~= "" then block.label = node.block.label end
    return { block = block }
  end
  local sp = node.split
  local out = { direction = sp.direction, before = create_layout(sp.before, leaves), after = create_layout(sp.after, leaves) }
  if type(sp.ratio) == "number" and sp.ratio > 0 and sp.ratio < 1 then out.ratio = sp.ratio end
  return { split = out }
end

-- Exposed for tests: the session.create request for a saved session, plus
-- the saved panes of each window in the order Rex returns their new IDs.
function M.create_request(saved, label)
  local initial, leaves_by_window = {}, {}
  for _, w in ipairs(saved.windows or {}) do
    if w.layout then
      local leaves = {}
      initial[#initial + 1] = { window_label = w.label, layout = create_layout(w.layout, leaves) }
      leaves_by_window[#leaves_by_window + 1] = { saved = w, leaves = leaves }
    end
  end
  return { label = label, initial_windows = initial }, leaves_by_window
end

local function create_session(saved)
  local base = saved.label
  local labels = { base, base and (base .. "-restored") or nil, base and (base .. "-restored-" .. os.time()) or nil }
  local last_err
  for i = 1, 3 do
    if i > 1 and not labels[i] then break end
    local req, leaves = M.create_request(saved, labels[i])
    local res, err = util.call("session.create", req)
    if res and res.session_id then return res, leaves end
    last_err = tostring(err)
    if not last_err:find("already used", 1, true) then break end -- only retry label clashes
  end
  return nil, last_err
end

function M.restore_session(saved, cfg)
  local res, leaves_or_err = create_session(saved)
  if not res then return nil, leaves_or_err end
  local leaves_by_window = leaves_or_err
  local relaunch, focus, active = {}, {}, nil
  for i, wres in ipairs(res.initial_windows or {}) do
    local info = leaves_by_window[i]
    if info then
      for j, new_id in ipairs(wres.block_ids or {}) do
        local leaf = info.leaves[j]
        if leaf then
          if leaf.block_id == info.saved.focused_block_id then focus[#focus + 1] = new_id end
          local argv = programs.restore_argv(leaf.program, leaf.cwd, cfg)
          if argv then
            relaunch[#relaunch + 1] = { session_id = res.session_id, block_id = new_id, argv = argv, cwd = leaf.cwd }
          end
        end
      end
      if info.saved.window_id == saved.active_window_id then active = wres.window_id end
    end
  end
  -- Put focus back where it was: each window's pane, then the active window.
  for _, bid in ipairs(focus) do
    util.call("session.focus_block", { session_id = res.session_id, block_id = bid })
  end
  if active then util.call("session.focus_window", { session_id = res.session_id, window_id = active }) end
  return { session_id = res.session_id, relaunch = relaunch }
end

local function shell_ready(proc)
  local fg = type(proc) == "table" and proc.foreground
  if type(fg) ~= "table" then return false end
  local name = util.basename(fg.argv0 or fg.name or ""):gsub("^%-", "")
  return programs.shells[name] == true and name ~= "login"
end

-- Waits (briefly, and only where pausing is allowed) for the shell to start,
-- then types the command. Returns ok, err.
function M.relaunch(item)
  if rex.sleep then
    for _ = 1, 16 do
      local proc = snapshot.probe_process(item.session_id, item.block_id)
      if shell_ready(proc) then break end
      rex.sleep(0.25)
    end
  end
  local res, err = util.block_call(item.session_id, item.block_id, "write",
    { data = util.shell_join(item.argv) .. "\r" })
  return res ~= nil, err
end

-- Runs the whole plan; returns a summary table. Never raises.
function M.execute(plan, cfg, say)
  say = say or function() end
  local result = { created = 0, relaunched = 0, errors = {} }
  local queue = {}
  for _, saved in ipairs(plan.missing or {}) do
    local res, err = M.restore_session(saved, cfg)
    if res then
      result.created = result.created + 1
      local _, w, p = snapshot.count({ sessions = { saved } })
      say(string.format("✓ session %s (%d windows, %d panes)", saved.label or "?", w, p))
      for _, r in ipairs(res.relaunch) do queue[#queue + 1] = r end
    else
      result.errors[#result.errors + 1] = string.format("session %s: %s", saved.label or "?", err)
      say("✗ session " .. (saved.label or "?") .. ": " .. tostring(err))
    end
  end
  for _, r in ipairs(plan.relaunch or {}) do queue[#queue + 1] = r end
  for _, r in ipairs(queue) do
    local ok, err = M.relaunch(r)
    if ok then
      result.relaunched = result.relaunched + 1
      say("✓ " .. util.shell_join(r.argv) .. "  in " .. util.tilde(r.cwd or "~"))
    else
      result.errors[#result.errors + 1] = util.shell_join(r.argv) .. ": " .. err
      say("✗ " .. util.shell_join(r.argv) .. ": " .. err)
    end
  end
  return result
end

return M
