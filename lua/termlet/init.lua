local M = {}

-- Load menu module
local menu = require("termlet.menu")

-- Load stacktrace module
local stacktrace = require("termlet.stacktrace")

-- Load highlight module
local highlight = require("termlet.highlight")

-- Load keybindings module
local keybindings = require("termlet.keybindings")

-- Load history module
local history = require("termlet.history")

-- Load filter module
local filter = require("termlet.filter")

-- Load filter UI module
local filter_ui = require("termlet.filter_ui")

-- Default configuration
local config = {
  scripts = {},
  root_dir = nil, -- Global root directory for script searching
  terminal = {
    height_ratio = 0.16, -- 1/6 of screen height
    width_ratio = 1.0, -- full width
    border = "rounded", -- string preset or table of 8 border characters
    position = "bottom", -- "bottom", "center", "top"
    highlights = {
      border = "FloatBorder",
      title = "Title",
      background = "NormalFloat",
    },
    title_format = " {icon} {name} ",
    title_icon = "",
    title_pos = "center", -- "left", "center", "right"
    show_status = false,
    status_icons = {
      running = "●",
      success = "✓",
      error = "✗",
    },
    output_persistence = "none", -- "none" | "buffer"
    max_saved_buffers = 5, -- Maximum number of hidden buffers to keep
    focus = "previous", -- "terminal" | "previous" | "none" - where to place focus after opening terminal
    auto_insert = false, -- Auto-enter insert mode when focus="terminal"
    filters = {
      enabled = false, -- Enable output filtering
      show_only = {}, -- Only show lines matching these patterns
      hide = {}, -- Hide lines matching these patterns
      highlight = {}, -- Custom highlighting rules: { pattern = "ERROR", color = "#ff0000" }
    },
  },
  search = {
    exclude_dirs = {
      "node_modules",
      ".git",
      ".svn",
      ".hg",
      "dist",
      "build",
      "target",
      "__pycache__",
      ".cache",
      ".tox",
      ".mypy_cache",
      ".pytest_cache",
      "vendor",
      "venv",
      ".venv",
      "env",
    },
    exclude_hidden = true,
    exclude_patterns = {},
    max_depth = 5, -- Maximum recursion depth for searching
  },
  menu = {
    width_ratio = 0.6,
    height_ratio = 0.5,
    border = "rounded",
    title = " TermLet Scripts ",
  },
  stacktrace = {
    enabled = true, -- Enable stack trace detection
    languages = {}, -- Languages to detect (empty = all)
    custom_parsers = {}, -- Custom parser definitions
    parser_order = { "custom", "builtin" }, -- Parser priority
    buffer_size = 50, -- Lines to keep in buffer for multi-line detection
    highlight = {
      enabled = true, -- Enable visual highlighting of file paths
      style = "underline", -- "underline", "color", "both", "none"
      hl_group = "TermLetStackTracePath", -- Custom highlight group
    },
  },
  history = {
    enabled = true, -- Enable execution history tracking
    max_entries = 50, -- Maximum number of history entries to keep
  },
  debug = false,
}

-- Store active terminal windows for cleanup
local active_terminals = {}

-- Store saved terminal buffers for output persistence
local saved_buffers = {}

-- Store active filters per buffer
local active_filters = {}

-- Store original script-level filter config per buffer (preserved across preset changes)
local original_script_filters = {}

-- Literal string replacement to avoid Lua pattern issues with special chars
-- Replaces ALL occurrences of placeholder in str
local function replace_placeholder(str, placeholder, replacement)
  local result = str
  local search_start = 1
  while true do
    local start, finish = result:find(placeholder, search_start, true)
    if not start then
      break
    end
    result = result:sub(1, start - 1) .. replacement .. result:sub(finish + 1)
    search_start = start + #replacement
  end
  return result
end

-- Format terminal title using config placeholders
local function format_terminal_title(term_config, name, status)
  local title = term_config.title_format or " {icon} {name} "

  local icon = term_config.title_icon or ""
  title = replace_placeholder(title, "{icon}", icon)
  title = replace_placeholder(title, "{name}", name or "Terminal")

  local status_text = ""
  if term_config.show_status and status then
    local icons = term_config.status_icons or {}
    status_text = icons[status] or ""
  end
  title = replace_placeholder(title, "{status}", status_text)

  -- Trim trailing whitespace when status placeholder was empty
  title = title:gsub("%s+$", " ")

  return title
end

-- Update terminal title with exit status (extracted for testability)
local function update_terminal_status(win, exit_code)
  local term_data = active_terminals[win]
  if not term_data then
    return false
  end
  if not term_data.term_config.show_status then
    return false
  end
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local status = exit_code == 0 and "success" or "error"
  local new_title = format_terminal_title(term_data.term_config, term_data.name, status)
  vim.api.nvim_win_set_config(win, { title = new_title })
  return true
end

-- Expose for testing
M._format_terminal_title = format_terminal_title
M._update_terminal_status = update_terminal_status

-- Utility function for debug logging
local function debug_log(msg)
  if config.debug then
    print("[TermLet] " .. msg)
  end
end

-- Check if a directory should be excluded from search
local function should_exclude_dir(name, search_config)
  search_config = search_config or config.search

  if search_config.exclude_hidden and name:match("^%.") then
    return true
  end

  for _, excluded in ipairs(search_config.exclude_dirs or {}) do
    if name == excluded then
      return true
    end
  end

  return false
