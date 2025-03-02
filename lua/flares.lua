local M = {}

-- ######## STATE ########

-- Whether the plugin has been set up
local is_setup = false
-- The namespace for keeping track of flares
local flares_ns = vim.api.nvim_create_namespace("flares_nvim")
local flares_background_ns = vim.api.nvim_create_namespace("flares_background_nvim")

-- ######## COLORS ########

--- Get the normal colors from the current theme.
---@return table: A table containing the background and foreground colors in hex format.
local function get_normal_colors()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  return {
    bg = normal.bg and string.format("#%06x", normal.bg) or "#000000",
    fg = normal.fg and string.format("#%06x", normal.fg) or "#ffffff",
  }
end

--- Blend two hex colors by a given factor.
---@param color1 string: The first color in hex format.
---@param color2 string: The second color in hex format.
---@param blend_factor number: A number between 0 and 1 indicating the blend ratio.
---@return string: The blended color in hex format.
local function blend_hex_colors(color1, color2, blend_factor)
  local r1, g1, b1 = tonumber(color1:sub(2, 3), 16), tonumber(color1:sub(4, 5), 16), tonumber(color1:sub(6, 7), 16)
  local r2, g2, b2 = tonumber(color2:sub(2, 3), 16), tonumber(color2:sub(4, 5), 16), tonumber(color2:sub(6, 7), 16)

  local r = math.floor(r1 * (1 - blend_factor) + r2 * blend_factor)
  local g = math.floor(g1 * (1 - blend_factor) + g2 * blend_factor)
  local b = math.floor(b1 * (1 - blend_factor) + b2 * blend_factor)

  return string.format("#%02x%02x%02x", r, g, b)
end

--- Register highlight groups for flares.
-- TODO: Make highlight groups configurable.
local function register_highlight_groups()
  local colors = get_normal_colors()
  local blended_content_bg = blend_hex_colors(colors.bg, colors.fg, 0.02)
  local blended_header_bg = blend_hex_colors(colors.bg, colors.fg, 0.033)
  local blended_header_fg = blend_hex_colors(colors.bg, colors.fg, 0.3)

  vim.api.nvim_set_hl(0, "FlaresContentBackground", { bg = blended_content_bg })
  vim.api.nvim_set_hl(0, "FlaresHeaderBackground", { bg = blended_header_bg })
  vim.api.nvim_set_hl(0, "FlaresHeaderForeground", { bg = blended_header_bg, fg = blended_header_fg })
end

-- ######## DEBOUNCING ########

-- Timer used for debouncing flare additions.
local timer = nil

--- Create a debounced function that delays invoking the provided function.
---@param fn function: The function to debounce.
---@param delay number: The delay in milliseconds.
local function debounced_update(fn, delay)
  if timer then
    timer:stop()
    timer:close()
  end

  timer = vim.uv.new_timer()

  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      fn()
      timer:stop()
      timer:close()
      timer = nil
    end)
  )
end

-- ######## LSP ########

