-- Clear user commands if they already exist so that we can re-define them below.
pcall(vim.api.nvim_del_user_command, "FlaresShow")
pcall(vim.api.nvim_del_user_command, "FlaresHide")

local M = {}

-- ######## STATE ########

-- Initial namespace IDs to be overwritten later.
local virtual_text_ns = 0
local highlight_ns = 0
-- Store the setup state
local is_setup = false

M.define_namespaces = function()
  virtual_text_ns = vim.api.nvim_create_namespace("flares_nvim_vtext")
  highlight_ns = vim.api.nvim_create_namespace("flares_nvim_highlight")
end

-- ######## COLORS ########

local function get_normal_colors()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  return {
    bg = normal.bg and string.format("#%06x", normal.bg) or "#000000",
    fg = normal.fg and string.format("#%06x", normal.fg) or "#ffffff",
  }
end

local function blend_hex_colors(color1, color2, blend_factor)
  -- Convert hex to RGB
  local r1, g1, b1 = tonumber(color1:sub(2, 3), 16), tonumber(color1:sub(4, 5), 16), tonumber(color1:sub(6, 7), 16)
  local r2, g2, b2 = tonumber(color2:sub(2, 3), 16), tonumber(color2:sub(4, 5), 16), tonumber(color2:sub(6, 7), 16)

  -- Blend RGB values
  local r = math.floor(r1 * (1 - blend_factor) + r2 * blend_factor)
  local g = math.floor(g1 * (1 - blend_factor) + g2 * blend_factor)
  local b = math.floor(b1 * (1 - blend_factor) + b2 * blend_factor)

  -- Convert back to hex
  return string.format("#%02x%02x%02x", r, g, b)
end

local function register_highlight_groups()
  local colors = get_normal_colors()
  local blended_bg = blend_hex_colors(colors.bg, colors.fg, 0.033)
  local blended_fg = blend_hex_colors(colors.bg, colors.fg, 0.2)

  vim.api.nvim_set_hl(0, "FlaresBackground", { bg = blended_bg })
  vim.api.nvim_set_hl(0, "FlaresComment", { bg = blended_bg, fg = blended_fg })
end

-- ######## DEBOUNCING ########
local timer = nil -- Store timer reference

local function debounced_update(fn, delay)
  -- Cancel existing timer if present
  if timer then
    timer:stop()
    timer:close()
  end

  -- Create new timer
  timer = vim.uv.new_timer()

  -- Start timer with delay
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      fn() -- Execute the actual update
      timer:stop()
      timer:close()
      timer = nil
    end)
  )
end

-- ######## LSP ########

-- Check if buffer has symbol-providing LSP clients
local function has_symbol_clients(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.server_capabilities.documentSymbolProvider then
      return true
    end
  end
  return false
end

M.get_document_symbols = function(bufnr)
  local params = { textDocument = vim.lsp.util.make_text_document_params() }

  -- Create a table to store the symbols
  local symbols = {}
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 500)

  -- Define the kinds we want to keep
  local wanted_kinds = {
    [5] = true, -- Class
    [12] = true, -- Function
    [6] = true, -- Method
  }

  local function traverse_symbols(symbol_list)
    for _, symbol in ipairs(symbol_list) do
      if wanted_kinds[symbol.kind] then
        table.insert(symbols, symbol)
      end
      if symbol.children then
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

  return symbols
end

-- ######## FLARE ADDITION ########

M.add_text_flare = function(bufnr, opts)
  local text = opts.text or ""
  local hl_group = opts.hl_group or "Normal"

  local extmark_opts = {
    id = opts.id,
    virt_text = { { text, hl_group } },
    virt_text_pos = opts.position or "right_align",
    priority = opts.priority or 1,
  }

  return vim.api.nvim_buf_set_extmark(bufnr, virtual_text_ns, opts.line or 0, opts.col or 0, extmark_opts)
end

M.add_highlight_flare = function(buffer, opts)
  local line = opts.line or 0
  local hl_group = opts.hl_group or "Normal" -- fallback to Normal if no group specified

  return vim.api.nvim_buf_set_extmark(buffer, highlight_ns, line, 0, {
    line_hl_group = hl_group,
    priority = 10,
  })
end

M.add_line_above_flare = function(bufnr, linenr, text, highlight_group)
  -- Get window width
  local win_width = vim.api.nvim_win_get_width(0)
  -- Pad the text to fill the entire line width
  local padded_text = text .. string.rep(" ", win_width - vim.fn.strdisplaywidth(text))

  vim.api.nvim_buf_set_extmark(bufnr, virtual_text_ns, linenr - 1, 0, {
    virt_lines = {
      {
        { padded_text, highlight_group }, -- The padding will now be included in the highlight
      },
    },
    virt_lines_above = true,
  })
end

local function get_flare_display_string_for_symbol(symbol)
  local result = ""

  for _, entry in ipairs(M.display_contents) do
    if entry == "icon" then
      result = result .. M.icon_for_kind[symbol.kind] .. " "
    elseif entry == "kind" then
      result = result .. M.display_text_for_kind[symbol.kind] .. " "
    elseif entry == "name" then
      result = result .. symbol.name .. " "
    else
      error("[Flares] Invalid display content: " .. entry)
    end
  end

  return result
end

