pcall(vim.api.nvim_del_user_command, "FlaresHighlight")
pcall(vim.api.nvim_del_user_command, "FlaresClear")

local M = {}

-- Store namespace IDs internally
local virtual_text_ns = 0
local highlight_ns = 0

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

M.setup = function()
  -- Create namespaces once during setup
  virtual_text_ns = vim.api.nvim_create_namespace("flares_nvim_vtext")
  highlight_ns = vim.api.nvim_create_namespace("flares_nvim_highlight")

  setup_highlights()
end

M.set_virtual_text = function(bufnr, opts)
  local text = opts.text or ""
  local hl_group = opts.hl_group or "Normal"

  -- local extmark_opts = {
  --   id = opts.id,
  --   virt_text = { { text, hl_group } },
  --   virt_text_pos = opts.position or "right_align",
  --   priority = opts.priority or 1,
  -- }
  --
  -- return vim.api.nvim_buf_set_extmark(buffer, virtual_text_ns, opts.line or 0, opts.col or 0, extmark_opts)
  vim.api.nvim_buf_set_extmark(bufnr, virtual_text_ns, opts.line or 0, opts.col or 0, {
    virt_text = { { text, hl_group } },
    virt_text_pos = "overlay",
    -- Move to next line
    virt_lines = { { text, hl_group } },
    virt_lines_above = false,
  })
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
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 1000)

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

M.highlight_lsp_content = function(bufnr)
  local lsp_content = M.get_document_symbols(bufnr)

  local name_for_kind = {
    [5] = "󰯲",
    [12] = "󰯻",
    [6] = "󰰐",
  }

  local inline = false

  for _, symbol in ipairs(lsp_content) do
    if inline then
      M.highlight_line(bufnr, {
        line = symbol.range.start.line,
        hl_group = "FlaresBackground", -- Use our custom group
      })
      M.set_virtual_text(bufnr, {
        line = symbol.range.start.line,
        text = name_for_kind[symbol.kind] .. " " .. symbol.name,
        hl_group = "FlaresComment", -- Use our custom group
      })
    else
      M.add_virtual_line_above(
        M.current_buffer(),
        symbol.range.start.line + 1,
        name_for_kind[symbol.kind] .. " " .. symbol.name,
        "FlaresComment"
      )
    end
  end
end

M.clear_all = function(buffer)
  M.clear_virtual_text(buffer)
  M.clear_line_highlights(buffer)
end

-- Create the user commands
vim.api.nvim_create_user_command("FlaresHighlight", function()
  M.setup()
  M.highlight_lsp_content(M.current_buffer())
end, { range = true })

vim.api.nvim_create_user_command("FlaresClear", function()
  M.setup()
  M.clear_all(M.current_buffer())
end, { range = true })

return M
