# dep

> This readme is a work in progress.

A versatile, declarative and correct [neovim][2] package manager in [lua][3].
Written for personal use by [phosphene47][4].

What does that mean?

1. `versatile` - packages can be declared in any lua file in any order of your liking.
2. `declarative` - packages are declared using simple lua tables.
3. `correct` - packages are always loaded in a correct and consistent order.

Read [this blog post][1] for context.

## Requirements

- [neovim][2] 0.5+
- [git][5]

## Setup

1. Create `lua/bootstrap.lua` in your neovim config directory.

```lua
-- ~/.config/nvim/lua/bootstrap.lua:
-- automatically install `chiyadev/dep` on startup
local path = vim.fn.stdpath("data") .. "/site/pack/deps/opt/dep"

if vim.fn.empty(vim.fn.glob(path)) > 0 then
  vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/chiyadev/dep", path })
end

vim.cmd("packadd dep")
```

2. In `init.lua`, call `dep` with an array of package specifications.

```lua
require "bootstrap"
require "dep" {
  -- list of package specs...
}
```

## Commands

- `:DepSync` - installs new packages, updates packages to the latest versions,
  cleans removed packages and reloads packages as necessary.
- `:DepClean` - cleans removed packages.
- `:DepReload` - reloads all packages.
- `:DepList` - prints the package list, performance metrics and dependency graphs.
- `:DepLog` - opens the log file.
- `:DepConfig` - opens the file that called dep, for convenience.

## Package specification

A package must be declared in the following format.

```lua
{
  -- [string] Specifies the full name of the package.
  -- This is the only required field; all other fields are optional.
  "user/package",

  -- [function] Code to run after the package is loaded into neovim.
  function()
    require "package".setup(...)
  end,

  -- [function] Code to run before the package is loaded into neovim.
  setup = function()
    vim.g.package_config = ...
  end,

  -- [function] Code to run after the package is installed or updated.
  config = function()
    os.execute(...)
  end,

  -- [string] Overrides the short name of the package.
  -- Defaults to a substring of the full name after '/'.
  as = "custom_package",

  -- [string] Overrides the URL of the git repository to clone.
  -- Defaults to "https://github.com/{full_name}.git".
  url = "https://git.chiya.dev/user/package.git",

  -- [string] Overrides the name of the branch to clone.
  -- Defaults to whatever the remote configured as their HEAD, which is usually "master".
  branch = "develop",

  -- [boolean] Prevents the package from being loaded.
  disable = true,

  -- [boolean] Prevents the package from being updated.
  pin = true,

  -- [string|array] Specifies dependencies that must be loaded before the package.
  -- If given a string, it is wrapped into an array.
  requires = {...},

  -- [string|array] Specifies dependents that must be loaded after the package.
  -- If given a string, it is wrapped into an array.
  deps = {...}
}
```

When a string is given where a package specification table is expected,
it is assumed to be the package's full name.

```lua
require "dep" {
  -- these two are equivalent
  "user/package",
  { "user/package" },
}
```

A package can be declared multiple times. Multiple declarations of the same package are
combined into one. This is useful when declaring dependencies, which is explored later.

```lua
require "dep" {
  {
    "user/package",
    requires = "user/dependency",
    disabled = true,
    config = function()
      print "my config hook"
    end
  },
  {
    "user/package",
    requires = "user/another_dependency",
    deps = "user/dependent",
    disabled = false,
    config = function()
      os.execute("make")
    end
  }
}

-- the above is equivalent to
require "dep" {
  {
    "user/package",
    requires = { "user/dependency", "user/another_dependency" },
    deps = "user/dependent",
    disabled = true,
    config = function()
      print "my config hook"
      os.execute("make")
    end
  }
}
```

## Declaring dependencies

The dependencies and dependents declared in a package specification are themselves
package specifications. If a dependency or dependent is declared multiple times,
they are combined into one just like normal package specifications.

