-- Decides what is running in a pane and whether it may be started again.
--
-- Safety rules:
--   * Only programs on the allowlist are recorded with their arguments, so a
--     command such as `mysql -pSECRET` never reaches the snapshot file.
--   * Restored programs are typed into an idle shell, one quoted word at a
--     time, so quitting the program leaves the user in a shell like tmux.
local util = require("resurrect.util")

local M = {}

M.shells = util.set({
  "sh", "bash", "zsh", "fish", "nu", "dash", "ksh", "mksh", "tcsh", "csh",
  "elvish", "xonsh", "pwsh", "login", "tmux",
})

local MAX_ARGS, MAX_CHARS = 64, 2048

local function strip_login_dash(name)
  return (name:gsub("^%-", ""))
end

-- Names a process can be known by. Programs installed as versioned binaries
-- (claude runs as ".../versions/2.1.322") are best matched by argv0.
local function names_of(proc)
  local names = {}
  local function add(n)
    n = strip_login_dash(util.basename(n or ""))
    if n ~= "" then names[#names + 1] = n end
  end
  add(proc.argv0); add(proc.name); add(proc.invoked_path); add(proc.path)
  return names
end

-- Summarises a terminal's `process` result as
--   { idle = true, cwd = ... }                 shell at a prompt
--   { key = "nvim", pid = 123, cwd = ... }     an allowlisted program
--   { other = "make", cwd = ... }              something we will not restart
function M.identify(proc, allowed)
  if type(proc) ~= "table" then return { idle = true } end
  local fg = proc.foreground
  local shell = proc.ancestors and proc.ancestors[1]
  local cwd = (fg and fg.cwd) or (shell and shell.cwd)
  if type(fg) ~= "table" then return { idle = true, cwd = cwd } end
  local names = names_of(fg)
  for _, n in ipairs(names) do
    if M.shells[n] then return { idle = true, cwd = cwd } end
  end
  for _, n in ipairs(names) do
    if allowed[n] then return { key = n, pid = fg.pid, cwd = cwd } end
  end
  return { other = names[1] or "?", cwd = cwd }
end

-- Full argv of a process. Linux exposes it exactly; elsewhere `ps` joins it
-- with spaces, so an argument containing a space is split (documented).
function M.read_argv(pid)
  pid = tonumber(pid)
  if not pid then return nil end
  local f = io.open("/proc/" .. pid .. "/cmdline", "rb")
  if f then
    local raw = f:read("*a") or ""
    f:close()
    local argv = {}
    for word in raw:gmatch("([^%z]*)%z") do argv[#argv + 1] = word end
    if #argv > 0 then return argv end
  end
  local ok, res = pcall(rex.exec, { "ps", "-ww", "-o", "command=", "-p", tostring(pid) })
  if not ok or type(res) ~= "table" or res.code ~= 0 then return nil end
  local line = (res.stdout or ""):gsub("%s+$", "")
  if line == "" then return nil end
  return util.split_words(line)
end

local function has_follow_flag(argv)
  for i = 2, #argv do
    local a = argv[i]
    if a == "--follow" or a:match("^%-%-follow=") or (a:match("^%-[^-]") and a:find("[fF]")) then return true end
  end
  return false
end

local function within_limits(argv)
  if #argv == 0 or #argv > MAX_ARGS then return false end
  local n = 0
  for _, a in ipairs(argv) do n = n + #a end
  return n <= MAX_CHARS
end

-- Built-in restore strategies. Each gets (argv, cwd) and returns the argv to
-- start, or nil to leave the pane as a plain shell.
M.builtin_strategies = {
  -- Resume the conversation instead of re-sending the original prompt.
  claude = function(argv) return { argv[1], "--continue" } end,
  codex = function(argv) return { argv[1], "resume", "--last" } end,
  -- `tail` without -f exits at once; restarting it is pointless.
  tail = function(argv) if has_follow_flag(argv) then return argv end return nil end,
  -- Prefer a saved vim session in the folder when there is one.
  vim = function(argv, cwd)
    if cwd and util.file_exists(cwd .. "/Session.vim") then return { argv[1], "-S" } end
    return argv
  end,
}
M.builtin_strategies.nvim = M.builtin_strategies.vim

-- argv to type into the restored pane, or nil.
function M.restore_argv(program, cwd, cfg)
  if type(program) ~= "table" or type(program.argv) ~= "table" then return nil end
  if not cfg.restore_programs or not cfg.programs[program.key] then return nil end
  local strategy = cfg.strategies[program.key]
  if strategy == false then return nil end
  if type(strategy) ~= "function" then strategy = M.builtin_strategies[program.key] end
  local argv = program.argv
  if strategy then
    local ok, res = pcall(strategy, argv, cwd)
    if not ok then
      util.log("warn", "strategy for " .. program.key .. " failed: " .. tostring(res))
      return nil
    end
    argv = res
  end
  if type(argv) ~= "table" or not within_limits(argv) then return nil end
  for _, a in ipairs(argv) do
    if type(a) ~= "string" then return nil end
    if a:find("[%z\r\n]") then return nil end -- would break out of the typed line
  end
  return argv
end

return M
