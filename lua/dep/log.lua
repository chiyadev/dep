local logger = {
  path = vim.fn.stdpath("cache") .. "/dep.log",
  silent = false,
}

local colors = {
  install = "MoreMsg",
  update = "WarningMsg",
  delete = "Directory",
  error = "ErrorMsg",
}

function logger:open(path)
  self:close()

  self.path = path or self.path
  self.handle = vim.loop.fs_open(self.path, "w", 0x1A4) -- 0644
  self.pipe = vim.loop.new_pipe()

  self.pipe:open(self.handle)
end

function logger:close()
  if self.pipe then
    self.pipe:close()
    self.pipe = nil
  end

  if self.handle then
    vim.loop.fs_close(self.handle)
    self.handle = nil
  end
end

function logger:log(op, message, cb)
  if not self.silent and colors[op] then
    vim.api.nvim_echo({
      { "[dep]", "Identifier" },
      { " " },
      { message, colors[op] },
    }, false, {})
  end

  if self.pipe then
    local source = debug.getinfo(2, "Sl").short_src
    local message = string.format("[%s] %s: %s\n", os.date(), source, message)

    self.pipe:write(
      message,
      vim.schedule_wrap(function(err)
        if cb then
          cb(err)
        end
      end)
    )
  end
end

return logger
