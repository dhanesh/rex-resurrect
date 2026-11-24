-- Small, dependency-free helpers shared by every rex-resurrect module.
-- Runs under Rex's embedded Lua 5.1 (GopherLua), so no 5.2+ features.
local M = {}

function M.home()
  return os.getenv("HOME") or ""
end

function M.basename(path)
  if type(path) ~= "string" then return "" end
  return path:match("([^/]+)/*$") or ""
end

function M.dirname(path)
  return (path:match("^(.*)/[^/]*$")) or "."
end

-- Quote one word for a POSIX shell. Plain words pass through unchanged so the
-- command a user sees in their pane looks like the one they typed.
function M.shell_quote(word)
  word = tostring(word)
  if word ~= "" and word:match("^[%w%._/%-=:,@%+%%]+$") then return word end
  return "'" .. (word:gsub("'", "'\\''")) .. "'"
end

function M.shell_join(argv)
  local out = {}
  for i, word in ipairs(argv) do out[i] = M.shell_quote(word) end
  return table.concat(out, " ")
end

function M.split_words(line)
  local words = {}
  for word in tostring(line):gmatch("%S+") do words[#words + 1] = word end
  return words
end

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- "file://host/Users/me/x%20y" -> "/Users/me/x y"; plain absolute paths pass through.
function M.file_url_to_path(url)
  if type(url) ~= "string" or url == "" then return nil end
  local path = url:match("^file://[^/]*(/.*)$")
  if path then return url_decode(path) end
  if url:sub(1, 1) == "/" then return url end
  return nil
end

function M.tilde(path)
  local home = M.home()
  if type(path) == "string" and home ~= "" and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

function M.ago(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return string.format("%d min ago", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%d h ago", math.floor(seconds / 3600)) end
  return string.format("%d days ago", math.floor(seconds / 86400))
end

function M.set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

-- "Thu 13:14". Rex's Lua (GopherLua) returns "mon" for every %a, so the short
-- weekday is cut from %A, which is correct.
function M.short_time(t)
  return os.date("%A", t):sub(1, 3) .. os.date(" %H:%M", t)
end

function M.file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- Rex auto-labels windows "Window 1a2b3c4d" from their ID. Such a label is
-- meaningless once the window is recreated with a new ID, so we drop it.
function M.is_default_window_label(label)
  return type(label) ~= "string" or label == "" or label:match("^Window %x%x%x%x%x%x%x%x$") ~= nil
end

-- rex.call reports failure by returning (nil, err) rather than raising, and a
-- method may legitimately return null. This normalises both into:
--   result_table            on success ({} for a null result)
--   nil, "error text"       on failure
local function raw_call(method, params)
  local ok, res, err = pcall(rex.call, method, params)
  if not ok then return nil, tostring(res) end
  if res == nil and err ~= nil then return nil, tostring(err) end
  if res == nil then return {} end
  return res
end

-- Session-scoped methods (session.view, block.method, ...) need the script's
-- connection attached to that session. A daemon started with --all is
-- attached once its event loop starts, but not while its main chunk runs, and
-- a one-off script never is. Attach on demand and retry once, so the common
-- path costs nothing extra.
function M.call(method, params)
  params = params or {}
  local res, err = raw_call(method, params)
  if not res and params.session_id and err and err:find("not attached", 1, true) then
    raw_call("session.attach", { session_id = params.session_id })
    res, err = raw_call(method, params)
  end
  return res, err
end

function M.block_call(session_id, block_id, method, args)
  return M.call("block.method", { session_id = session_id, block_id = block_id, method = method, args = args })
end

function M.log(level, msg)
  -- rex.log exists in every Rex Lua context; fall back to stderr just in case.
  local ok = rex and rex.log and pcall(rex.log, level, "[resurrect] " .. msg)
  if not ok then io.stderr:write(os.date("%Y-%m-%d %H:%M:%S ") .. level .. " [resurrect] " .. msg .. "\n") end
end

return M
