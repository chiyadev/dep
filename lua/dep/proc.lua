local logger = require("dep/log")
local proc = {}

function proc.exec(process, args, cwd, env, cb)
  local out = vim.loop.new_pipe()
  local buffer = {}

  local handle = vim.loop.spawn(
    process,
    { args = args, cwd = cwd, env = env, stdio = { nil, out, out } },
    vim.schedule_wrap(function(code)
      handle:close()

      local output = table.concat(buffer)

      logger:log(
        process,
        string.format('executed `%s` with args: "%s"\n%s', process, table.concat(args, '", "'), output)
      )

      cb(code, output)
    end)
  )

  vim.loop.read_start(
    out,
    vim.schedule_wrap(function(_, data)
      if data then
        table.insert(buffer, data)
      else
        out:close()
      end
    end)
  )
end

local git_env = { "GIT_TERMINAL_PROMPT=0" }

function proc.git_current_commit(dir, cb)
  exec("git", { "rev-parse", "HEAD" }, dir, git_env, cb)
end

function proc.git_clone(dir, url, branch, cb)
  local args = { "--depth=1", "--recurse-submodules", "--shallow-submodules", url, dir }

  if branch then
    table.insert(args, "--branch=" .. branch)
  end

  exec("git", args, nil, git_env, cb)
end

function proc.git_fetch(dir, branch, cb)
  local args = { "--depth=1", "--recurse-submodules" }

  if branch then
    table.insert(args, "origin")
    table.insert(args, branch)
  end

  exec("git", args, dir, git_env, cb)
end

function proc.git_reset(dir, branch, cb)
  local args = { "--hard", "--recurse-submodules" }

  if branch then
    table.insert("origin/" .. branch)
  end

  exec("git", args, dir, git_env, cb)
end

return proc