end

-- Check if a filename matches any exclusion pattern (glob-style)
local function should_exclude_file(name, search_config)
  search_config = search_config or config.search

  for _, pattern in ipairs(search_config.exclude_patterns or {}) do
    -- Escape all Lua pattern metacharacters first, then convert glob wildcards
    local lua_pattern = pattern:gsub("([%(%)%.%%%+%-%[%]%^%$])", "%%%1")
    lua_pattern = "^" .. lua_pattern:gsub("%*", ".*"):gsub("%?", ".") .. "$"
    if name:match(lua_pattern) then
      return true
    end
  end

  return false
end

-- Expose for testing
M._should_exclude_dir = should_exclude_dir
M._should_exclude_file = should_exclude_file

-- Compute floating window geometry and build nvim_open_win options table
local function compute_win_opts(term_config, title)
  local height = math.floor(vim.o.lines * term_config.height_ratio)
  local width = math.floor(vim.o.columns * term_config.width_ratio)

  local row
  if term_config.position == "center" then
    row = math.floor((vim.o.lines - height) / 2)
  elseif term_config.position == "top" then
    row = 1
  else -- bottom (default)
    row = vim.o.lines - height - 2
  end

  local col = math.floor((vim.o.columns - width) / 2)

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    anchor = "NW",
    style = "minimal",
    border = term_config.border,
    title = title,
    title_pos = term_config.title_pos or "center",
  }
end

-- Apply winhighlight groups to a window
local function apply_win_highlights(win, highlights)
  if highlights then
    vim.api.nvim_set_option_value(
      "winhighlight",
      "Normal:"
        .. (highlights.background or "NormalFloat")
        .. ",FloatBorder:"
        .. (highlights.border or "FloatBorder")
        .. ",FloatTitle:"
        .. (highlights.title or "Title"),
      { win = win }
    )
  end
end

-- Improved terminal window creation with better error handling
function M.create_floating_terminal(opts)
  opts = opts or {}

  local term_config = vim.tbl_deep_extend("force", config.terminal, opts)

  -- Validate title_pos
  local valid_title_pos = { left = true, center = true, right = true }
  if term_config.title_pos and not valid_title_pos[term_config.title_pos] then
    vim.notify(
      "[TermLet] Invalid title_pos '"
        .. tostring(term_config.title_pos)
        .. "', falling back to 'center'. Valid values: left, center, right",
      vim.log.levels.WARN
    )
    term_config.title_pos = "center"
  end

  -- Validate border table length
  if type(term_config.border) == "table" and #term_config.border ~= 8 then
    vim.notify(
      "[TermLet] Custom border table must have exactly 8 characters, got "
        .. #term_config.border
        .. ". Falling back to 'rounded'.",
      vim.log.levels.WARN
    )
    term_config.border = "rounded"
  end

  -- Create buffer and window
  local buf = vim.api.nvim_create_buf(false, true)
  if not buf then
    vim.notify("Failed to create terminal buffer", vim.log.levels.ERROR)
    return nil
  end

  -- Build formatted title
  local name = opts.title or "Terminal"
  local initial_status = term_config.show_status and "running" or nil
  local title = format_terminal_title(term_config, name, initial_status)

  local win_opts = compute_win_opts(term_config, title)

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  if not win then
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.notify("Failed to create terminal window", vim.log.levels.ERROR)
    return nil
  end

  -- Apply highlight groups
  apply_win_highlights(win, term_config.highlights)

  -- Set buffer options based on output_persistence setting
  local bufhidden_value = "wipe"
  if term_config.output_persistence == "buffer" then
    bufhidden_value = "hide"
  end
  vim.api.nvim_set_option_value("bufhidden", bufhidden_value, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "terminal", { buf = buf })
  vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
  -- Store reference for cleanup (table for status title updates)
  active_terminals[win] = {
    buf = buf,
    name = name,
    term_config = term_config,
    original_win = opts.original_win, -- Track original window if provided
  }

  -- Auto-cleanup on window close
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    callback = function()
      active_terminals[win] = nil

      -- Clear active filters, original script config, and cached original lines for this buffer
      active_filters[buf] = nil
      original_script_filters[buf] = nil
      filter.discard_cache(buf)

      -- Handle output persistence
      if term_config.output_persistence == "buffer" and vim.api.nvim_buf_is_valid(buf) then
        -- Save buffer metadata for later retrieval
        table.insert(saved_buffers, 1, {
          buf = buf,
          name = name,
          timestamp = os.time(),
        })

        -- Enforce max_saved_buffers limit
        local max_buffers = term_config.max_saved_buffers or 5
        while #saved_buffers > max_buffers do
          local old_entry = table.remove(saved_buffers)
          if old_entry and old_entry.buf and vim.api.nvim_buf_is_valid(old_entry.buf) then
            vim.api.nvim_buf_delete(old_entry.buf, { force = true })
          end
        end
      end
    end,
    once = true,
  })

  return buf, win
end

