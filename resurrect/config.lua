-- Defaults plus optional user overrides from
-- $XDG_CONFIG_HOME/rex/resurrect-config.lua (default ~/.config/rex/...).
-- That file just returns a table, e.g.:
--   return { on_restart = "auto", extra_programs = { "ssh" } }
local util = require("resurrect.util")

local M = {}

local function config_home()
  local x = os.getenv("XDG_CONFIG_HOME")
  if x and x ~= "" then return x end
  return util.home() .. "/.config"
end

local function state_home()
  local x = os.getenv("XDG_STATE_HOME")
  if x and x ~= "" then return x end
  return util.home() .. "/.local/state"
end

M.user_config_path = config_home() .. "/rex/resurrect-config.lua"

-- Programs that are safe to start again in a restored pane: interactive
-- viewers, editors and TUIs whose re-launch has no side effects. Anything not
-- listed comes back as a plain shell in the right folder.
M.default_programs = {
  "vi", "vim", "nvim", "nano", "micro", "hx", "helix", "kak", "emacs",
  "less", "more", "man", "tail",
  "top", "htop", "btop", "glances",
  "lazygit", "tig", "k9s", "yazi", "ranger", "nnn", "lf",
  "claude", "codex",
}

M.defaults = {
  state_dir = state_home() .. "/rex-resurrect",
  on_restart = "ask",        -- "ask": prompt; "auto": restore silently; "off": never offer
  restore_programs = true,   -- relaunch allowlisted programs in restored panes
  extra_programs = {},       -- added to default_programs
  exclude_programs = {},     -- removed from default_programs
  save_debounce = 2,         -- seconds to let a burst of events settle before saving
  min_save_interval = 5,     -- never save more often than this
  resync_interval = 300,     -- periodic full re-read, a safety net for missed events
  settle_delay = 2,          -- wait after a server restart before comparing
  history_keep = 20,         -- archived snapshots to keep
  history_interval = 900,    -- archive the current snapshot at most this often
  confirm_interval = 900,    -- note "snapshot still current" at most this often
  scrollback_lines = 2000,   -- lines of output kept per block (shell hook only); 0 = off
  scrollback_poll = 15,      -- how often to look for commands run in hooked blocks
}

local LIMITS = {
  save_debounce = { 0.2, 60 },
  min_save_interval = { 1, 3600 },
  resync_interval = { 30, 86400 },
  settle_delay = { 0, 60 },
  history_keep = { 1, 500 },
  history_interval = { 60, 86400 * 7 },
  confirm_interval = { 1, 86400 },
  scrollback_lines = { 0, 20000 },
  scrollback_poll = { 1, 3600 },
}

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- Merge user values over defaults, ignoring anything of the wrong type and
-- clamping numbers, so a typo can never make the daemon spin or stop saving.
function M.merge(user, warn)
  warn = warn or function() end
  local cfg = copy(M.defaults)
  if type(user) ~= "table" then return M.finish(cfg) end
  for key, value in pairs(user) do
    local default = M.defaults[key]
    if default == nil and key ~= "strategies" then
      warn("unknown option '" .. tostring(key) .. "' ignored")
    elseif key == "strategies" then
      if type(value) == "table" then cfg.strategies = value else warn("'strategies' must be a table") end
    elseif type(value) ~= type(default) then
      warn(string.format("option '%s' should be a %s, got %s; using default", key, type(default), type(value)))
    else
      local lim = LIMITS[key]
      if lim then value = math.max(lim[1], math.min(lim[2], value)) end
      cfg[key] = value
    end
  end
  if cfg.on_restart ~= "ask" and cfg.on_restart ~= "auto" and cfg.on_restart ~= "off" then
    warn("on_restart must be ask, auto or off; using ask")
    cfg.on_restart = "ask"
  end
  return M.finish(cfg)
end

function M.finish(cfg)
  local allowed = util.set(M.default_programs)
  for _, p in ipairs(cfg.extra_programs or {}) do allowed[p] = true end
  for _, p in ipairs(cfg.exclude_programs or {}) do allowed[p] = nil end
  cfg.programs = allowed
  cfg.strategies = cfg.strategies or {}
  return cfg
end

function M.load(warn)
  warn = warn or function(msg) util.log("warn", msg) end
  local user
  if util.file_exists(M.user_config_path) then
    local ok, res = pcall(dofile, M.user_config_path)
    if ok then user = res else warn("could not load " .. M.user_config_path .. ": " .. tostring(res)) end
  end
  return M.merge(user, warn)
end

return M
