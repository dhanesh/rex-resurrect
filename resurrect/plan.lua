-- Compares a saved snapshot with what is live now and works out what is
-- worth offering. Rex restores sessions itself, keeping their IDs, so we
-- only offer what it did not bring back:
--   * missing  - saved sessions with no live counterpart
--   * relaunch - panes Rex restored as a bare shell that were running an
--                allowlisted program
-- Nothing in a plan closes, replaces or duplicates what already exists.
local util = require("resurrect.util")
local programs = require("resurrect.programs")
local snapshot = require("resurrect.snapshot")

local M = {}

-- Terminal panes of each window's tiled layout, in layout order.
local function live_window_leaves(view)
  local out = {}
  for wi, win in ipairs((view and view.windows) or {}) do
    local ids = {}
    local function walk(node)
      if type(node) ~= "table" then return end
      if node.block_id then ids[#ids + 1] = node.block_id return end
      if node.split then walk(node.split.before) walk(node.split.after) end
    end
    for _, layer in ipairs(win.layers or {}) do
      if layer.kind == "tiled" then walk(layer.layout) end
    end
    out[wi] = ids
  end
  return out
end

-- Which live pane corresponds to a saved one. Rex keeps block IDs when it
-- restores, so the ID is tried first; if IDs changed, fall back to the same
-- position in the same window, but only when that window has exactly the
-- same number of panes (otherwise the layout changed and we don't guess).
local function pane_matcher(saved, now)
  local by_pos = {}
  local live_leaves = live_window_leaves(now.view)
  for wi, win in ipairs(saved.windows or {}) do
    local saved_ids = {}
    snapshot.each_leaf(win.layout, function(leaf) saved_ids[#saved_ids + 1] = leaf.block_id end)
    local here = live_leaves[wi]
    if here and #here == #saved_ids then
      for j, id in ipairs(saved_ids) do by_pos[id] = here[j] end
    end
  end
  return function(saved_block_id)
    if now.block_ids and now.block_ids[saved_block_id] then return saved_block_id end
    return by_pos[saved_block_id]
  end
end

-- live: array of { session_id, label, block_ids = { [id] = true }, view = session.view }
-- probe(session_id, block_id) -> programs.identify() result or nil
function M.build(snap, live, probe, cfg)
  local plan = { saved_at = snap.saved_at, checked_at = snap.checked_at, missing = {}, relaunch = {}, natively_restored = 0, total = 0 }
  local by_id, by_label = {}, {}
  for _, s in ipairs(live or {}) do
    by_id[s.session_id] = s
    if s.label then by_label[s.label] = s end
  end

  for _, saved in ipairs(snap.sessions or {}) do
    plan.total = plan.total + 1
    local now = by_id[saved.session_id] or by_label[saved.label]
    if not now then
      plan.missing[#plan.missing + 1] = saved
    else
      plan.natively_restored = plan.natively_restored + 1
      -- A pane is a relaunch candidate only when we can tell which live pane
      -- it is, and that pane is idle at a prompt.
      local match = pane_matcher(saved, now)
      for wi, win in ipairs(saved.windows or {}) do
        snapshot.each_leaf(win.layout, function(leaf)
          local argv = programs.restore_argv(leaf.program, leaf.cwd, cfg)
          local target = argv and match(leaf.block_id)
          if target then
            local ident = probe(now.session_id, target)
            if ident and ident.idle then
              plan.relaunch[#plan.relaunch + 1] = {
                session_id = now.session_id,
                block_id = target,
                argv = argv,
                cwd = leaf.cwd,
                where = string.format("%s / %s", now.label or saved.label or "?", win.label or ("window " .. wi)),
              }
            end
          end
        end)
      end
    end
  end
  return plan
end

function M.is_empty(plan)
  return #plan.missing == 0 and #plan.relaunch == 0
end

-- Human-readable summary shown in the prompt pane.
function M.describe(plan, now)
  now = now or os.time()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  local saved = plan.saved_at or now
  local checked = plan.checked_at
  if type(checked) == "number" and checked > saved + 60 then
    -- Unchanged since it was saved, and known to be current until `checked`.
    add(string.format("rex-resurrect · snapshot from %s, still current at %s (%s)",
      util.short_time(saved), util.short_time(checked), util.ago(now - checked)))
  else
    add(string.format("rex-resurrect · snapshot from %s (%s)", util.short_time(saved), util.ago(now - saved)))
  end
  add("")
  if plan.total > 0 then
    add(string.format("Rex brought back %d of %d saved session%s on its own.",
      plan.natively_restored, plan.total, plan.total == 1 and "" or "s"))
  end
  if #plan.missing > 0 then
    add("")
    add("Not restored yet:")
    for _, s in ipairs(plan.missing) do
      local panes, folders, seen = 0, {}, {}
      for _, w in ipairs(s.windows or {}) do
        snapshot.each_leaf(w.layout, function(leaf)
          panes = panes + 1
          local d = util.tilde(leaf.cwd or "~")
          if not seen[d] and #folders < 3 then seen[d] = true folders[#folders + 1] = d end
        end)
      end
      add(string.format("  • %-20s %d window%s, %d pane%s  %s", s.label or "(unnamed)",
        #(s.windows or {}), #(s.windows or {}) == 1 and "" or "s", panes, panes == 1 and "" or "s",
        table.concat(folders, ", ")))
    end
  end
  if #plan.relaunch > 0 then
    add("")
    add("Programs to reopen:")
    for _, r in ipairs(plan.relaunch) do
      add(string.format("  • %-28s %s  (%s)", r.where, util.shell_join(r.argv), util.tilde(r.cwd or "~")))
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Live session list in the shape build() wants, from session.view calls.
function M.live_sessions()
  local list, err = util.call("session.list", {})
  if not list then return nil, err end
  local out = {}
  for _, s in ipairs(list.sessions or {}) do
    local view = util.call("session.view", { session_id = s.session_id })
    local ids = {}
    if view then
      for _, win in ipairs(view.windows or {}) do
        for _, layer in ipairs(win.layers or {}) do
          for _, b in ipairs(layer.blocks or {}) do ids[b.block_id] = true end
        end
      end
    end
    out[#out + 1] = { session_id = s.session_id, label = s.label, block_ids = ids, view = view }
  end
  return out
end

return M