-- Find script by filename, searching from a specified root directory
-- Supports:
--   1. Absolute paths (starting with / or ~) - used directly
--   2. Relative paths with directory components (e.g., "subdir/script.sh") - resolved from root
--   3. Plain filenames (e.g., "build.sh") - searched recursively from root
function M.find_script_by_name(filename, root_dir, search_dirs)
  if not filename then
    debug_log("Missing filename")
    return nil
  end

  -- Expand ~ in filename for absolute path detection
  local expanded_filename = vim.fn.expand(filename)

  -- Check if filename is an absolute path
  if expanded_filename:sub(1, 1) == "/" then
    debug_log("Filename is an absolute path: " .. expanded_filename)
    if vim.fn.filereadable(expanded_filename) == 1 then
      debug_log("Found script at absolute path: " .. expanded_filename)
      return expanded_filename
    end
    debug_log("Absolute path not found: " .. expanded_filename)
    return nil
  end

  -- Determine root directory
  local search_root
  if root_dir then
    -- Use provided root directory
    search_root = vim.fn.expand(root_dir)
    if vim.fn.isdirectory(search_root) == 0 then
      debug_log("Specified root directory does not exist: " .. search_root)
      return nil
    end
  else
    -- Fallback to current file's directory if no root specified
    local current_file = vim.fn.expand("%:p")
    if current_file == "" then
      debug_log("No current file and no root directory specified")
      return nil
    end
    search_root = vim.fn.fnamemodify(current_file, ":h")
  end

  debug_log("Starting search from root: " .. search_root)

  -- Default search directories if none specified
  search_dirs = search_dirs
    or {
      "scripts",
      "bin",
      "tools",
      "build",
      ".scripts",
      "dev",
      "development",
      "utils",
      "automation",
    }

  -- Get maximum search depth from config
  local max_search_depth = config.search.max_depth or 5

  -- Function to recursively search for file in a directory
  local function search_in_dir(dir_path, target_file, max_depth)
    max_depth = max_depth or max_search_depth
    if max_depth <= 0 then
      return nil
    end

    -- Check if the target file itself is excluded by patterns
    if should_exclude_file(target_file, config.search) then
      debug_log("Skipping excluded target file: " .. target_file)
      return nil
    end

    local full_path = dir_path .. "/" .. target_file
    if vim.fn.filereadable(full_path) == 1 then
      debug_log("Found script at: " .. full_path)
      return full_path
    end

    -- Search in subdirectories
    local handle = vim.loop.fs_scandir(dir_path)
    if handle then
      while true do
        local name, type = vim.loop.fs_scandir_next(handle)
        if not name then
          break
        end

        if type == "directory" then
          if should_exclude_dir(name, config.search) then
            debug_log("Skipping excluded directory: " .. dir_path .. "/" .. name)
          else
            local sub_path = dir_path .. "/" .. name
            local result = search_in_dir(sub_path, target_file, max_depth - 1)
            if result then
              return result
            end
          end
        elseif type == "file" and should_exclude_file(name, config.search) then
          debug_log("Skipping excluded file: " .. dir_path .. "/" .. name)
        end
      end
    end

    return nil
  end

  -- First, try direct path relative to root (handles both plain filenames
  -- and relative paths with directory components like "subdir/script.sh")
  if not should_exclude_file(filename, config.search) then
    local direct_path = search_root .. "/" .. filename
    if vim.fn.filereadable(direct_path) == 1 then
      debug_log("Found script directly at: " .. direct_path)
      return direct_path
    end
  else
    debug_log("Skipping excluded file in direct search: " .. filename)
  end

  -- Extract the basename for recursive searching
  -- This allows "subdir/build.sh" to find "build.sh" anywhere in root tree
  local basename = vim.fn.fnamemodify(filename, ":t")

  -- Then search in common script directories within root
  for _, search_dir in ipairs(search_dirs) do
    local search_path = search_root .. "/" .. search_dir
    if vim.fn.isdirectory(search_path) == 1 then
      debug_log("Searching in directory: " .. search_path)
      local result = search_in_dir(search_path, basename, max_search_depth)
      if result then
        return result
      end
    end
  end

  -- Finally, do a recursive search from root (as fallback)
  debug_log("Doing recursive search from root: " .. search_root)
  local result = search_in_dir(search_root, basename, max_search_depth)
  if result then
    return result
  end

  debug_log("Script '" .. filename .. "' not found in root directory: " .. search_root)
  return nil
end

-- Backwards compatibility - find script by directory name and relative path
function M.find_script(dir_name, relative_path)
  if not dir_name or not relative_path then
    debug_log("Missing dir_name or relative_path")
    return nil
  end

  local current_file = vim.fn.expand("%:p")
  if current_file == "" then
    debug_log("No current file")
    return nil
  end

  local path = vim.fn.fnamemodify(current_file, ":h")
  debug_log("Starting search from: " .. path)

  local max_depth = 20
  local depth = 0

  while path ~= "/" and depth < max_depth do
    local folder = vim.fn.fnamemodify(path, ":t")
    debug_log("Checking: " .. path .. " (dir: " .. folder .. ")")

    if folder == dir_name then
      local script_path = path .. "/" .. relative_path
      debug_log("Found target folder. Looking for script at: " .. script_path)

      if vim.fn.filereadable(script_path) == 1 then
        debug_log("Script found at: " .. script_path)
        return script_path
      else
        debug_log("Script not found at: " .. script_path)
      end
    end

    path = vim.fn.fnamemodify(path, ":h")
    depth = depth + 1
  end

  debug_log("Directory named '" .. dir_name .. "' not found after " .. depth .. " iterations")
  return nil
