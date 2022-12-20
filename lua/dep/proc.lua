local logger = require("dep.log").global
local proc = {}

function proc.exec(process, args, cwd, env, cb)
  local handle, pid, buffer = nil, nil, {}
  local stdout = vim.loop.new_pipe()
  local stderr = vim.loop.new_pipe()

  handle, pid = vim.loop.spawn(
    process,
    { args = args, cwd = cwd, env = env, stdio = { nil, stdout, stderr } },
    vim.schedule_wrap(function(code)
      handle:close()

      local output = table.concat(buffer)

      if output:sub(-1) == "\n" then
        output = output:sub(1, -2)
      end

      logger:log(
        process,
        string.format(
          'executed `%s` (code=%s, pid=%s) with args: "%s"\n%s',
          process,
          code,
          pid,
          table.concat(args, '", "'),
          output
        )
      )

      cb(code ~= 0, output)
    end)
  )

  vim.loop.read_start(stdout, function(_, data)
    if data then
      buffer[#buffer + 1] = data
    else
      stdout:close()
    end
  end)

  vim.loop.read_start(stderr, function(_, data)
    if data then
      buffer[#buffer + 1] = data
    else
      stderr:close()
    end
  end)
end

local git_env = { "GIT_TERMINAL_PROMPT=0" }

function proc.git_rev_parse(dir, arg, cb)
  local args = { "rev-parse", "--short", arg }

  proc.exec("git", args, dir, git_env, cb)
end

function proc.git_clone(dir, url, branch, cb)
  local args = { "clone", "--depth=1", "--recurse-submodules", "--shallow-submodules", url, dir }

  if branch then
    args[#args + 1] = "--branch=" .. branch
  end

  proc.exec("git", args, nil, git_env, cb)
end

function proc.git_fetch(dir, remote, refspec, cb)
  local args = { "fetch", "--depth=1", "--recurse-submodules", remote, refspec }

  proc.exec("git", args, dir, git_env, cb)
end

function proc.git_reset(dir, treeish, cb)
  local args = { "reset", "--hard", "--recurse-submodules", treeish, "--" }

  proc.exec("git", args, dir, git_env, cb)
end

return proc