--- Check if a buffer has LSP clients that provide document symbols.
---@param bufnr number: The buffer number.
---@return boolean: True if there are symbol-providing LSP clients, false otherwise.
local function has_symbol_clients(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.server_capabilities.documentSymbolProvider then
      return true
    end
  end
  return false
end

local symbol_kinds = {
  [5] = "Class",
  [6] = "Method",
  [9] = "Constructor",
  [12] = "Function",
  [999] = "Comment", -- New custom kind for comments
}

--- Get all symbol kind names as an array
---@return string[]: An array of symbol kind names
local function get_symbol_kind_names()
  local kinds = {}
  for _, kind in pairs(symbol_kinds) do
    if not vim.tbl_contains(kinds, kind) then
      table.insert(kinds, kind)
    end
  end
  return kinds
end

--- Check if a symbol kind should have a flare
---@param symbol unknown: The LSP symbol
---@return boolean: Whether this kind should have a flare
local function symbol_with_flare(symbol)
  return symbol_kinds[symbol.kind] and vim.tbl_contains(M.enabled_flares, symbol_kinds[symbol.kind])
end

--- Check if we should consider adding flares for the descendants
--- of a symbol, by looking at the `allow_nested` option.
---@param symbol unknown: The LSP symbol
---@return boolean: Whether we should consider the descendants of this symbol.
local function symbol_disallows_nesting(symbol)
  local kind = symbol_kinds[symbol.kind]
  return vim.tbl_contains(M.disallow_nesting, kind)
end

--- Check if a symbol should have a background, by looking
--- at the `has_background` option.
---@param symbol unknown: The LSP symbol
---@return boolean: Whether this kind should have a background
local function symbol_has_background(symbol)
  local kind = symbol_kinds[symbol.kind]
  return vim.tbl_contains(M.has_background, kind)
end

-- Function to find comments in a buffer
-- @param bufnr number: The buffer number
-- @return table: Array of comment symbols in the same format as LSP symbols
local function get_comment_symbols(bufnr)
  local comment_symbols = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Get comment string for the current filetype
  local commentstring = vim.api.nvim_get_option_value("commentstring", { buf = bufnr })
  -- Extract just the comment prefix (without the format specifier)
  local comment_prefix = commentstring:match("(.*)%%s") or commentstring
  comment_prefix = vim.trim(comment_prefix)

  -- If we can't determine a comment string, use some common defaults
  if comment_prefix == "" then
    -- Try to detect based on filetype
    local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
    if ft == "lua" then
      comment_prefix = "--"
    elseif vim.tbl_contains({ "javascript", "typescript", "c", "cpp", "java", "scala" }, ft) then
      comment_prefix = "//"
    elseif ft == "python" then
      comment_prefix = "#"
    else
      comment_prefix = "--" -- Default fallback
    end
  end

  -- Pattern to match a comment at the beginning of a line (with optional whitespace)
  local pattern = "^%s*" .. vim.pesc(comment_prefix) .. "%s*(.+)"

  for i, line in ipairs(lines) do
    local comment_text = line:match(pattern)
    if comment_text then
      -- Format the comment symbol like an LSP symbol
      table.insert(comment_symbols, {
        name = comment_text,
        kind = 999, -- Our custom comment kind
        range = {
          start = { line = i - 1, character = 0 },
          ["end"] = { line = i - 1, character = #line },
        },
      })
    end
  end

  return comment_symbols
end

--- Get document symbols from the LSP for a given buffer.
---@param bufnr number: The buffer number.
---@return table: A table of symbols.
local function get_document_symbols(bufnr)
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 500)

  -- Collect the symbols we want to add flares to
  local symbols = {}

  -- Recursively traverse the symbol tree
  local function traverse_symbols(symbol_list)
    for _, symbol in ipairs(symbol_list) do
      if symbol_with_flare(symbol) then
        table.insert(symbols, symbol)
      end
      if symbol.children and not symbol_disallows_nesting(symbol) then
        traverse_symbols(symbol.children)
      end
    end
  end

  if result and next(result) then
    for _, res in pairs(result) do
      if res.result then
        traverse_symbols(res.result)
      end
    end
  end

  -- Add comment symbols to our list of symbols
  local comment_symbols = get_comment_symbols(bufnr)
  for _, comment in ipairs(comment_symbols) do
    table.insert(symbols, comment)
  end

  -- Sort all symbols by start line for proper ordering
  table.sort(symbols, function(a, b)
    return a.range.start.line < b.range.start.line
  end)

  return symbols
end

-- ######## FLARE CLEARING ########

--- Clear text flares in a range of lines.
---@param bufnr number: The buffer number.
---@param start_line number|nil: The starting line number.
---@param end_line number|nil: The ending line number.
local function clear_flares_in_lines(bufnr, start_line, end_line, namespace)
  namespace = namespace or flares_ns
  print("Clearing flares from " .. (start_line or 0) .. " to " .. (end_line or -1) .. " in namespace " .. namespace)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, start_line or 0, end_line or -1)

  if namespace == flares_ns then
    local pattern = "FlaresNvim" .. flares_ns .. "_"
    local highlights = vim.fn.getcompletion(pattern, "highlight")
    for _, hl_group in ipairs(highlights) do
      pcall(vim.api.nvim_del_hl, 0, hl_group)
    end
  end
end

--- Clear all flares in a buffer.
---@param bufnr number: The buffer number.
local function clear_all_flares(bufnr)
  clear_flares_in_lines(bufnr)
end

-- ######## FLARE ADDITION ########

--- Add a text flare to a buffer.
---@param bufnr number: The buffer number.
---@param linenr number: The line number in which to add the flare.
---@param content string: The text to display.
---@param highlight_group string: The highlight group to use.
---@return number: The extmark ID.
local function add_text_flare(bufnr, linenr, content, highlight_group)
  local extmark_opts = {
    virt_text = { { content, highlight_group } },
    virt_text_pos = "right_align",
    priority = 1,
  }

  return vim.api.nvim_buf_set_extmark(bufnr, flares_ns, linenr, 0, extmark_opts)
end