end

-- Improved script execution with better error handling
local function execute_script(script)
  -- Save the current window BEFORE doing anything else
  local original_win = vim.api.nvim_get_current_win()

  local full_path

  -- Determine how to find the script
  if script.filename then
    -- New method: find by filename from root directory
    full_path = M.find_script_by_name(script.filename, script.root_dir, script.search_dirs)
  elseif script.dir_name and script.relative_path then
    -- Legacy method: find by directory name and relative path
    full_path = M.find_script(script.dir_name, script.relative_path)
  else
    vim.notify(
      "Script '"
        .. script.name
        .. "' must specify either 'filename' (with optional 'root_dir') or both 'dir_name' and 'relative_path'",
      vim.log.levels.ERROR
    )
    return false
  end

  if not full_path then
    local search_info = script.filename
        and ("filename: " .. script.filename .. (script.root_dir and (", root: " .. script.root_dir) or ""))
      or ("dir: " .. script.dir_name .. ", path: " .. script.relative_path)
    vim.notify("Script '" .. script.name .. "' not found (" .. search_info .. ")", vim.log.levels.ERROR)
    return false
  end

  local cwd = vim.fn.fnamemodify(full_path, ":h")
  local script_name = vim.fn.fnamemodify(full_path, ":t")

  -- Create terminal with script name as title, passing original window
  local buf, win = M.create_floating_terminal({
    title = script.name or script_name,
    original_win = original_win,
  })

  if not buf or not win then
    return false
  end

  -- Clear stacktrace buffer and all metadata for new execution.
  -- We use clear_all_metadata() rather than clear_metadata(buf) because Neovim
  -- can recycle buffer IDs, so stale metadata from previous buffers may persist.
  if config.stacktrace.enabled then
    stacktrace.clear_buffer()
    stacktrace.clear_all_metadata()
    -- Clear any previous highlights from the buffer
    if buf and vim.api.nvim_buf_is_valid(buf) then
      highlight.clear_buffer(buf)
    end
  end

  -- Store filters for this buffer
  local script_filters = vim.tbl_deep_extend("force", config.terminal.filters or {}, script.filters or {})
  active_filters[buf] = script_filters
  original_script_filters[buf] = vim.deepcopy(script_filters)

  -- Determine command based on file extension or explicit command
  local cmd = script.cmd or ("./" .. script_name)

  debug_log("Executing: " .. cmd .. " in " .. cwd)

  -- Track start time for history
  local start_time = vim.loop.hrtime()

  -- Run the command in the terminal.
  -- Note: termopen() creates a pseudo-terminal (PTY), which merges stdout and
  -- stderr into a single stream. on_stderr is never called with termopen().
  -- All output (including stderr) arrives through on_stdout.
  local job_id = vim.fn.termopen(cmd, {
    cwd = cwd,
    on_exit = function(_, code)
      local msg = script.name .. " exited with code " .. code
      local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
      vim.schedule(function()
        vim.notify(msg, level)
        update_terminal_status(win, code)
        -- After process exits, scan the terminal buffer for stack traces.
        -- This is the most reliable detection method because Neovim strips
        -- ANSI escape codes from terminal buffer content read via the API,
        -- and line numbers are accurate 1-indexed values matching cursor positions.
        if config.stacktrace.enabled and buf and vim.api.nvim_buf_is_valid(buf) then
          stacktrace.clear_metadata(buf)
          highlight.clear_buffer(buf)
          stacktrace.scan_buffer_for_stacktraces(buf, cwd)
        end
        -- Record execution in history
        if config.history.enabled then
          local end_time = vim.loop.hrtime()
          local execution_time = (end_time - start_time) / 1e9 -- Convert to seconds
          history.add_entry({
            script_name = script.name,
            exit_code = code,
            execution_time = execution_time,
            timestamp = os.time(),
            working_dir = cwd,
            script = {
              name = script.name,
              filename = script.filename,
              root_dir = script.root_dir,
              dir_name = script.dir_name,
              relative_path = script.relative_path,
              cmd = script.cmd,
              search_dirs = script.search_dirs,
              description = script.description,
            },
          })
        end
        -- Apply filters after process completes
        if active_filters[buf] and active_filters[buf].enabled and buf and vim.api.nvim_buf_is_valid(buf) then
          filter.apply_filters(buf, active_filters[buf])
        end
      end)
    end,
    on_stdout = function(_, data)
      -- Process stdout for real-time stack trace detection.
      -- ANSI escape codes are stripped before pattern matching.
      if config.stacktrace.enabled then
        stacktrace.process_terminal_output(data, cwd, buf)
      end
      -- Call user-defined callback if provided
      if script.on_stdout then
        script.on_stdout(data)
      end
    end,
  })

  if job_id <= 0 then
    vim.notify("Failed to start " .. script.name, vim.log.levels.ERROR)
    vim.api.nvim_win_close(win, true)
    return false
  end

  -- Handle focus based on configuration
  local focus_mode = config.terminal.focus
  if focus_mode == "previous" then
    -- Return focus to the original window
    if original_win and vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    else
      -- Try to find any valid non-floating window
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local win_config = vim.api.nvim_win_get_config(w)
        if (not win_config.relative or win_config.relative == "") and vim.api.nvim_win_is_valid(w) and w ~= win then
          vim.api.nvim_set_current_win(w)
          break
        end
      end
    end
  elseif focus_mode == "terminal" then
    -- Stay in terminal window
    vim.api.nvim_set_current_win(win)
    -- Optionally enter insert mode
    if config.terminal.auto_insert then
      vim.cmd("startinsert")
    end
  end
  -- focus_mode == "none" means don't change focus (already in terminal)

  return true
