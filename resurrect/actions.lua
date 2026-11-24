-- init.lua integration. Adds palette/keybindable actions:
--   resurrect_save, resurrect_restore, resurrect_status
-- Usage in ~/.config/rex/init.lua:
--   pcall(function() require("resurrect.actions").setup() end)
local M = {}

function M.setup()
  local function run(cmd)
    return function(args)
      local commands = require("resurrect.commands")
      local lines = {}
      local result = commands.run(cmd, args or {}, function(line) lines[#lines + 1] = line end)
      if #lines > 0 and type(result) == "table" then result.log = lines end
      return result
    end
  end
  rex.action{ name = "resurrect_save", title = "Resurrect: Save Now", run = run("save") }
  rex.action{ name = "resurrect_restore", title = "Resurrect: Restore Saved Sessions", run = run("restore") }
  rex.action{ name = "resurrect_status", title = "Resurrect: Status", run = run("status") }
end

return M