--- Add a highlight flare to a buffer.
---@param bufnr number: The buffer number.
---@param linenr number: The line number at which to add the flare.
---@param highlight_group string: The highlight group to use.
---@return number: The extmark ID.
local function add_highlight_flare(bufnr, linenr, highlight_group)
  return vim.api.nvim_buf_set_extmark(bufnr, flares_ns, linenr, 0, {
    line_hl_group = highlight_group,
    priority = 1,
  })
end

--- Add a line above flare to a buffer.
---@param bufnr number: The buffer number.
---@param linenr number: The line number above which to add the flare.
---@param content string: The text to display.
---@param highlight_group string: The highlight group to use.
local function add_line_above_flare(bufnr, linenr, content, highlight_group)
  -- Following issues where `nvim_buf_set_extmark` got `line` values that
  -- were out of range, we check if the line number is valid before adding
  -- the virtual line.
  if linenr <= 0 then
    return
  end

  local win_width = vim.api.nvim_win_get_width(0)
  local padded_text = content .. string.rep(" ", win_width - vim.fn.strdisplaywidth(content))

  vim.api.nvim_buf_set_extmark(bufnr, flares_ns, linenr - 1, 0, {
    virt_lines = {
      {
        { padded_text, highlight_group },
      },
    },
    virt_lines_above = true,
  })
end

local function add_background(bufnr, start_line, end_line)
  for i = start_line, end_line do
    vim.api.nvim_buf_set_extmark(bufnr, flares_background_ns, i, 0, {
      line_hl_group = "FlaresContentBackground",
      priority = 1,
    })
  end
end

--- Get the leading whitespace substring from a line in a buffer
---@param bufnr number: The buffer number
---@param linenr number: The line number (0-based)
---@return string: The leading whitespace substring
local function get_leading_whitespace(bufnr, linenr)
  local line = vim.api.nvim_buf_get_lines(bufnr, linenr, linenr + 1, false)[1]
  if not line then
    return ""
  end

  -- Find the first non-whitespace character
  local first_non_ws = line:find("[^%s]")
  if not first_non_ws then
    return ""
  end

  -- Return the substring from start to before first non-whitespace
  return line:sub(1, first_non_ws - 1)
end

--- Get the display string for a symbol.
---@param bufnr number: The buffer number.
---@param symbol unknown: The LSP symbol to get the display string for.
---@return string: The display string.
local function get_flare_display_string_for_symbol(bufnr, symbol)
  local result = ""

  if M.mode == "above" and M.align_above then
    result = result .. get_leading_whitespace(bufnr, symbol.range.start.line)
  end

  for _, entry in ipairs(M.display_contents) do
    if entry == "icon" then
      result = result .. M.icon_for_kind[symbol.kind] .. " "
    elseif entry == "kind" then
      result = result .. symbol_kinds[symbol.kind] .. " "
    elseif entry == "name" then
      result = result .. symbol.name .. " "
    else
      error("[Flares] Invalid display content: " .. entry)
    end
  end

  return result
end

--- Add flares to a buffer based on LSP document symbols.
---@param bufnr number: The buffer number.
local function add_flares(bufnr)
  -- Check whether we have a valid mode for displaying flares.
  if not vim.tbl_contains({ "inline", "above" }, M.mode) then
    error("[Flares] Invalid display mode: " .. tostring(M.mode))
    return
  end

  -- Gather the LSP symbols for which we want to add flares.
  local lsp_symbols = get_document_symbols(bufnr)

  -- We clear previously added flares while adding new ones,
  -- since clearing all flares in advance leads to jittering.
  -- To that end, we keep track of the position at which we
  -- last added a new flare and then clear all the ones between
  -- this last one and the new one we add. Note that we have to
  -- deal with backgrounds and non-backgrounds separately, since
  -- we draw the whole background a symbol, and may find
  -- additional symbols before reaching the end of the background.
  local clear_flares_from = 0
  local clear_background_flares_from = 0

  for _, symbol in ipairs(lsp_symbols) do
    -- Where to add the flare:
    local start_line = symbol.range.start.line
    local end_line = symbol.range["end"].line
    -- What to display for that flare:
    local display_string = get_flare_display_string_for_symbol(bufnr, symbol)

    -- Clear the old flares between the last one added and
    -- the new one we want to add.
    if clear_flares_from <= start_line then
      clear_flares_in_lines(bufnr, clear_flares_from + 1, start_line + 1)
    end

    -- Clear the old background flares between the last one
    -- added and the new one we want to add.
    if clear_background_flares_from <= start_line then
      clear_flares_in_lines(bufnr, clear_background_flares_from + 1, start_line + 1, flares_background_ns)
    end

    -- The next time we want to clear flares from where this symbol starts.
    clear_flares_from = math.max(start_line, clear_flares_from)

    -- Draw the background for symbols, if enabled.
    if symbol_has_background(symbol) then
      add_background(bufnr, start_line, end_line)
      clear_background_flares_from = math.max(end_line, clear_background_flares_from)
    end

    if M.mode == "inline" then
      -- When displaying the flare inline, we first add the background highlight
      -- to the corresponding line and then add the virtual text.
      add_highlight_flare(bufnr, start_line, "FlaresHeaderBackground")
      add_text_flare(bufnr, start_line, display_string, "FlaresHeaderForeground")
    elseif M.mode == "above" then
      add_line_above_flare(bufnr, start_line + 1, display_string, "FlaresHeaderForeground")
    end
  end

  -- Clear all the remaining flares in the buffer.
  clear_flares_in_lines(bufnr, clear_flares_from + 1, nil, flares_ns)
  clear_flares_in_lines(bufnr, clear_background_flares_from + 1, nil, flares_background_ns)