end

-- Track previously applied keybindings so they can be removed on reapply
local applied_keybindings = {} -- { key = script_name }

-- Apply keybindings from saved configuration
local function apply_keybindings()
  -- Remove previously applied keybindings
  for key, _ in pairs(applied_keybindings) do
    pcall(vim.keymap.del, "n", key)
    debug_log("Removed old keybinding: " .. key)
  end
  applied_keybindings = {}

  local saved_keybindings = keybindings.get_keybindings()

  for _, script in ipairs(config.scripts) do
    local key = saved_keybindings[script.name]
    if key and key ~= "" then
      -- Create keybinding for this script
      local function_name = "run_" .. script.name:gsub("[%s%-%.]", "_"):gsub("_+", "_"):lower()
      local run_func = M[function_name]

      if run_func then
        pcall(function()
          vim.keymap.set("n", key, run_func, {
            noremap = true,
            silent = true,
            desc = "TermLet: " .. (script.description or script.name),
          })
        end)
        applied_keybindings[key] = script.name
        debug_log("Applied keybinding " .. key .. " for script: " .. script.name)
      end
    end
  end
end

-- Improved setup function with validation
function M.setup(user_config)
  -- Validate and merge configuration
  if user_config then
    config = vim.tbl_deep_extend("force", config, user_config)
  end

  -- Validate output_persistence config value
  local valid_persistence = { none = true, buffer = true }
  if config.terminal.output_persistence and not valid_persistence[config.terminal.output_persistence] then
    vim.notify(
      "[TermLet] Invalid output_persistence '"
        .. tostring(config.terminal.output_persistence)
        .. "', falling back to 'none'. Valid values: none, buffer",
      vim.log.levels.WARN
    )
    config.terminal.output_persistence = "none"
  end

  -- Clean up saved buffers if output_persistence changed to "none"
  if config.terminal.output_persistence == "none" and #saved_buffers > 0 then
    M.clear_outputs()
  end

  -- Initialize stacktrace module with configuration
  stacktrace.setup(config.stacktrace)

  -- Initialize highlight module with configuration
  if config.stacktrace and config.stacktrace.highlight then
    highlight.setup(config.stacktrace.highlight)
  end

  -- Initialize history module with configuration
  if config.history and config.history.max_entries then
    history.set_max_entries(config.history.max_entries)
  end

  -- Initialize filter module with configuration
  filter.setup(config.terminal.filters)

  -- Validate scripts configuration
  if not config.scripts or type(config.scripts) ~= "table" then
    vim.notify("Invalid scripts configuration", vim.log.levels.ERROR)
    return
  end

  -- Create functions for each script
  for i, script in ipairs(config.scripts) do
    -- Validate script configuration
    if not script.name then
      vim.notify("Script " .. i .. " missing required field: name", vim.log.levels.WARN)
      goto continue
    end

    -- Use global root_dir if script doesn't specify one
    if not script.root_dir and config.root_dir then
      script.root_dir = config.root_dir
    end

    -- Check for valid configuration method
    local has_filename = script.filename
    local has_legacy = script.dir_name and script.relative_path

    if not has_filename and not has_legacy then
      vim.notify(
        "Script '"
          .. script.name
          .. "' must specify either 'filename' (with optional 'root_dir') or both 'dir_name' and 'relative_path'",
        vim.log.levels.WARN
      )
      goto continue
    end

    -- Create sanitized function name
    local function_name = "run_" .. script.name:gsub("[%s%-%.]", "_"):gsub("_+", "_"):lower()

    -- Ensure function name is valid
    if not function_name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
      vim.notify("Invalid function name generated for script: " .. script.name, vim.log.levels.WARN)
      goto continue
    end

    -- Create the function
    M[function_name] = function()
      return execute_script(script)
    end

    debug_log("Created function: " .. function_name .. " for script: " .. script.name)

    ::continue::
  end

  -- Initialize keybindings module with scripts
  keybindings.init(config.scripts)

  -- Apply saved keybindings
  apply_keybindings()
end

-- Utility function to close all active terminals
function M.close_all_terminals()
  for win, _ in pairs(active_terminals) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  active_terminals = {}
end