```lua
require "dep" {
  {
    "user/package",
    requires = {
      {
        "user/dependency1",
        requires = "user/dependency2"
      }
    }
  }
}

-- the above is equivalent to
require "dep" {
  {
    "user/dependency2",
    deps = {
      {
        "user/dependency1",
        deps = "user/package"
      }
    }
  }
}

-- which is equivalent to
require "dep" {
  {
    "user/dependency1",
    requires = "user/dependency2",
    deps = "user/package"
  }
}

-- which is equivalent to
require "dep" {
  {
    "user/dependency1",
    requires = "user/dependency2"
  },
  {
    "user/package",
    requires = "user/dependency1"
  }
}

-- which is equivalent to
require "dep" {
  {
    "user/dependency2",
    deps = "user/dependency1"
  },
  {
    "user/dependency1",
    deps = "user/package"
  }
}

-- all of the above are guaranteed to load in the following order: dependency2, dependency1, package
```

If dep detects a circular dependency cycle, it reports the problematic packages
instead of hanging or crashing.

```lua
-- this throws an error saying package1 depends on package2 which depends on package1
require "dep" {
  {
    "user/package1",
    requires = "user/package2"
  },
  {
    "user/package2",
    requires = "user/package1"
  }
}
```

A dependency can be marked as disabled, which disables all dependents automatically.

```lua
require "dep" {
  {
    "user/dependency",
    disabled = true
  },
  {
    "user/package1",
    disabled = true, -- implied
    requires = "user/dependency"
  },
  {
    "user/package2",
    disabled = true, -- implied
    requires = "user/dependency"
  }
}
```

If a dependency fails to load for some reason, all of its dependents are guaranteed to not load.

```lua
require "dep" {
  {
    "user/problematic",
    function()
      error("bad hook")
    end
  },
  {
    "user/dependent",
    requires = "user/problematic",
    function()
      print "unreachable"
    end
  }
}
```

## Separating code into modules

Suppose you split your `init.lua` into two files `packages/search.lua` and
`packages/vcs.lua`, which declare the packages [telescope.nvim][6] and [vim-fugitive][7] respectively.

```lua
-- ~/.config/nvim/lua/packages/search.lua:
return {
  {
    "nvim-telescope/telescope.nvim",
    requires = "nvim-lua/plenary.nvim"
  }
}
```

```lua
-- ~/.config/nvim/lua/packages/vcs.lua:
return {
  "tpope/vim-fugitive"
}
```

Package specifications from other modules can be loaded using the `modules` option.

```lua
require "dep" {
  modules = {
    prefix = "packages.",
    "search",
    "vcs"
  }
}

-- the above is equivalent to
require "dep" {
  modules = {
    "packages.search",
    "packages.vcs"
  }
}

-- which is equivalent to
local packages = {}

for _, package in ipairs(require "packages.search") do
  table.insert(packages, package)
end

for _, package in ipairs(require "packages.vcs") do
  table.insert(packages, package)
end

require("dep")(packages)

-- which is ultimately equivalent to
require "dep" {
  {
    "nvim-telescope/telescope.nvim",
    requires = "nvim-lua/plenary.nvim"
  },
  "tpope/vim-fugitive"
}

-- all of the above are guaranteed to load plenary.nvim before telescope.nvim.
-- order of telescope.nvim and vim-fugitive is consistent but unspecified.
```

Entire modules can be marked as disabled, which disables all top-level packages declared in that module.

```lua
return {
  disable = true,
  {
    "user/package",
    disabled = true, -- implied by module
    requires = {
      {
        "user/dependency",
        -- disabled = true -- not implied
      }
    },
    deps = {
      {
        "user/dependent",
        disabled = true -- implied by dependency
      }
    }
  }
}
```

## Miscellaneous configuration

dep accepts configuration parameters as named fields in the package list.

```lua
require "dep" {
  -- [string] Specifies when dep should automatically synchronize.
  -- "never": disable this behavior
  -- "new": only install newly declared packages (default)
  -- "always": synchronize all packages on startup
  sync = "new",

  -- [array] Specifies the modules to load package specifications from.
  -- Defaults to an empty table.
  -- Items can be either an array of package specifications,
  -- or a string that indicates the name of the module from which the array of package specifications is loaded.
  modules = {
    -- [string] Prefix string to prepend to all module names.
    prefix = "",
  },

  -- list of package specs...
}
```

## License

dep is licensed under the [MIT License](LICENSE).

[1]: https://chiya.dev/posts/2021-11-27-why-package-manager
[2]: https://neovim.io/
[3]: https://www.lua.org/
[4]: https://github.com/phosphene47
[5]: https://git-scm.com/
[6]: https://github.com/nvim-telescope/telescope.nvim
[7]: https://github.com/tpope/vim-fugitive
