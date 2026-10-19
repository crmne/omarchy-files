-- Only bundled runtime syntax is loaded. File contents are data in a scratch
-- buffer, never opened as a file or evaluated as commands/modelines.
vim.opt.runtimepath = vim.env.VIMRUNTIME
vim.opt.packpath = ''
vim.opt.modeline = false
vim.opt.exrc = false
vim.opt.swapfile = false
vim.opt.shada = ''
vim.opt.loadplugins = false
-- Load only Omarchy's trusted theme specification and already installed theme
-- packages. Never start the user's plugin manager or install anything.
local function load_theme()
  local path = vim.fn.stdpath('config') .. '/lua/plugins/theme.lua'
  if vim.fn.filereadable(path) == 0 then return end
  local specs = dofile(path)
  local scheme
  for _, spec in ipairs(specs) do
    if spec[1] == 'LazyVim/LazyVim' then
      if type(spec.opts) == 'table' then scheme = spec.opts.colorscheme end
    elseif type(spec[1]) == 'string' then
      local name = spec.name or spec[1]:match('/([^/]+)$')
      local dir = spec.dir or (vim.fn.stdpath('data') .. '/lazy/' .. name)
      if vim.fn.isdirectory(dir) == 1 then
        vim.opt.runtimepath:prepend(dir)
        if type(spec.init) == 'function' then spec.init(spec) end
        local opts = spec.opts or {}
        if type(opts) == 'function' then opts = opts(spec, {}) or {} end
        if type(spec.config) == 'function' then spec.config(spec, opts)
        elseif spec.opts then
          local module = spec.main or name:gsub('%.nvim$', ''):gsub('%-neovim$', '')
          require(module).setup(opts)
        end
      end
    end
  end
  if type(scheme) == 'string' then vim.cmd.colorscheme(scheme) end
end
local theme_ok = pcall(load_theme)
local color_cache = {}
local function color(group)
  if color_cache[group] then return color_cache[group] end
  local hl = vim.api.nvim_get_hl(0, {name=group, link=false})
  local normal = vim.api.nvim_get_hl(0, {name='Normal', link=false})
  local fg = hl.fg or normal.fg
  color_cache[group] = fg and string.format('#%06x', fg) or ''
  return color_cache[group]
end
local input = vim.json.decode(io.read('*a'))
local lines = vim.split(input.text, '\n', { plain = true })
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.bo.buftype = 'nofile'
local ft = vim.filetype.match({ filename = input.name })
local tokens = {}
if ft and ft:match('^[%w_]+$') then
  vim.cmd('syntax enable')
  vim.bo.syntax = ft
  vim.cmd('syntax sync fromstart')
  local categories = {Comment='comment', String='string', Character='string',
    Number='number', Float='number', Boolean='number', Constant='number',
    Statement='keyword', PreProc='keyword', Type='keyword', Function='function',
    Special='string', Identifier='text', Operator='operator'}
  local function append(category, value, fg)
    local last = tokens[#tokens]
    if last and last[1] == category and last[3] == fg then last[2] = last[2] .. value
    else tokens[#tokens+1] = {category, value, fg} end
  end
  for row, line in ipairs(lines) do
    -- Iterate UTF-8 characters, while synID takes byte columns.
    for col, char in line:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
      local group = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.synID(row, col, 1)), 'name')
      append(#tokens < 2048 and (categories[group] or 'text') or 'text', char, color(group ~= '' and group or 'Normal'))
    end
    if row < #lines then append('text', '\n', color('Normal')) end
  end
end
local normal = vim.api.nvim_get_hl(0, {name='Normal', link=false})
io.write(vim.json.encode({tokens=tokens, language=ft or '', theme=theme_ok and vim.g.colors_name or '',
  background=normal.bg and string.format('#%06x', normal.bg) or ''}))
