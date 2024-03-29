--
-- Copyright (c) 2022 chiya.dev
--
-- Use of this source code is governed by the MIT License
-- which can be found in the LICENSE file and at:
--
--   https://chiya.dev/licenses/mit.txt
--
local vim, setmetatable, pcall, debug, string, os, assert = vim, setmetatable, pcall, debug, string, os, assert

local function default_log_path()
  -- ensure cache directory exists (#5)
  local path = vim.fn.stdpath("cache")
  if not vim.loop.fs_stat(path) then
    vim.loop.fs_mkdir(path, 0x1ff) -- 0777
  end

  return path .. "/dep.log"
end

local function try_format(...)
  local ok, s = pcall(string.format, ...)
  if ok then
    return s
  end
end

--- Writes logs to a file and prints pretty status messages.
local Logger = setmetatable({
  __metatable = "Logger",
  __index = {
    --- Prints a message associated with a stage.
    log = function(self, stage, message, ...)
      -- calling function
      local source = debug.getinfo(2, "Sl").short_src

      -- format or stringify message
      if type(message) == "string" then
        message = try_format(message, ...) or message
      else
        message = vim.inspect(message)
      end

      -- print and write must be done on the main event loop
      vim.schedule(function()
        if not self.silent then
          if stage == "error" then
            vim.api.nvim_err_writeln(string.format("[dep] %s", message))
          elseif self.stage_colors[stage] then
            vim.api.nvim_echo({
              { "[dep]", "Identifier" },
              { " " },
              { message, self.stage_colors[stage] },
            }, true, {})
          end
        end

        if self.pipe then
          self.pipe:write(string.format("[%s] %s: %s\n", os.date(), source, message))
        end
      end)
    end,

    --- Closes the log file handle.
    close = function(self)
      if self.pipe then
        self.pipe:close()
        self.pipe = nil
      end

      if self.handle then
        vim.loop.fs_close(self.handle)
        self.handle = nil
      end
    end,
  },
}, {
  --- Constructs a new `Logger`.
  __call = function(mt, path)
    path = path or default_log_path()

    -- clear and open log file
    local handle = assert(vim.loop.fs_open(path, "w", 0x1a4)) -- 0644
    local pipe = vim.loop.new_pipe()
    pipe:open(handle)

    return setmetatable({
      path = path,
      handle = handle,
      pipe = pipe,
      silent = false,

      -- TODO: This looks good for me ;) but it should have proper vim color mapping for other people.
      stage_colors = {
        skip = "Comment",
        clean = "Boolean",
        install = "MoreMsg",
        update = "WarningMsg",
        delete = "Directory",
        error = "ErrorMsg",
      },
    }, mt)
  end,
})

return {
  Logger = Logger,
  global = Logger(),
}
