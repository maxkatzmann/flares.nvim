local M = {}

-- Store namespace IDs internally
local virtual_text_ns = 0
local highlight_ns = 0

M.setup = function()
  -- Create namespaces once during setup
  virtual_text_ns = vim.api.nvim_create_namespace("flares_nvim_vtext")
  highlight_ns = vim.api.nvim_create_namespace("flares_nvim_highlight")
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

M.highlight_line = function(buffer, opts)
  local line = opts.line or 0
  local bg_color = opts.bg_color
  local hl_group = "FlaresNvim" .. highlight_ns .. "_" .. line

  -- Create highlight group
  vim.api.nvim_set_hl(0, hl_group, { bg = bg_color })

  -- Set the extmark with the background
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

M.clear_all = function(buffer)
  M.clear_virtual_text(buffer)
  M.clear_line_highlights(buffer)
end

M.setup()

M.clear_all(M.current_buffer())

-- M.highlight_line(M.current_buffer(), {
--   line = 60,
--   bg_color = "#ff0000",
-- })
--
-- M.set_virtual_text(M.current_buffer(), {
--   line = 60,
--   text = "Hello, world!",
--   hl_group = "IncSearch",
-- })

return M