-- Improved close function with better target detection
function M.close_terminal()
  local current_win = vim.api.nvim_get_current_win()

  -- Check if current window is a terminal
  if active_terminals[current_win] then
    vim.api.nvim_win_close(current_win, true)
    return true
  end

  -- Find and close the most recently created terminal
  local wins = vim.tbl_keys(active_terminals)
  if #wins > 0 then
    local last_win = wins[#wins]
    if vim.api.nvim_win_is_valid(last_win) then
      vim.api.nvim_win_close(last_win, true)
      return true
    end
  end

  vim.notify("No active terminals to close", vim.log.levels.INFO)
  return false
end

-- Utility function to list available scripts
function M.list_scripts()
  if not config.scripts or #config.scripts == 0 then
    vim.notify("No scripts configured", vim.log.levels.INFO)
    return
  end

  local script_list = {}
  for _, script in ipairs(config.scripts) do
    local location_info
    if script.filename then
      local root = script.root_dir or config.root_dir or "current file location"
      location_info = "filename: " .. script.filename .. " (root: " .. root .. ")"
    else
      location_info = script.dir_name .. "/" .. script.relative_path
    end
    table.insert(script_list, script.name .. " (" .. location_info .. ")")
  end

  vim.notify("Available scripts:\n" .. table.concat(script_list, "\n"), vim.log.levels.INFO)
end

-- Backwards compatibility
M.open_floating_terminal = function()
  vim.notify("open_floating_terminal is deprecated, use create_floating_terminal", vim.log.levels.WARN)
  return M.create_floating_terminal()
end

M.close_build_window = function()
  vim.notify("close_build_window is deprecated, use close_terminal", vim.log.levels.WARN)
  return M.close_terminal()
end

-- Open the interactive script menu
function M.open_menu()
  if not config.scripts or #config.scripts == 0 then
    vim.notify("No scripts configured", vim.log.levels.INFO)
    return false
  end

  return menu.open(config.scripts, execute_script, config.menu)
end

-- Close the menu if open
function M.close_menu()
  menu.close()
end

-- Check if menu is currently open
function M.is_menu_open()
  return menu.is_open()
end

-- Toggle the menu open/closed
function M.toggle_menu()
  if menu.is_open() then
    menu.close()
  else
    M.open_menu()
  end
end

-- Stacktrace module access
M.stacktrace = stacktrace

-- Highlight module access
M.highlight = highlight

-- Filter module access
M.filter = filter

-- Get file info at cursor position in terminal buffer
function M.get_stacktrace_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  return stacktrace.find_nearest_metadata(buf, line)
end

-- Jump to file referenced in stack trace at cursor
function M.goto_stacktrace()
  local file_info = M.get_stacktrace_at_cursor()
  if file_info and file_info.path then
    -- Check if file exists
    if vim.fn.filereadable(file_info.path) == 1 then
      -- If the current window is a floating terminal, close it first and find
      -- a regular (non-floating) window to open the file in.
      local current_win = vim.api.nvim_get_current_win()
      local win_config = vim.api.nvim_win_get_config(current_win)
      if win_config.relative and win_config.relative ~= "" then
        -- We're in a floating window — close it
        vim.api.nvim_win_close(current_win, true)
        -- Try to find a non-floating window to switch to
        local found_regular_win = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local wc = vim.api.nvim_win_get_config(win)
          if (not wc.relative or wc.relative == "") and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
            found_regular_win = true
            break
          end
        end
        if not found_regular_win then
          -- No regular window found, create a new split
          vim.cmd("new")
        end
      end

      vim.cmd("edit " .. vim.fn.fnameescape(file_info.path))
      if file_info.line then
        vim.api.nvim_win_set_cursor(0, { file_info.line, (file_info.column or 1) - 1 })
      end
      return true
    else
      vim.notify("File not found: " .. file_info.path, vim.log.levels.WARN)
      return false
    end
  end
  vim.notify("No stack trace reference found at cursor", vim.log.levels.INFO)
  return false
end

-- ============================================================================
-- Output Persistence API
-- ============================================================================

-- Show output from the most recently saved terminal buffer
function M.show_last_output()
  if #saved_buffers == 0 then
    vim.notify("No saved terminal outputs available", vim.log.levels.INFO)
    return false
  end

  -- Find the first valid saved buffer (use while loop to avoid
  -- iterator invalidation when removing entries during traversal)
  local saved_entry = nil
  local i = 1
  while i <= #saved_buffers do
    local entry = saved_buffers[i]
    if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      saved_entry = entry
      break
    else
      table.remove(saved_buffers, i)
      -- don't increment i, next entry is now at same index
    end
  end

  if not saved_entry then
    vim.notify("No saved terminal outputs available", vim.log.levels.INFO)
    return false
  end

  -- Create a new floating window to display the saved buffer
  local term_config = vim.tbl_deep_extend("force", config.terminal, {})

  -- Format title with timestamp
  local timestamp = os.date("%H:%M:%S", saved_entry.timestamp)
  local title = " " .. (saved_entry.name or "Terminal") .. " (" .. timestamp .. ") "

  local win_opts = compute_win_opts(term_config, title)

  local win = vim.api.nvim_open_win(saved_entry.buf, true, win_opts)
  if not win then
    vim.notify("Failed to open saved output window", vim.log.levels.ERROR)
    return false
  end

  -- Apply highlights
  apply_win_highlights(win, term_config.highlights)

  -- Set bufhidden to wipe so closing this viewer deletes the buffer
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = saved_entry.buf })

  -- Add q keymap to close the output viewer window
  vim.api.nvim_buf_set_keymap(saved_entry.buf, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })

  return true, win
end

