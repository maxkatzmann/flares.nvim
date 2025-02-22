pcall(vim.api.nvim_del_user_command, "FlaresHighlight")
pcall(vim.api.nvim_del_user_command, "FlaresClear")

local M = {}

-- Store namespace IDs internally
local virtual_text_ns = 0
local highlight_ns = 0

local function setup_highlight_groups()
  -- Get colors from LineNr highlight group
  local linenr_hl = vim.api.nvim_get_hl(0, { name = "LineNr" })
  local comment_hl = vim.api.nvim_get_hl(0, { name = "Comment" })

  -- Create highlight group with LineNr fg as bg
  vim.api.nvim_set_hl(0, "FlaresBackground", {
    bg = linenr_hl.fg and string.format("#%06x", linenr_hl.fg),
  })

  -- Create highlight group with LineNr fg as bg and Comment fg as fg
  vim.api.nvim_set_hl(0, "FlaresComment", {
    bg = linenr_hl.fg and string.format("#%06x", linenr_hl.fg),
    fg = comment_hl.fg and string.format("#%06x", comment_hl.fg),
  })
end

M.setup = function()
  -- Create namespaces once during setup
  virtual_text_ns = vim.api.nvim_create_namespace("flares_nvim_vtext")
  highlight_ns = vim.api.nvim_create_namespace("flares_nvim_highlight")

  setup_highlight_groups()
end

M.set_virtual_text = function(buffer, opts)
  local text = opts.text or ""
  local hl_group = opts.hl_group or "Normal"

  local extmark_opts = {
    id = opts.id,
    virt_text = { { text, hl_group } },
    virt_text_pos = opts.position or "right_align",
    priority = opts.priority or 1,
  }

  return vim.api.nvim_buf_set_extmark(buffer, virtual_text_ns, opts.line or 0, opts.col or 0, extmark_opts)
end

M.current_buffer = function()
  return vim.fn.bufnr("%")
end

M.clear_virtual_text = function(buffer)
  vim.api.nvim_buf_clear_namespace(buffer, virtual_text_ns, 0, -1)
end

-- M.highlight_line = function(buffer, opts)
--   local line = opts.line or 0
--   local bg_color = opts.bg_color
--   local new_hl_group = "FlaresNvim" .. highlight_ns .. "_" .. line
--
--   -- Get color from highlight group if a group name is provided
--   if type(bg_color) == "string" and not bg_color:match("^#") then
--     local existing_hl = vim.api.nvim_get_hl(0, { name = bg_color })
--     print("Got existing highlight", vim.inspect(existing_hl))
--     -- Try bg first, then fg if bg is nil
--     bg_color = existing_hl.bg and string.format("#%06x", existing_hl.bg)
--       or existing_hl.fg and string.format("#%06x", existing_hl.fg)
--       or nil
--   end
--
--   print("Using bg_color", bg_color)
--
--   -- Create highlight group
--   vim.api.nvim_set_hl(0, new_hl_group, { bg = bg_color })
--
--   return vim.api.nvim_buf_set_extmark(buffer, highlight_ns, line, 0, {
--     line_hl_group = new_hl_group,
--     priority = 10,
--   })
-- end

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

M.highlight_lsp_content = function(bufnr)
  local lsp_content = M.get_document_symbols(bufnr)

  local name_for_kind = {
    [5] = "󰯲",
    [12] = "󰯻",
    [6] = "󰰐",
  }

  for _, symbol in ipairs(lsp_content) do
    M.highlight_line(bufnr, {
      line = symbol.range.start.line,
      hl_group = "FlaresBackground", -- Use our custom group
    })
    M.set_virtual_text(bufnr, {
      line = symbol.range.start.line,
      text = name_for_kind[symbol.kind] .. " " .. symbol.name,
      hl_group = "FlaresComment", -- Use our custom group
    })
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
