-- Command-line entry point:
--   rex do ~/.config/rex/resurrect/ctl.lua cmd=save
--   rex do ~/.config/rex/resurrect/ctl.lua cmd=restore [from=history|FILE]
--   rex do ~/.config/rex/resurrect/ctl.lua cmd=status
--   rex do ~/.config/rex/resurrect/ctl.lua cmd=dismiss
local here = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_dir = here:match("^(.*)/[^/]+$") or "."
package.path = (plugin_dir:match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path

local commands = require("resurrect.commands")
local args = rex.args or {}
local result = commands.run(args.cmd or "status", args, print)
if args.cmd == "restore" and type(result) == "table" and result.ok == false then
  rex.stop(1)
end
return result
