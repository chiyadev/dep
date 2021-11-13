local logger = require("dep/log")
local proc = require("dep/proc")

logger:open()

local base_dir
local packages, package_roots

local function register(arg)
  if type(arg) ~= "table" then
    arg = { arg }
  end

  local id = arg[1]
  local package = packages[id]

  if not package then
    package = {
      id = id,
      enabled = false,
      exists = false,
      added = false,
      configured = false,
      loaded = false,
      on_setup = {},
      on_config = {},
      on_load = {},
      root = true,
      dependencies = {}, -- inward edges
      dependents = {}, -- outward edges
    }

    packages[id] = package
  end

  local prev_dir = package.dir -- optimization

  -- meta
  package.name = arg.as or package.name or id:match("^[%w-_.]+/([%w-_.]+)$")
  package.url = arg.url or package.url or ("https://github.com/" .. id .. ".git")
  package.branch = arg.branch or package.branch
  package.dir = base_dir .. package.name
  package.pin = arg.pin or package.pin
  package.enabled = not arg.disabled and package.enabled

  if prev_dir ~= package.dir then
    package.exists = vim.fn.isdirectory(package.dir) ~= 0
    package.configured = package.exists
  end

  table.insert(package.on_setup, arg.setup)
  table.insert(package.on_config, arg.config)
  table.insert(package.on_load, arg[2])

  for _, req in ipairs(type(arg.requires) == "table" and arg.requires or { arg.requires }) do
    local parent, child = register(req), package
    parent.dependents[child.id] = child
    child.dependencies[parent.id], child.root = parent, false
  end

  for _, dep in ipairs(type(arg.deps) == "table" and arg.deps or { arg.deps }) do
    local parent, child = package, register(dep)
    parent.dependents[child.id] = child
    child.dependencies[parent.id], child.root = parent, false
  end
end

local function register_recursive(list)
  for _, arg in ipairs(list) do
    register(arg)
  end

  for _, module in ipairs(list.modules or {}) do
    if type(module) == "string" then
      module = require(module)
    end

    register_recursive(module)
  end
end

local function find_cycle()
  local index = 0
  local indexes = {}
  local lowlink = {}
  local set = {}
  local stack = {}

  local function connect(package)
    indexes[package.id], lowlink[package.id], set[package.id] = index, index, true
    index = index + 1
    table.insert(stack, package)

    for _, dependent in pairs(package.dependents) do
      if indexes[dependent.id] == nil then
        local cycle = connect(dependent)
        if cycle then
          return cycle
        else
          lowlink[package.id] = math.min(lowlink[package.id], lowlink[dependent.id])
        end
      elseif set[dependent.id] then
        lowlink[package.id] = math.min(lowlink[package.id], indexes[dependent.id])
      end
    end

    if lowlink[package.id] == indexes[package.id] then
      local cycle = { package }
      local node

      repeat
        node = table.remove(stack)
        set[node.id] = nil
        table.insert(cycle, node)
      until node == package

      -- only consider multi-node components
      if #cycle > 2 then
        return cycle
      end
    end
  end

  for _, package in pairs(packages) do
    if indexes[package.id] == nil then
      local cycle = connect(package)
      if cycle then
        return cycle
      end
    end
  end
end

local function find_roots()
  for _, package in pairs(packages) do
    if package.root then
      table.insert(package_roots, package)
    end
  end
end

local function run_hooks(package, type)
  for _, cb in ipairs(package["on_" .. type]) do
    local ok, err = pcall(cb)
    if not ok then
      return false, err
    end
  end

  return true
end

local function ensure_added(package)
  if not package.added then
    local ok, err = pcall(vim.cmd, "packadd " .. package.name)
    if ok then
      package.added = true
    else
      return false, err
    end
  end

  return true
end

local function configure_recursive(package, force)
  if not package.exists or not package.enabled then
    return
  end

  if not package.configured or force then
    local ok, err = run_hooks(package, "setup")
    if not ok then
      logger:log("error", string.format("failed to set up %s; reason: %s", package.id, err))
      return
    end

    ok, err = ensure_added(package)
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    ok, err = run_hooks(package, "config")
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    package.configured, package.loaded = true, false
    force = true
  end

  for _, dependent in pairs(package.dependents) do
    configure_recursive(dependent, force)
  end
