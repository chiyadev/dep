--
-- Copyright (c) 2022 chiya.dev
--
-- Use of this source code is governed by the MIT License
-- which can be found in the LICENSE file and at:
--
--   https://opensource.org/licenses/MIT
--
local require, type, setmetatable, error, table, assert, math, os, debug =
  require, type, setmetatable, error, table, assert, math, os, debug
local logger = require("dep.log").global

local function parse_name_from_id(id)
  local name = id:match("^[%w-_.]+/([%w-_.]+)$")
  if name then
    return name
  else
    error(string.format('invalid package name "%s"; must be in the format "user/package"', id))
  end
end

local function is_nonempty_str(s)
  return type(s) == "string" and #s ~= 0
end

--- Package information.
local Package = setmetatable({
  __metatable = "Package",
  __index = {
    --- Runs all registered hooks of the given type.
    run_hooks = function(self, hook)
      local hooks = self["on_" .. hook]
      if not hooks or #hooks == 0 then
        return true
      end

      local start = os.clock()
      for i = 1, #hooks do
        local ok, err = xpcall(hooks[i], debug.traceback)
        if not ok then
          return false, err
        end
      end

      local elapsed = os.clock() - start
      self.perf.hooks[hook] = elapsed

      logger:log(
        "hook",
        "triggered %d %s %s for %s in %dms",
        #hooks,
        hook,
        #hooks == 1 and "hook" or "hooks",
        self.id,
        elapsed
      )

      return true
    end,
  },
}, {
  --- Constructs a new `Package` with the given identifier.
  __call = function(mt, id)
    local name = parse_name_from_id(id)
    return setmetatable({
      id = id,
      name = name,
      url = "https://github.com/" .. id .. ".git",
      enabled = true,
      exists = false,
      added = false,
      configured = false,
      loaded = false,
      dependencies = {},
      dependents = {},
      subtree_configured = false,
      subtree_loaded = false,
      on_setup = {},
      on_config = {},
      on_load = {},
      perf = { hooks = {} },
    }, mt)
  end,
})