-- List all saved terminal outputs
function M.list_outputs()
  if #saved_buffers == 0 then
    vim.notify("No saved terminal outputs", vim.log.levels.INFO)
    return {}
  end

  -- Clean up invalid buffers and build list
  local valid_outputs = {}
  local i = 1
  while i <= #saved_buffers do
    local entry = saved_buffers[i]
    if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      local timestamp = os.date("%Y-%m-%d %H:%M:%S", entry.timestamp)
      local line_count = vim.api.nvim_buf_line_count(entry.buf)
      table.insert(valid_outputs, {
        name = entry.name,
        timestamp = timestamp,
        lines = line_count,
        buffer = entry.buf,
      })
      i = i + 1
    else
      table.remove(saved_buffers, i)
    end
  end

  if #valid_outputs == 0 then
    vim.notify("No saved terminal outputs", vim.log.levels.INFO)
    return {}
  end

  -- Format and display the list
  local output_list = {}
  for idx, output in ipairs(valid_outputs) do
    table.insert(
      output_list,
      idx .. ". " .. output.name .. " - " .. output.timestamp .. " (" .. output.lines .. " lines)"
    )
  end

  vim.notify("Saved terminal outputs:\n" .. table.concat(output_list, "\n"), vim.log.levels.INFO)
  return valid_outputs
end

-- Clear all saved terminal outputs
function M.clear_outputs()
  local count = 0
  for _, entry in ipairs(saved_buffers) do
    if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      vim.api.nvim_buf_delete(entry.buf, { force = true })
      count = count + 1
    end
  end

  saved_buffers = {}

  if count > 0 then
    vim.notify("Cleared " .. count .. " saved terminal output(s)", vim.log.levels.INFO)
  else
    vim.notify("No saved terminal outputs to clear", vim.log.levels.INFO)
  end

  return count
end

-- ============================================================================
-- Keybinding Management API
-- ============================================================================

--- Open the keybinding configuration UI
---@return boolean Success
function M.open_keybindings()
  if not config.scripts or #config.scripts == 0 then
    vim.notify("No scripts configured", vim.log.levels.INFO)
    return false
  end

  return keybindings.open(config.scripts, function(_new_keybindings)
    -- Re-apply keybindings when saved
    apply_keybindings()
  end, config.keybindings)
end

--- Close the keybinding configuration UI
function M.close_keybindings()
  keybindings.close()
end

--- Check if keybindings UI is currently open
---@return boolean
function M.is_keybindings_open()
  return keybindings.is_open()
end

--- Toggle the keybindings UI open/closed
function M.toggle_keybindings()
  if keybindings.is_open() then
    keybindings.close()
  else
    M.open_keybindings()
  end
end

--- Set a keybinding for a script programmatically
---@param script_name string Name of the script
---@param key string|nil Keybinding to set (nil to clear)
---@return boolean Success
function M.set_keybinding(script_name, key)
  local result = keybindings.set_keybinding(script_name, key)
  if result then
    -- Re-apply keybindings after change
    apply_keybindings()
  end
  return result
end

--- Clear a keybinding for a script
---@param script_name string Name of the script
function M.clear_keybinding(script_name)
  keybindings.clear_keybinding(script_name)
  -- Re-apply keybindings after change (to remove the old one)
  apply_keybindings()
end

--- Get all current keybindings
---@return table Map of script_name -> keybinding
function M.get_keybindings()
  return keybindings.get_keybindings()
end

-- ============================================================================
-- Focus Management API
-- ============================================================================

