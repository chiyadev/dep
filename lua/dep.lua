--
-- Copyright (c) 2022 chiya.dev
--
-- Use of this source code is governed by the MIT License
-- which can be found in the LICENSE file and at:
--
--   https://chiya.dev/licenses/mit.txt
--

local logger = require("dep.log").global
local proc = require("dep.proc")

local initialized, perf, config_path, base_dir
local packages, root

local function bench(name, code, ...)
  local start = os.clock()
  code(...)
  perf[name] = os.clock() - start
end

local function get_name(id)
  local name = id:match("^[%w-_.]+/([%w-_.]+)$")
  if name then
    return name
  else
    error(string.format('invalid name "%s"; must be in the format "user/package"', id))
  end
end

local function link_dependency(parent, child)
  if not parent.dependents[child.id] then
    parent.dependents[child.id] = child
    parent.dependents[#parent.dependents + 1] = child
  end

  if not child.dependencies[parent.id] then
    child.dependencies[parent.id] = parent
    child.dependencies[#child.dependencies + 1] = parent
  end
end

local function register(spec, overrides)
  overrides = overrides or {}

  if type(spec) ~= "table" then
    spec = { spec }
  end

  local id = spec[1]
  local package = packages[id]

  if not package then
    package = {
      id = id,
      enabled = true,
      exists = false,
      added = false,
      configured = false,
      loaded = false,
      subtree_configured = false,
      subtree_loaded = false,
      on_setup = {},
      on_config = {},
      on_load = {},
      dependencies = {}, -- inward edges
      dependents = {}, -- outward edges
      perf = {},
    }

    packages[id] = package
    packages[#packages + 1] = package
  end

  local prev_dir = package.dir -- optimization

  package.name = spec.as or package.name or get_name(id)
  package.url = spec.url or package.url or ("https://github.com/" .. id .. ".git")
  package.branch = spec.branch or package.branch
  package.dir = base_dir .. package.name
  package.pin = overrides.pin or spec.pin or package.pin
  package.enabled = not overrides.disable and not spec.disable and package.enabled

  if prev_dir ~= package.dir then
    package.exists = vim.fn.isdirectory(package.dir) ~= 0
    package.configured = package.exists
  end

  package.on_setup[#package.on_setup + 1] = spec.setup
  package.on_config[#package.on_config + 1] = spec.config
  package.on_load[#package.on_load + 1] = spec[2]

  -- every package is implicitly dependent on us, the package manager
  if root and package ~= root then
    link_dependency(root, package)
  end

  if type(spec.requires) == "table" then
    for i = 1, #spec.requires do
      link_dependency(register(spec.requires[i]), package)
    end
  elseif spec.requires then
    link_dependency(register(spec.requires), package)
  end

  if type(spec.deps) == "table" then
    for i = 1, #spec.deps do
      link_dependency(package, register(spec.deps[i]))
    end
  elseif spec.deps then
    link_dependency(package, register(spec.deps))
  end

  return package
end

local function register_recursive(list, overrides)
  overrides = overrides or {}
  overrides = {
    pin = overrides.pin or list.pin,
    disable = overrides.disable or list.disable,
  }

  for i = 1, #list do
    local ok, err = pcall(register, list[i], overrides)
    if not ok then
      error(string.format("%s (spec=%s)", err, vim.inspect(list[i])))
    end
  end

  if list.modules then
    for i = 1, #list.modules do
      local name, module = "<unnamed module>", list.modules[i]

      if type(module) == "string" then
        if list.modules.prefix then
          module = list.modules.prefix .. module
        end

        name, module = module, require(module)
      end

      name = module.name or name

      local ok, err = pcall(register_recursive, module, overrides)
      if not ok then
        error(string.format("%s <- %s", err, name))
      end
    end
  end
end

local function sort_dependencies()
  -- we don't do topological sort, packages are loaded by traversing the graph recursively
  -- any sorting is fine as long as the order is consistent and predictable
  local function compare(a, b)
    local a_deps, b_deps = #a.dependencies, #b.dependencies
    if a_deps == b_deps then
      return a.id < b.id
    else
      return a_deps < b_deps
    end
  end

  table.sort(packages, compare)

  for i = 1, #packages do
    table.sort(packages[i].dependencies, compare)
    table.sort(packages[i].dependents, compare)
  end
end

local function find_cycle()
  local index = 0
  local indexes = {}
  local lowlink = {}
  local stack = {}

  -- use tarjan algorithm to find circular dependencies (strongly connected components)
  local function connect(package)
    indexes[package.id], lowlink[package.id] = index, index
    stack[#stack + 1], stack[package.id] = package, true
    index = index + 1

    for i = 1, #package.dependents do
      local dependent = package.dependents[i]

      if not indexes[dependent.id] then
        local cycle = connect(dependent)
        if cycle then
          return cycle
        else
          lowlink[package.id] = math.min(lowlink[package.id], lowlink[dependent.id])
        end
      elseif stack[dependent.id] then
        lowlink[package.id] = math.min(lowlink[package.id], indexes[dependent.id])
      end
    end

    if lowlink[package.id] == indexes[package.id] then
      local cycle = { package }
      local node

      repeat
        node = stack[#stack]
        stack[#stack], stack[node.id] = nil, nil
        cycle[#cycle + 1] = node
      until node == package

      -- a node is by definition strongly connected to itself
      -- ignore single-node components unless it explicitly specified itself as a dependency
      if #cycle > 2 or package.dependents[package.id] then
        return cycle
      end
    end
  end

  for i = 1, #packages do
    local package = packages[i]

    if not indexes[package.id] then
      local cycle = connect(package)
      if cycle then
        return cycle
      end
    end
  end
end

local function ensure_acyclic()
  local cycle = find_cycle()

  if cycle then
    local names = {}
    for i = 1, #cycle do
      names[i] = cycle[i].id
    end
    error("circular dependency detected in package dependency graph: " .. table.concat(names, " -> "))
  end
end

local function run_hooks(package, type)
  local hooks = package[type]
  if #hooks == 0 then
    return true
  end

  local start = os.clock()

  -- chdir into the package directory to make running external commands
  -- from hooks easier.
  local last_cwd = vim.fn.getcwd()
  vim.fn.chdir(package.dir)

  for i = 1, #hooks do
    local ok, err = pcall(hooks[i])
    if not ok then
      vim.fn.chdir(last_cwd)

      package.error = true
      return false, err
    end
  end

  vim.fn.chdir(last_cwd)
  package.perf[type] = os.clock() - start

  logger:log(
    "hook",
    string.format("triggered %d %s %s for %s", #hooks, type, #hooks == 1 and "hook" or "hooks", package.id)
  )

  return true
end

local function ensure_added(package)
  if not package.added then
    local ok, err = run_hooks(package, "on_setup")
    if not ok then
      package.error = true
      return false, err
    end

    local start = os.clock()

    ok, err = pcall(vim.cmd, "packadd " .. package.name)
    if not ok then
      package.error = true
      return false, err
    end

    package.added = true
    package.perf.pack = os.clock() - start

    logger:log("vim", string.format("packadd completed for %s", package.id))
  end

  return true
end

local function configure_recursive(package)
  if not package.exists or not package.enabled or package.error then
    return
  end

  if package.subtree_configured then
    return true
  end

  for i = 1, #package.dependencies do
    if not package.dependencies[i].configured then
      return
    end
  end

  if not package.configured then
    local ok, err = ensure_added(package)
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    ok, err = run_hooks(package, "on_config")
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    package.configured = true
    logger:log("config", string.format("configured %s", package.id))
  end

  package.subtree_configured = true

  for i = 1, #package.dependents do
    package.subtree_configured = configure_recursive(package.dependents[i]) and package.subtree_configured
  end

  return package.subtree_configured
end

local function load_recursive(package)
  if not package.exists or not package.enabled or package.error then
    return
  end

  if package.subtree_loaded then
    return true
  end

  for i = 1, #package.dependencies do
    if not package.dependencies[i].loaded then
      return
    end
  end

  if not package.loaded then
    local ok, err = ensure_added(package)
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    ok, err = run_hooks(package, "on_load")
    if not ok then
      logger:log("error", string.format("failed to load %s; reason: %s", package.id, err))
      return
    end

    package.loaded = true
    logger:log("load", string.format("loaded %s", package.id))
  end

  package.subtree_loaded = true

  for i = 1, #package.dependents do
    package.subtree_loaded = load_recursive(package.dependents[i]) and package.subtree_loaded
  end

  return package.subtree_loaded
end

local function reload_meta()
  local ok, err
  bench("meta", function()
    ok, err = pcall(
      vim.cmd,
      [[
        silent! helptags ALL
        silent! UpdateRemotePlugins
      ]]
    )
  end)

  if ok then
    logger:log("vim", "reloaded helptags and remote plugins")
  else
    logger:log("error", string.format("failed to reload helptags and remote plugins; reason: %s", err))
  end
end

local function reload()
  -- clear errors to retry
  for i = 1, #packages do
    packages[i].error = false
  end

  local reloaded
  reloaded = configure_recursive(root) or reloaded
  reloaded = load_recursive(root) or reloaded

  if reloaded then
    reload_meta()
  end

  return reloaded
end

local function reload_all()
  for i = 1, #packages do
    local package = packages[i]
    package.loaded, package.subtree_loaded = false, false
  end

  reload()
end

local function clean()
  vim.loop.fs_scandir(
    base_dir,
    vim.schedule_wrap(function(err, handle)
      if err then
        logger:log("error", string.format("failed to clean; reason: %s", err))
      else
        local queue = {}

        while handle do
          local name = vim.loop.fs_scandir_next(handle)
          if name then
            queue[name] = base_dir .. name
          else
            break
          end
        end

        for i = 1, #packages do
          queue[packages[i].name] = nil
        end

        for name, dir in pairs(queue) do
          -- todo: make this async
          local ok = vim.fn.delete(dir, "rf")
          if ok then
            logger:log("clean", string.format("deleted %s", name))
          else
            logger:log("error", string.format("failed to delete %s", name))
          end
        end
      end
    end)
  )
end

local function mark_reconfigure(package)
  local function mark_dependencies(node)
    node.subtree_configured, node.subtree_loaded = false, false

    for i = 1, #node.dependencies do
      mark_dependencies(node.dependencies[i])
    end
  end

  local function mark_dependents(node)
    node.configured, node.loaded, node.added = false, false, false
    node.subtree_configured, node.subtree_loaded = false, false

    for i = 1, #node.dependents do
      mark_dependents(node.dependents[i])
    end
  end

  mark_dependencies(package)
  mark_dependents(package)
end

local function sync(package, cb)
  if not package.enabled then
    cb()
    return
  end

  if package.exists then
    if package.pin then
      cb()
      return
    end

    local function log_err(err)
      logger:log("error", string.format("failed to update %s; reason: %s", package.id, err))
    end

    proc.git_rev_parse(package.dir, "HEAD", function(err, before)
      if err then
        log_err(before)
        cb(err)
      else
        proc.git_fetch(package.dir, "origin", package.branch or "HEAD", function(err, message)
          if err then
            log_err(message)
            cb(err)
          else
            proc.git_rev_parse(package.dir, "FETCH_HEAD", function(err, after)
              if err then
                log_err(after)
                cb(err)
              elseif before == after then
                logger:log("skip", string.format("skipped %s", package.id))
                cb(err)
              else
                proc.git_reset(package.dir, after, function(err, message)
                  if err then
                    log_err(message)
                  else
                    mark_reconfigure(package)
                    logger:log("update", string.format("updated %s; %s -> %s", package.id, before, after))
                  end

                  cb(err)
                end)
              end
            end)
          end
        end)
      end
    end)
  else
    proc.git_clone(package.dir, package.url, package.branch, function(err, message)
      if err then
        logger:log("error", string.format("failed to install %s; reason: %s", package.id, message))
      else
        package.exists = true
        mark_reconfigure(package)
        logger:log("install", string.format("installed %s", package.id))
      end

      cb(err)
    end)
  end
end

local function sync_list(list, on_complete)
  local progress = 0
  local has_errors = false

  local function done(err)
    progress = progress + 1
    has_errors = has_errors or err

    if progress == #list then
      clean()
      reload()

      if has_errors then
        logger:log("error", "there were errors during sync; see :messages or :DepLog for more information")
      else
        logger:log("update", string.format("synchronized %s %s", #list, #list == 1 and "package" or "packages"))
      end

      if on_complete then
        on_complete()
      end
    end
  end

  for i = 1, #list do
    sync(list[i], done)
  end
end

local function get_commits(cb)
  local results = {}
  local done = 0
  for i = 1, #packages do
    local package = packages[i]

    if package.exists then
      proc.git_rev_parse(package.dir, "HEAD", function(err, commit)
        if not err then
          results[package.id] = commit
        end

        done = done + 1
        if done == #packages then
          cb(results)
        end
      end)
    else
      done = done + 1
    end
  end
end

local function print_list(cb)
  get_commits(function(commits)
    local buffer = vim.api.nvim_create_buf(true, true)
    local line, indent = 0, 0

    local function print(chunks)
      local concat = {}
      local column = 0

      for _ = 1, indent do
        concat[#concat + 1] = "  "
        column = column + 2
      end

      if not chunks then
        chunks = {}
      elseif type(chunks) == "string" then
        chunks = { { chunks } }
      end

      for i = 1, #chunks do
        local chunk = chunks[i]
        concat[#concat + 1] = chunk[1]
        chunk.offset, column = column, column + #chunk[1]
      end

      vim.api.nvim_buf_set_lines(buffer, line, -1, false, { table.concat(concat) })

      for i = 1, #chunks do
        local chunk = chunks[i]
        if chunk[2] then
          vim.api.nvim_buf_add_highlight(buffer, -1, chunk[2], line, chunk.offset, chunk.offset + #chunk[1])
        end
      end

      line = line + 1
    end

    print(string.format("Installed packages (%s):", #packages))
    indent = 1

    local loaded = {}

    local function dry_load(package)
      if loaded[package.id] then
        return
      end

      for i = 1, #package.dependencies do
        if not loaded[package.dependencies[i].id] then
          return
        end
      end

      loaded[package.id], loaded[#loaded + 1] = true, package

      local chunk = {
        { string.format("[%s] ", commits[package.id] or "       "), "Comment" },
        { package.id, "Underlined" },
      }

      if not package.exists then
        chunk[#chunk + 1] = { " *not installed", "Comment" }
      end

      if not package.loaded then
        chunk[#chunk + 1] = { " *not loaded", "Comment" }
      end

      if not package.enabled then
        chunk[#chunk + 1] = { " *disabled", "Comment" }
      end

      if package.pin then
        chunk[#chunk + 1] = { " *pinned", "Comment" }
      end

      print(chunk)

      for i = 1, #package.dependents do
        dry_load(package.dependents[i])
      end
    end

    dry_load(root)
    indent = 0

    print()
    print("Load time (μs):")
    indent = 1
    local profiles = {}

    for i = 1, #packages do
      local package = packages[i]
      local profile = {
        package = package,
        total = 0,
        setup = package.perf.on_setup or 0,
        load = package.perf.on_load or 0,
        pack = package.perf.pack or 0,

        "total",
        "setup",
        "pack",
        "load",
      }

      if package == root then
        for k, v in pairs(perf) do
          if profile[k] then
            profile[k] = profile[k] + v
          end
        end
      end

      for j = 1, #profile do
        profile.total = profile.total + profile[profile[j]]
      end

      profiles[#profiles + 1] = profile
    end

    table.sort(profiles, function(a, b)
      return a.total > b.total
    end)

    for i = 1, #profiles do
      local profile = profiles[i]
      local chunk = {
        { "- ", "Comment" },
        { profile.package.id, "Underlined" },
        { string.rep(" ", 40 - #profile.package.id) },
      }

      for j = 1, #profile do
        local key, value = profile[j], profile[profile[j]]
        chunk[#chunk + 1] = { string.format(" %5s ", key), "Comment" }
        chunk[#chunk + 1] = { string.format("%4d", value * 1000000) }
      end

      print(chunk)
    end

    indent = 0
    print()
    print("Dependency graph:")

    local function walk_graph(package)
      local chunk = {
        { "| ", "Comment" },
        { package.id, "Underlined" },
      }

      local function add_edges(p)
        for i = 1, #p.dependencies do
          local dependency = p.dependencies[i]

          if dependency ~= root and not chunk[dependency.id] then -- don't convolute the list
            chunk[#chunk + 1] = { " " .. dependency.id, "Comment" }
            chunk[dependency.id] = true
            add_edges(dependency)
          end
        end
      end

      add_edges(package)
      print(chunk)

      for i = 1, #package.dependents do
        indent = indent + 1
        walk_graph(package.dependents[i])
        indent = indent - 1
      end
    end

    walk_graph(root)

    print()
    print("Debug information:")

    local debug = {}
    for l in vim.inspect(packages):gmatch("[^\n]+") do
      debug[#debug + 1] = l
    end

    vim.api.nvim_buf_set_lines(buffer, line, -1, false, debug)
    vim.api.nvim_buf_set_name(buffer, "packages.dep")
    vim.api.nvim_buf_set_option(buffer, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buffer, "modifiable", false)

    vim.cmd("sp")
    vim.api.nvim_win_set_buf(0, buffer)

    if cb then
      cb()
    end
  end)
end

vim.cmd([[
  command! DepSync lua require("dep").sync()
  command! DepReload lua require("dep").reload()
  command! DepClean lua require("dep").clean()
  command! DepList lua require("dep").list()
  command! DepLog lua require("dep").open_log()
  command! DepConfig lua require("dep").open_config()
]])

local function wrap_api(name, fn)
  return function(...)
    if initialized then
      local ok, err = pcall(fn, ...)
      if not ok then
        logger:log("error", err)
      end
    else
      logger:log("error", string.format("cannot call %s; dep is not initialized", name))
    end
  end
end

--todo: prevent multiple execution of async routines
return setmetatable({
  sync = wrap_api("dep.sync", function(on_complete)
    sync_list(packages, on_complete)
  end),

  reload = wrap_api("dep.reload", reload_all),
  clean = wrap_api("dep.clean", clean),
  list = wrap_api("dep.list", print_list),

  open_log = wrap_api("dep.open_log", function()
    vim.cmd("sp " .. logger.path)
  end),

  open_config = wrap_api("dep.open_config", function()
    vim.cmd("sp " .. config_path)
  end),
}, {
  __call = function(_, config)
    local err
    perf = {}
    config_path = debug.getinfo(2, "S").source:sub(2)

    initialized, err = pcall(function()
      base_dir = config.base_dir or (vim.fn.stdpath("data") .. "/site/pack/deps/opt/")
      packages = {}

      bench("load", function()
        root = register("chiyadev/dep")
        register_recursive(config)
        sort_dependencies()
        ensure_acyclic()
      end)

      reload()

      local should_sync = function(package)
        if config.sync == "new" or config.sync == nil then
          return not package.exists
        else
          return config.sync == "always"
        end
      end

      local targets = {}

      for i = 1, #packages do
        local package = packages[i]
        if should_sync(package) then
          targets[#targets + 1] = package
        end
      end

      sync_list(targets)
    end)

    if not initialized then
      logger:log("error", err)
    end
  end,
})
