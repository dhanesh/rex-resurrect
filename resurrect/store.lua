-- Snapshot files on disk. Every write goes to a temporary file in the same
-- directory and is renamed over the target, so a crash or power cut leaves
-- either the old file or the new one, never a torn one.
--
-- Layout of state_dir (mode 0700):
--   last.json      the current snapshot, rewritten only when something changed
--   pending.json   the snapshot from before a server restart, awaiting a decision
--   state.json     which server instance we last saw, and the history index
--   history/       older snapshots, pruned to history_keep
local util = require("resurrect.util")

local Store = {}
Store.__index = Store

local seq = 0

function Store.new(dir)
  local self = setmetatable({ dir = dir, history_dir = dir .. "/history" }, Store)
  return self
end

function Store:ensure()
  if self.ready then return true end
  -- rex.exec takes an argv table: no shell, so odd paths can't inject.
  local ok, res = pcall(rex.exec, { "mkdir", "-p", self.history_dir })
  if not ok or type(res) ~= "table" or res.code ~= 0 then
    return false, "cannot create " .. self.history_dir .. ": " .. tostring(ok and (res and res.stderr) or res)
  end
  pcall(rex.exec, { "chmod", "700", self.dir, self.history_dir })
  self.ready = true
  return true
end

function Store:path(name)
  return self.dir .. "/" .. name
end

function Store:write_raw(path, text)
  seq = seq + 1
  local tmp = string.format("%s.tmp-%d-%d", path, os.time(), seq)
  local f, err = io.open(tmp, "w")
  if not f then return false, err end
  local ok, werr = f:write(text)
  f:close()
  if not ok then os.remove(tmp) return false, werr end
  local rok, rerr = os.rename(tmp, path)
  if not rok then os.remove(tmp) return false, rerr end
  return true
end

function Store:write_json(name, value)
  local ok, text = pcall(rex.json.encode, value)
  if not ok then return false, text end
  return self:write_raw(self:path(name), text)
end

function Store:read_raw(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- Returns the decoded table, or nil when the file is missing or unreadable.
-- A corrupt file is moved aside instead of being trusted or deleted.
function Store:read_json(name)
  local path = name:sub(1, 1) == "/" and name or self:path(name)
  local text = self:read_raw(path)
  if not text or text == "" then return nil end
  local ok, value = pcall(rex.json.decode, text)
  if ok and type(value) == "table" then return value end
  os.rename(path, path .. ".corrupt-" .. os.time())
  util.log("warn", "moved unreadable " .. path .. " aside")
  return nil
end

function Store:exists(name)
  return util.file_exists(self:path(name))
end

function Store:remove(name)
  os.remove(self:path(name))
end

function Store:state()
  local st = self:read_json("state.json") or {}
  if type(st.history) ~= "table" then st.history = {} end
  return st
end

function Store:save_state(st)
  return self:write_json("state.json", st)
end

-- Copies a snapshot into history/ and prunes the oldest beyond `keep`.
function Store:archive(snapshot, keep, tag)
  local st = self:state()
  local name = string.format("snapshot-%s%s.json", os.date("%Y%m%d-%H%M%S", snapshot.saved_at or os.time()), tag and ("-" .. tag) or "")
  local ok, err = self:write_json("history/" .. name, snapshot)
  if not ok then return false, err end
  local list = {}
  for _, n in ipairs(st.history) do if n ~= name then list[#list + 1] = n end end
  list[#list + 1] = name
  while #list > keep do
    os.remove(self.history_dir .. "/" .. table.remove(list, 1))
  end
  st.history = list
  st.last_archive_at = os.time()
  self:save_state(st)
  return true, name
end

return Store