end

-- ######## FLARE HIDING ########
-- We want to hide flares in the current line when the cursor moves.

-- Storing temporarily hidden flares
local hidden_flares = {}

--- Store flares from a specific line and remove them from display
---@param bufnr number: The buffer number
---@param line number: The line number
local function hide_flares_in_line(bufnr, line)
  -- Get all extmarks in the line
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, flares_ns, { line, 0 }, { line, -1 }, { details = true })

  -- Initialize buffer table if it doesn't exist
  if not hidden_flares[bufnr] then
    hidden_flares[bufnr] = {}
  end

  -- Store the marks and their details
  for _, mark in ipairs(marks) do
    local id, _, _, opts = unpack(mark)

    -- Only handle marks that are not virt_lines_above. The
    -- cursor is never in those lines anyway.
    if not opts.virt_lines_above then
      if not hidden_flares[bufnr][line] then
        hidden_flares[bufnr][line] = {}
      end

      table.insert(hidden_flares[bufnr][line], {
        id = id,
        virt_text = opts.virt_text,
        virt_text_pos = opts.virt_text_pos,
        line_hl_group = opts.line_hl_group,
        virt_lines = opts.virt_lines,
        priority = opts.priority,
      })

      -- Remove just this specific mark instead of clearing the whole line
      vim.api.nvim_buf_del_extmark(bufnr, flares_ns, id)
    end
  end
end

--- Restore previously hidden flares for a specific line
---@param bufnr number: The buffer number
---@param line number: The line number
local function restore_flares_in_line(bufnr, line)
  if not hidden_flares[bufnr] or not hidden_flares[bufnr][line] then
    return
  end

  -- Check if the line exists in the buffer
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line >= line_count then
    -- Line no longer exists, just clear the stored marks
    hidden_flares[bufnr][line] = nil
    return
  end

  -- Restore each mark with its original options
  for _, opts in ipairs(hidden_flares[bufnr][line]) do
    vim.api.nvim_buf_set_extmark(bufnr, flares_ns, line, 0, opts)
  end

  -- Clear the stored marks
  hidden_flares[bufnr][line] = nil
end

-- ######## SETUP ########

--- Setup update events for a buffer. We want to re-draw flares
--- when the contents of the buffer have changed or the window
--- as been resized.
---@param bufnr number: The buffer number.
local function setup_update_events(bufnr)
  local group = vim.api.nvim_create_augroup("FlareEventListeners", { clear = true })

  vim.api.nvim_create_autocmd("LspRequest", {
    group = group,
    pattern = "textDocument/documentSymbols",
    callback = function()
      debounced_update(function()
        add_flares(bufnr)
      end, 500)
    end,
  })

  -- Without this event, flares may be drawn initially when the
  -- buffer is opened, since we may have to wait for the LSP to
  -- finish processing the document symbols.
  vim.api.nvim_create_autocmd("LspProgress", {
    pattern = { "end" },
    callback = function(args)
      if not is_setup then
        return
      end

      if args.buf then
        debounced_update(function()
          add_flares(bufnr)
        end, 500)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "WinResized", "WinNew" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      debounced_update(function()
        add_flares(bufnr)
      end, 500)
    end,
  })

  -- Add cursor movement tracking to allow for hiding flares in the cursorline.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      -- Nothing to do if cursorline is not enabled.
      if not vim.opt.cursorline:get() then
        return
      end

      local cursor = vim.api.nvim_win_get_cursor(0)
      local current_line = cursor[1] - 1 -- Convert to 0-based
      local current_buf = vim.api.nvim_get_current_buf()

      -- Initialize buffer table if it doesn't exist yet
      if not hidden_flares[current_buf] then
        hidden_flares[current_buf] = {}
      end

      -- Restore flares in previously hidden lines
      if hidden_flares[current_buf] then
        for line, _ in pairs(hidden_flares[current_buf]) do
          if line ~= current_line then
            restore_flares_in_line(current_buf, line)
          end
        end
      end

      -- Hide flares in current line
      hide_flares_in_line(current_buf, current_line)
    end,
  })
