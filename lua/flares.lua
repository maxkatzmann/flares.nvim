pcall(vim.api.nvim_del_user_command, "FlaresHighlight")
pcall(vim.api.nvim_del_user_command, "FlaresClear")

local M = {}

-- Store namespace IDs internally
local virtual_text_ns = 0
local highlight_ns = 0
-- Store the setup state
local is_setup = false

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

local function setup_highlights()
  local colors = get_normal_colors()
  local blended_bg = blend_hex_colors(colors.bg, colors.fg, 0.05)
  local blended_fg = blend_hex_colors(colors.bg, colors.fg, 0.2)

  vim.api.nvim_set_hl(0, "FlaresBackground", { bg = blended_bg })
  vim.api.nvim_set_hl(0, "FlaresComment", { bg = blended_bg, fg = blended_fg })
end

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

M.setup = function(opts)
  if is_setup then
    return
  end
  is_setup = true

  opts = opts or {}

  M.mode = opts.mode or "inline_icon_and_name"
  setup_highlights()

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

M.setup_namespaces = function()
  virtual_text_ns = vim.api.nvim_create_namespace("flares_nvim_vtext")
  highlight_ns = vim.api.nvim_create_namespace("flares_nvim_highlight")
end

M.set_virtual_text = function(bufnr, opts)
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

M.current_buffer = function()
  return vim.fn.bufnr("%")
end

M.clear_virtual_text = function(buffer)
  vim.api.nvim_buf_clear_namespace(buffer, virtual_text_ns, 0, -1)
end

M.highlight_line = function(buffer, opts)
  local line = opts.line or 0
  local hl_group = opts.hl_group or "Normal" -- fallback to Normal if no group specified

  return vim.api.nvim_buf_set_extmark(buffer, highlight_ns, line, 0, {
    line_hl_group = hl_group,
    priority = 10,
  })
end

M.clear_line_highlights = function(buffer)
  -- Clear all extmarks in the highlight namespace
  vim.api.nvim_buf_clear_namespace(buffer, highlight_ns, 0, -1)

  -- Clear all highlight groups created by the plugin
  local pattern = "FlaresNvim" .. highlight_ns .. "_"
  local highlights = vim.fn.getcompletion(pattern, "highlight")
  for _, hl_group in ipairs(highlights) do
    pcall(vim.api.nvim_del_hl, 0, hl_group)
  end
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

  if result and next(result) then
    for _, res in pairs(result) do
      if res.result then
        for _, symbol in ipairs(res.result) do
          -- Only insert symbols of the desired kinds
          if wanted_kinds[symbol.kind] then
            table.insert(symbols, symbol)
          end
        end
      end
    end
  end

  return symbols
end

M.add_virtual_line_above = function(bufnr, linenr, text, highlight_group)
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

local icon_for_kind = {
  [5] = "󰯲",
  [12] = "󰯻",
  [6] = "󰰐",
}

local display_text_for_kind = {
  [5] = "Class",
  [12] = "Function",
  [6] = "Method",
}

local display_handlers = {
  above_kind = function(bufnr, line, _, kind)
    M.add_virtual_line_above(bufnr, line + 1, display_text_for_kind[kind], "FlaresComment")
  end,
  above_icon_and_name = function(bufnr, line, name, kind)
    M.add_virtual_line_above(bufnr, line + 1, icon_for_kind[kind] .. " " .. name, "FlaresComment")
  end,
  inline_icon_and_name = function(bufnr, line, name, kind)
    M.highlight_line(bufnr, {
      line = line,
      hl_group = "FlaresBackground",
    })
    M.set_virtual_text(bufnr, {
      line = line,
      text = icon_for_kind[kind] .. " " .. name,
      hl_group = "FlaresComment",
    })
  end,
  inline_name = function(bufnr, line, name, _)
    M.highlight_line(bufnr, {
      line = line,
      hl_group = "FlaresBackground",
    })
    M.set_virtual_text(bufnr, {
      line = line,
      text = name,
      hl_group = "FlaresComment",
    })
  end,
  inline_icon = function(bufnr, line, _, kind)
    M.highlight_line(bufnr, {
      line = line,
      hl_group = "FlaresBackground",
    })
    M.set_virtual_text(bufnr, {
      line = line,
      text = icon_for_kind[kind],
      hl_group = "FlaresComment",
    })
  end,
  inline_kind = function(bufnr, line, _, kind)
    M.highlight_line(bufnr, {
      line = line,
      hl_group = "FlaresBackground",
    })
    M.set_virtual_text(bufnr, {
      line = line,
      text = display_text_for_kind[kind],
      hl_group = "FlaresComment",
    })
  end,
  highlight_only = function(bufnr, line, _, _)
    M.highlight_line(bufnr, {
      line = line,
      hl_group = "FlaresBackground",
    })
  end,
}

M.highlight_lsp_content = function(bufnr)
  M.setup_namespaces()
  M.clear_all(bufnr)

  local lsp_content = M.get_document_symbols(bufnr)
  local handler = display_handlers[M.mode]
  if not handler then
    error("[Flares] Invalid display mode: " .. tostring(M.mode))
    return
  end

  for _, symbol in ipairs(lsp_content) do
    handler(bufnr, symbol.range.start.line, symbol.name, symbol.kind)
  end
end

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

-- Register autocmds for dynamic updates
local function setup_dynamic_updates(bufnr)
  local group = vim.api.nvim_create_augroup("FlareDynamicUpdates", { clear = true })

  -- Update on LSP symbol changes
  vim.api.nvim_create_autocmd("LspRequest", {
    group = group,
    pattern = "textDocument/documentSymbols",
    callback = function()
      -- Add debouncing to avoid rapid updates
      debounced_update(function()
        M.highlight_lsp_content(bufnr)
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
        M.highlight_lsp_content(bufnr)
      end, 500)
    end,
  })

  -- Update on window resize/layout changes
  vim.api.nvim_create_autocmd({ "WinResized" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      require("flares").highlight_lsp_content(bufnr)
    end,
  })
end

-- Function to remove all flare-related autocommands
function M.clear_autocommands()
  -- Clear all autocommands in our specific group
  vim.api.nvim_clear_autocmds({ group = "FlareDynamicUpdates" })
end

-- Call this when initializing your plugin for a buffer
M.attach_to_buffer = function(bufnr)
  setup_dynamic_updates(bufnr)
end

M.clear_all = function(buffer)
  M.clear_virtual_text(buffer)
  M.clear_line_highlights(buffer)
end

-- Create the user commands
vim.api.nvim_create_user_command("FlaresHighlight", function(opts)
  local mode = opts.args or "inline_icon_and_name"
  M.setup({ mode = mode })
  M.attach_to_buffer(M.current_buffer())
  M.highlight_lsp_content(M.current_buffer())
end, {
  nargs = 1,
  complete = function(_, _, _)
    -- Return list of completion options
    return {
      "above_kind",
      "above_icon_and_name",
      "inline_icon_and_name",
      "inline_icon",
      "inline_name",
      "inline_kind",
      "highlight_only",
    }
  end,
})

vim.api.nvim_create_user_command("FlaresClear", function()
  M.setup_namespaces()
  M.clear_all(M.current_buffer())
  M.clear_autocommands()
end, { range = true })

return M