--- Manages a set of packages.
local PackageStore = setmetatable({
  __metatable = "PackageStore",
  __index = {
    --- Links the given packages such that the parent must load before the child.
    link_dependency = function(self, parent, child)
      if not parent.dependents[child.id] then
        parent.dependents[child.id] = child
        parent.dependents[#parent.dependents + 1] = child
      end

      if not child.dependencies[parent.id] then
        child.dependencies[parent.id] = parent
        child.dependencies[#child.dependencies + 1] = parent
      end
    end,

    --- Ensures the given package spec table is valid.
    validate_spec = function(self, spec)
      assert(spec[1] ~= nil, "package id missing from spec")
      assert(type(spec[1]) == "string", "package id must be a string")
      parse_name_from_id(spec[1])

      assert(spec.as == nil or is_nonempty_str(spec.as), "package name must be a string")
      assert(spec.url == nil or type(spec.url) == "string", "package url must be a string") -- TODO: validate url or path
      assert(spec.branch == nil or is_nonempty_str(spec.branch), "package branch must be a string")
      assert(spec.pin == nil or type(spec.pin) == "boolean", "package pin must be a boolean")
      assert(spec.disable == nil or type(spec.disable) == "boolean", "package disable must be a boolean")

      assert(
        spec.requires == nil or type(spec.requires) == "table" or type(spec.requires) == "string",
        "package requires must be a string or table"
      )
      assert(
        spec.deps == nil or type(spec.deps) == "table" or type(spec.deps) == "string",
        "package deps must be a string or table"
      )

      assert(spec.setup == nil or type(spec.setup) == "function", "package setup must be a function")
      assert(spec.config == nil or type(spec.config) == "function", "package config must be a function")
      assert(spec[2] == nil or type(spec[2]) == "function", "package loader must be a function")
    end,

    --- Creates or updates a package from the given spec table, and returns that package.
    add_spec = function(self, spec, scope)
      self:validate_spec(spec)
      scope = scope or {}

      local id = spec[1]
      local pkg = self[id]

      if not pkg then
        pkg = Package(id)
        self[id], self[#self + 1] = pkg, pkg
      end

      -- blend package spec with existing package info
      pkg.name = spec.as or pkg.name
      pkg.url = spec.url or pkg.url
      pkg.branch = spec.branch or pkg.branch
      pkg.pin = scope.pin or spec.pin or pkg.pin
      pkg.enabled = not scope.disable and not spec.disable and pkg.enabled

      pkg.on_setup[#pkg.on_setup + 1] = spec.setup
      pkg.on_config[#pkg.on_config + 1] = spec.config
      pkg.on_load[#pkg.on_load + 1] = spec[2]

      local requires = type(spec.requires) == "table" and spec.requires or { spec.requires }
      local deps = type(spec.deps) == "table" and spec.deps or { spec.deps }

      -- recursively add specs for dependencies and dependents
      for i = 1, #requires do
        self:link_dependency(self:add_spec(requires[i], scope), pkg)
      end

      for i = 1, #deps do
        self:link_dependency(pkg, self:add_spec(deps[i], scope))
      end
    end,

    --- Adds the given list of specs.
    add_specs = function(self, specs, scope)
      assert(type(specs) == "table", "package list must be a table")
      assert(specs.pin == nil or type(specs.pin) == "boolean", "package list pin must be a boolean")
      assert(specs.disable == nil or type(specs.disable) == "boolean", "package list disable must be a boolean")
      assert(specs.modules == nil or type(specs.modules) == "table", "package list module list must be a table")

      scope = scope or {}
      scope = {
        -- outer scope takes precedence over inner list's overrides
        pin = scope.pin or specs.pin,
        disable = scope.disable or specs.disable,
      }

      -- add specs in spec list
      for i = 1, #specs do
        self:add_spec(specs[i], scope)
      end

      -- recursively add referenced spec list modules
      if specs.modules then
        local prefix = specs.modules.prefix or ""
        for i = 1, #specs.modules do
          local name = specs.modules[i]
          assert(type(name) == "string", "package list inner module name must be a string")
          name = prefix .. name

          local module = require(name)
          assert(type(module) == "table", "package list inner module did not return a spec list table")
          self:add_specs(module, scope)
        end
      end
    end,

    --- Ensures there are no circular dependencies in this package store.
    ensure_acyclic = function(self)
      -- tarjan's strongly connected components algorithm
      local idx, indices, lowlink, stack = 0, {}, {}, {}

      local function connect(pkg)
        indices[pkg.id], lowlink[pkg.id] = idx, idx
        stack[#stack + 1], stack[pkg.id] = pkg, true
        idx = idx + 1

        for i = 1, #pkg.dependents do
          local dependent = pkg.dependents[i]

          if not indices[dependent.id] then
            local cycle = connect(dependent)
            if cycle then
              return cycle
            else
              lowlink[pkg.id] = math.min(lowlink[pkg.id], lowlink[dependent.id])
            end
          elseif stack[dependent.id] then
            lowlink[pkg.id] = math.min(lowlink[pkg.id], indices[dependent.id])
          end
        end

        if lowlink[pkg.id] == indices[pkg.id] then
          local cycle = { pkg }
          local node

          repeat
            node = stack[#stack]
            stack[#stack], stack[node.id] = nil, nil
            cycle[#cycle + 1] = node
          until node == pkg

          -- a node is by definition strongly connected to itself
          -- ignore single-node components unless the package explicitly specified itself as a dependency (i.e. the user is being weird)
          if #cycle > 2 or pkg.dependents[pkg.id] then
            return cycle
          end
        end
      end

      for i = 1, #self do
        local pkg = self[i]

        if not indices[pkg.id] then
          local cycle = connect(pkg)
          if cycle then
            -- found dependency cycle
            local names = {}
            for j = 1, #cycle do
              names[j] = cycle[j].id
            end
            error("circular dependency detected in package dependency graph: " .. table.concat(names, " -> "))
          end
        end
      end
    end,
  },
}, {
  --- Constructs a new `PackageStore`.
  __call = function(mt)
    -- hash part of store maps package ids to packages
    -- array part of store is a list of packages
    -- all packages in a store are unique based on their id
    return setmetatable({}, mt)
  end,
})

return {
  Package = Package,
  PackageStore = PackageStore,
}