--- Focus the most recent terminal window
---@return boolean Success
function M.focus_terminal()
  -- Find the most recently created terminal
  local wins = vim.tbl_keys(active_terminals)
  if #wins == 0 then
    vim.notify("No active terminals", vim.log.levels.INFO)
    return false
  end

  local last_win = wins[#wins]
  if vim.api.nvim_win_is_valid(last_win) then
    vim.api.nvim_set_current_win(last_win)
    return true
  end

  vim.notify("No valid terminal window found", vim.log.levels.WARN)
  return false
end

--- Return focus to the window that was active before the terminal opened
---@return boolean Success
function M.focus_previous()
  local current_win = vim.api.nvim_get_current_win()

  -- Check if we're currently in a terminal window
  if not active_terminals[current_win] then
    vim.notify("Not in a terminal window", vim.log.levels.INFO)
    return false
  end

  local term_data = active_terminals[current_win]
  local original_win = term_data.original_win

  if not original_win or not vim.api.nvim_win_is_valid(original_win) then
    -- Try to find any valid non-floating window
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local win_config = vim.api.nvim_win_get_config(win)
      if (not win_config.relative or win_config.relative == "") and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        return true
      end
    end
    vim.notify("No previous window available", vim.log.levels.WARN)
    return false
  end

  vim.api.nvim_set_current_win(original_win)
  return true
end

--- Toggle focus between terminal and previous window
---@return boolean Success
function M.toggle_focus()
  local current_win = vim.api.nvim_get_current_win()

  -- Check if we're in a terminal window
  if active_terminals[current_win] then
    -- We're in a terminal, switch to previous window
    return M.focus_previous()
  else
    -- We're not in a terminal, switch to the most recent terminal
    return M.focus_terminal()
  end
end

-- ============================================================================
-- History Management API
-- ============================================================================

--- Re-run the most recently executed script
---@return boolean Success
function M.rerun_last()
  local last_entry = history.get_last_entry()
  if not last_entry then
    vim.notify("No history available", vim.log.levels.INFO)
    return false
  end

  if not last_entry.script then
    vim.notify("Script configuration not found in history", vim.log.levels.ERROR)
    return false
  end

  vim.notify("Re-running: " .. last_entry.script_name, vim.log.levels.INFO)
  return execute_script(last_entry.script)
end

--- Show the interactive history browser
---@return boolean Success
function M.show_history()
  if not config.history.enabled then
    vim.notify("History tracking is disabled", vim.log.levels.INFO)
    return false
  end

  return history.open(function(entry)
    if entry.script then
      execute_script(entry.script)
    else
      vim.notify("Script configuration not found in history", vim.log.levels.ERROR)
    end
  end)
end

--- Close the history browser
function M.close_history()
  history.close()
end

--- Check if history browser is currently open
---@return boolean
function M.is_history_open()
  return history.is_open()
end

--- Toggle the history browser open/closed
function M.toggle_history()
  if history.is_open() then
    history.close()
  else
    M.show_history()
  end
end

--- Get all history entries
---@return table List of history entries
function M.get_history()
  return history.get_entries()
end

--- Clear all history entries
function M.clear_history()
  history.clear_history()
  vim.notify("History cleared", vim.log.levels.INFO)
end

--- Expose history module for advanced usage
M.history = history

-- ============================================================================
-- Filter Management API
-- ============================================================================

--- Apply a filter preset to the current terminal buffer
---@param preset string Preset name ("errors", "warnings", "info", "all")
---@return boolean Success
function M.apply_filter_preset(preset)
  local buf = vim.api.nvim_get_current_buf()
  return M.apply_filter_preset_to_buf(buf, preset)
end

--- Apply a filter preset to a specific buffer (no buffer switching needed)
---@param buf number Buffer ID
---@param preset string Preset name ("errors", "warnings", "info", "all")
---@return boolean Success
function M.apply_filter_preset_to_buf(buf, preset)
  if not active_filters[buf] then
    vim.notify("Not a TermLet terminal buffer", vim.log.levels.WARN)
    return false
  end

  local filter_config = filter.create_preset(preset)
  active_filters[buf] = filter_config

  filter.apply_filters(buf, filter_config)
  vim.notify("Applied filter preset: " .. preset, vim.log.levels.INFO)
  return true
end

--- Toggle filters on/off for the current terminal buffer
---@return boolean New enabled state
function M.toggle_filters()
  local buf = vim.api.nvim_get_current_buf()

  if not active_filters[buf] then
    vim.notify("Not in a TermLet terminal buffer", vim.log.levels.WARN)
    return false
  end

  local enabled = filter.toggle_enabled(buf, active_filters[buf])
  local status = enabled and "enabled" or "disabled"
  vim.notify("Filters " .. status, vim.log.levels.INFO)
  return enabled
end

--- Disable filters for a specific buffer (no buffer switching needed)
--- Restores the original script-level filter config with enabled=false.
---@param buf number Buffer ID
function M.disable_filters_for_buf(buf)
  if not active_filters[buf] then
    return
  end

  -- Restore original script config if available, with enabled=false
  if original_script_filters[buf] then
    active_filters[buf] = vim.deepcopy(original_script_filters[buf])
  end
  active_filters[buf].enabled = false
  filter.clear_buffer(buf)
  vim.notify("Filters disabled", vim.log.levels.INFO)
end

--- Clear filters from the current terminal buffer
---@return boolean Success
function M.clear_filters()
  local buf = vim.api.nvim_get_current_buf()

  if not active_filters[buf] then
    vim.notify("Not in a TermLet terminal buffer", vim.log.levels.WARN)
    return false
  end

  filter.clear_buffer(buf)
  vim.notify("Cleared filters", vim.log.levels.INFO)
  return true
end

--- Reapply current filters to the terminal buffer
---@return boolean Success
function M.reapply_filters()
  local buf = vim.api.nvim_get_current_buf()

  if not active_filters[buf] then
    vim.notify("Not in a TermLet terminal buffer", vim.log.levels.WARN)
    return false
  end

  if not active_filters[buf].enabled then
    vim.notify("Filters are disabled", vim.log.levels.INFO)
    return false
  end

  local hidden = filter.apply_filters(buf, active_filters[buf])
  vim.notify("Filters reapplied. Hidden lines: " .. hidden, vim.log.levels.INFO)
  return true
end

--- Get current filter configuration for the terminal buffer
---@return table|nil Filter configuration
function M.get_current_filters()
  local buf = vim.api.nvim_get_current_buf()
  return active_filters[buf]
end

--- Open the interactive filter UI for the current terminal buffer
---@return boolean Success
function M.open_filter_ui()
  local buf = vim.api.nvim_get_current_buf()

  if not active_filters[buf] then
    vim.notify("Not in a TermLet terminal buffer", vim.log.levels.WARN)
    return false
  end

  return filter_ui.open(buf)
end

--- Toggle the filter UI for the current terminal buffer
---@return boolean Success
function M.toggle_filter_ui()
  local buf = vim.api.nvim_get_current_buf()

  if not active_filters[buf] then
    vim.notify("Not in a TermLet terminal buffer", vim.log.levels.WARN)
    return false
  end

  filter_ui.toggle(buf)
  return true
end

return M
