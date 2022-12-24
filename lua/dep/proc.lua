local logger = require("dep.log").global
local proc = {}

function proc.exec(process, args, cwd, env, cb)
  local buffer = {}

  local function cb_output(_, data, _)
    table.insert(buffer, table.concat(data))
  end

  local function cb_exit(job_id, exit_code, _)
    local output = table.concat(buffer)
    logger:log(
      process,
      string.format(
        'Job %s ["%s"] finished with exitcode %s\n%s',
        job_id,
        table.concat(args, '", "'),
        exit_code,
        output
      )
    )
    cb(exit_code ~= 0, output)
  end

  table.insert(args, 1, process)
  vim.fn.jobstart(args, {
    cwd = cwd,
    env = env,
    stdin = nil,
    on_exit = cb_exit,
    on_stdout = cb_output,
    on_stderr = cb_output,
  })
end

local git_env = { GIT_TERMINAL_PROMPT = 0 }

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