M.add_flares = function(bufnr)
  M.define_namespaces()

  local lsp_content = M.get_document_symbols(bufnr)

  -- If the mode is not 'inline' or 'above', print an error and return
  if not vim.tbl_contains({ "inline", "above" }, M.mode) then
    error("[Flares] Invalid display mode: " .. tostring(M.mode))
    return
  end

  local last_line = 0

  for _, symbol in ipairs(lsp_content) do
    local line = symbol.range.start.line
    local display_string = get_flare_display_string_for_symbol(symbol)

    -- Clear flares until the current line
    M.clear_all_flares_in_lines(bufnr, last_line + 1, symbol.range.start.line + 1)

    -- Add the new flare
    if M.mode == "inline" then
      M.add_highlight_flare(bufnr, {
        line = line,
        hl_group = "FlaresBackground",
      })

      M.add_text_flare(bufnr, {
        line = line,
        text = display_string,
        hl_group = "FlaresComment",
      })
    elseif M.mode == "above" then
      M.add_line_above_flare(bufnr, line + 1, display_string, "FlaresComment")
    end
    last_line = symbol.range.start.line
  end

  -- Clear until the end of the buffer
  M.clear_all_flares_in_lines(bufnr, last_line + 1)
end

-- ######## FLARE CLEARING ########

M.clear_text_flares_in_lines = function(bufnr, start_line, end_line)
  vim.api.nvim_buf_clear_namespace(bufnr, virtual_text_ns, start_line or 0, end_line or -1)
end

M.clear_highlight_flares_in_lines = function(buffer, start_line, end_line)
  -- Clear all extmarks in the highlight namespace
  vim.api.nvim_buf_clear_namespace(buffer, highlight_ns, start_line or 0, end_line or -1)

  -- Clear all highlight groups created by the plugin
  local pattern = "FlaresNvim" .. highlight_ns .. "_"
  local highlights = vim.fn.getcompletion(pattern, "highlight")
  for _, hl_group in ipairs(highlights) do
    pcall(vim.api.nvim_del_hl, 0, hl_group)
  end
end

M.clear_all_flares = function(bufnr)
  M.clear_text_flares_in_lines(bufnr)
  M.clear_highlight_flares_in_lines(bufnr)
end

M.clear_all_flares_in_lines = function(bufnr, start_line, end_line)
  M.clear_text_flares_in_lines(bufnr, start_line, end_line)
  M.clear_highlight_flares_in_lines(bufnr, start_line, end_line)
end

-- ######## SETUP ########

local function setup_initialization_events()
  -- Create an autocmd group
  local group = vim.api.nvim_create_augroup("FlareAutoAttach", { clear = true })

  -- Watch for LSP attach events
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      -- Check if the attached LSP provides symbols
      if has_symbol_clients(bufnr) then
        M.attach_to_buffer(bufnr)
      end
    end,
  })

  -- Check currently active buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if has_symbol_clients(bufnr) then
      M.attach_to_buffer(bufnr)
    end
  end
end

local function setup_update_events(bufnr)
  local group = vim.api.nvim_create_augroup("FlareEventListeners", { clear = true })

  -- Update on LSP symbol changes
  vim.api.nvim_create_autocmd("LspRequest", {
    group = group,
    pattern = "textDocument/documentSymbols",
    callback = function()
      -- Add debouncing to avoid rapid updates
      debounced_update(function()
        M.add_flares(bufnr)
      end, 500)
    end,
  })

  -- Update on buffer changes
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      -- Add debouncing to avoid rapid updates
      debounced_update(function()
        M.add_flares(bufnr)
      end, 500)
    end,
  })

  vim.api.nvim_create_autocmd("LspProgress", {
    pattern = { "end" },
    callback = function(args)
      if not is_setup then
        return
      end

      if args.buf then
        M.add_flares(args.buf)
      end
    end,
  })

  -- Update on window resize/layout changes
  vim.api.nvim_create_autocmd({ "WinResized" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.add_flares(bufnr)
    end,
  })
end

M.attach_to_buffer = function(bufnr)
  setup_update_events(bufnr)
  debounced_update(function()
    M.add_flares(bufnr)
  end, 500)
end

M.setup = function(opts)
  if is_setup then
    return
  end
  is_setup = true

  opts = opts or {}

  M.mode = opts.mode or "inline"

  M.display_contents = opts.display_contents or { "icon", "kind", "name" }

  M.icon_for_kind = {
    [5] = opts.icons and opts.icons.Class or "",
    [6] = opts.icons and opts.icons.Method or "",
    [12] = opts.icons and opts.icons.Function or "",
  }

  M.display_text_for_kind = {
    [5] = "Class",
    [6] = "Method",
    [12] = "Function",
  }

  register_highlight_groups()
  setup_initialization_events()
end

-- ######## USER COMMANDS ########
M.current_buffer = function()
  return vim.fn.bufnr("%")
end

function M.clear_autocommands()
  -- Clear all autocommands in our specific group
  vim.api.nvim_clear_autocmds({ group = "FlareEventListeners" })
end

vim.api.nvim_create_user_command("FlaresShow", function(opts)
  local args = vim.split(opts.args, " ")
  local mode = args[1]

  if not vim.tbl_contains({ "above", "inline" }, mode) then
    error("[Flares] Invalid mode: " .. tostring(mode))
    return
  end

  local display_contents = {}
  for i = 2, #args do
    if vim.tbl_contains({ "kind", "icon", "name" }, args[i]) then
      table.insert(display_contents, args[i])
    else
      error("[Flares] Invalid display content: " .. args[i])
    end
  end

  M.mode = mode
  M.display_contents = display_contents

  M.attach_to_buffer(M.current_buffer())
  M.add_flares(M.current_buffer())
end, {
  nargs = "+",
  complete = function(_, cmd_line, _)
    local args = vim.split(cmd_line, " ")
    if #args == 2 then
      return { "above", "inline" }
    else
      return { "kind", "icon", "name" }
    end
  end,
})

vim.api.nvim_create_user_command("FlaresHide", function()
  M.define_namespaces()
  M.clear_all_flares(M.current_buffer())
  M.clear_autocommands()
end, { range = true })

return M
