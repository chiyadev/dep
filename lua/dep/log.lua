local logger = {
  path = vim.fn.stdpath("cache") .. "/dep.log",
  silent = false,
}

local colors = {
  skip = "Comment",
  clean = "Boolean",
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

function logger:log(op, message)
  local source = debug.getinfo(2, "Sl").short_src

  vim.schedule(function()
    if type(message) ~= "string" then
      message = vim.inspect(message)
    end

    if not self.silent and colors[op] then
      vim.api.nvim_echo({
        { "[dep]", "Identifier" },
        { " " },
        { message, colors[op] },
      }, true, {})
    end

    if self.pipe then
      self.pipe:write(string.format("[%s] %s: %s\n", os.date(), source, message))
    end
  end)
end

return logger