end

--- Attach the plugin to a buffer.
---@param bufnr number: The buffer number.
local function attach_to_buffer(bufnr)
  setup_update_events(bufnr)
  -- When attaching to a buffer, it may happen that the LSP is
  -- attached and ready before we are, in which case there is no
  -- event that triggers initial flare drawing. To account for
  -- this, we draw the flares immediately after attaching.
  debounced_update(function()
    add_flares(bufnr)
  end, 500)
end

--- Setup initialization events for the plugin. This allows us to
--- automatically show flares in all (existing and new) buffers that
--- have LSP clients.
local function setup_initialization_events()
  local group = vim.api.nvim_create_augroup("FlareAutoAttach", { clear = true })

  -- Watch for LSP attach events
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      if has_symbol_clients(bufnr) then
        attach_to_buffer(bufnr)
      end
    end,
  })

  -- Check currently active buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if has_symbol_clients(bufnr) then
      attach_to_buffer(bufnr)
    end
  end
end

--- Setup the flares.nvim plugin with options.
---@param opts table: Configuration opts. Keys: mode, display_contents, icon_for_kind.
-- Update the icon_for_kind in M.setup to include a comment icon
M.setup = function(opts)
  if is_setup then
    return
  end
  is_setup = true

  opts = opts or {}

  M.mode = opts.mode or "inline"

  M.enabled_flares = opts.enabled_flares or get_symbol_kind_names()

  M.display_contents = opts.display_contents or { "icon", "kind", "name" }

  M.align_above = true

  M.disallow_nesting = opts.disallow_nesting or {}

  M.has_background = opts.has_background or {}

  M.icon_for_kind = {
    [5] = opts.icons and opts.icons.Class or "",
    [6] = opts.icons and opts.icons.Method or "",
    [9] = opts.icons and opts.icons.Constructor or "",
    [12] = opts.icons and opts.icons.Function or "",
    [999] = opts.icons and opts.icons.Comment or "󰆉",
  }

  register_highlight_groups()
  setup_initialization_events()
end

-- ######## USER COMMANDS ########

--- Get the current buffer number.
---@return number: The current buffer number.
local function current_buffer()
  return vim.fn.bufnr("%")
end

--- Clear all autocommands in the `FlareEventListeners` group.
local function clear_autocommands()
  vim.api.nvim_clear_autocmds({ group = "FlareEventListeners" })
end

-- Clear command before re-defining it.
pcall(vim.api.nvim_del_user_command, "FlaresShow")

vim.api.nvim_create_user_command("FlaresShow", function(opts)
  local args = vim.split(opts.args, " ")

  -- Evaluating the mode argument.
  if #args > 0 and args[1] and args[1] ~= "" then
    local mode = args[1]

    if not vim.tbl_contains({ "above", "inline" }, mode) then
      error("[Flares] Invalid mode: " .. tostring(mode))
      return
    end

    M.mode = mode
    -- When a mode is displayed, we clear the display contents, allowing us to
    -- use flares without displayed text. This is explicitly not done before the
    -- mode is set, as we want to allow for showing flares with the previously
    -- set display contents.
    M.display_contents = {}
  end

  -- Evaluating the display content arguments.
  if #args > 1 then
    local display_contents = {}
    for i = 2, #args do
      if vim.tbl_contains({ "kind", "icon", "name" }, args[i]) then
        table.insert(display_contents, args[i])
      else
        error("[Flares] Skipping invalid display content: " .. args[i])
      end
    end

    M.display_contents = display_contents
  end

  attach_to_buffer(current_buffer())
  add_flares(current_buffer())
end, {
  nargs = "*",
  complete = function(_, line, _)
    local args = vim.split(line, "%s+")
    if #args == 2 then
      return { "above", "inline" }
    else
      return { "kind", "icon", "name" }
    end
  end,
})

-- Clear command before re-defining it.
pcall(vim.api.nvim_del_user_command, "FlaresHide")
vim.api.nvim_create_user_command("FlaresHide", function()
  clear_all_flares(current_buffer())
  clear_autocommands()
end, { range = true })

return M