end

local function load_recursive(package, force)
  if not package.exists or not package.enabled then
    return
  end

  if not package.loaded or force then
    local ok, err = ensure_added(package)
    if not ok then
      logger:log("error", string.format("failed to configure %s; reason: %s", package.id, err))
      return
    end

    ok, err = run_hooks(package, "load")
    if not ok then
      logger:log("error", string.format("failed to load %s; reason: %s", package.id, err))
      return
    end

    package.loaded = true
    force = true
  end

  for _, dependent in pairs(package.dependents) do
    load_recursive(dependent, force)
  end
end

local function reload_meta()
  vim.cmd([[
    silent! helptags ALL
    silent! UpdateRemotePlugins
  ]])
end

local function reload_all()
  for _, package in pairs(package_roots) do
    configure_recursive(package)
  end

  for _, package in pairs(package_roots) do
    load_recursive(package)
  end

  reload_meta()
end

local function clean()
  vim.loop.fs_scandir(base_dir, function(err, handle)
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

      for _, package in pairs(packages) do
        queue[package.name] = nil
      end

      for name, dir in pairs(queue) do
        -- todo: make this async
        local ok = vim.fn.delete(dir, "rf")
        if not ok then
          logger:log("error", string.format("failed to delete %s", name))
        end
      end
    end
  end)
end

local function sync(package, cb)
  if not package.enabled then
    return
  end

  if package.exists then
    if package.pin then
      return
    end

    local function cb_err(err)
      logger:log("error", string.format("failed to update %s; reason: %s", package.id, err))
      cb(err)
    end

    proc.git_current_commit(package.dir, function(err, before)
      if err then
        cb_err(before)
      else
        proc.git_fetch(package.dir, package.branch or "HEAD", function(err, message)
          if err then
            cb_err(message)
          else
            proc.git_reset(package.dir, package.branch or "HEAD", function(err, message)
              if err then
                cb_err(message)
              else
                proc.get_current_commit(package.dir, function(err, after)
                  if err then
                    cb_err(after)
                  else
                    if before == after then
                      logger:log("skip", string.format("skipped %s", package.id))
                    else
                      package.added, package.configured = false, false
                      logger:log("update", string.format("updated %s", package.id))
                    end
                  end
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
        package.exists, package.added, package.configured = true, false, false
        logger:log("install", string.format("installed %s", package.id))
      end
    end)
  end
end

local function sync_list(list)
  local progress = 0

  for _, package in ipairs(list) do
    sync(package, function(err)
      progress = progress + 1
      if progress == #list then
        clean()
        reload_all()
      end
    end)
  end
end

vim.cmd([[
  command! DepSync lua require("dep").sync()
  command! DepList lua require("dep").list()
  command! DepClean lua require("dep").clean()
  command! DepLog lua require("dep").open_log()
]])

--todo: prevent multiple execution of async routines
return setmetatable({
  sync = function()
    local targets = {}

    for _, package in pairs(packages) do
      table.insert(targets, package)
    end

    sync_list(targets)
  end,

  open_log = function()
    vim.cmd("sp " .. logger.path)
  end,
}, {
  __call = function(config)
    base_dir = config.base_dir or (vim.fn.stdpath("data") .. "/site/pack/deps/start/")
    packages, package_roots = {}, {}

    register_recursive({ "chiyadev/dep", modules = { config } })

    local cycle = find_cycle()
    if cycle then
      local names = {}
      for _, package in ipairs(cycle) do
        table.insert(names, package.id)
      end
      error("circular dependency detected in package graph: " .. table.concat(names, " -> "))
    end

    find_roots()
    reload_all()

    local should_sync = function(package)
      if config.sync == "new" or config.sync == nil then
        return not package.exists
      else
        return config.sync == "always"
      end
    end

    local targets = {}

    for _, package in pairs(packages) do
      if should_sync(package) then
        table.insert(targets, package)
      end
    end

    sync_list(targets)
  end,
})
