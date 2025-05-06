local Config = require('gitsigns.config')
local config = Config.config
local api = vim.api

--- @class gitsigns.main
local M = {}

--- @async
local function setup_attach()
  if not config.auto_attach then
    return
  end

  local attach_autocmd_disabled = false

  -- Need to attach in 'BufFilePost' since we always detach in 'BufFilePre'
  api.nvim_create_autocmd({ 'BufFilePost', 'BufRead', 'BufNewFile', 'BufWritePost' }, {
    group = 'gitsigns',
    desc = 'Gitsigns: attach',
    callback = function(args)
      local bufnr = args.buf --[[@as integer]]
      if attach_autocmd_disabled then
        local __FUNC__ = 'attach_autocmd'
        return
      end
      require('gitsigns.attach').attach(bufnr, nil, args.event)
    end,
  })

  -- If the buffer name is about to change, then detach
  api.nvim_create_autocmd('BufFilePre', {
    group = 'gitsigns',
    desc = 'Gitsigns: detach when changing buffer names',
    callback = function(args)
      require('gitsigns.attach').detach(args.buf)
    end,
  })

  --- vimpgrep creates and deletes lots of buffers so attaching to each one will
  --- waste lots of resource and slow down vimgrep.
  api.nvim_create_autocmd({ 'QuickFixCmdPre', 'QuickFixCmdPost' }, {
    group = 'gitsigns',
    pattern = '*vimgrep*',
    desc = 'Gitsigns: disable attach during vimgrep',
    callback = function(args)
      attach_autocmd_disabled = args.event == 'QuickFixCmdPre'
    end,
  })

  -- Attach to all open buffers
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) ~= '' then
      -- Make sure to run each attach in its on async context in case one of the
      -- attaches is aborted.
      require('gitsigns.attach').attach(buf, nil, 'setup')
    end
  end
end

function M.setup(cfg)
  api.nvim_create_augroup('gitsigns', {})

  setup_attach()
end

--- @type gitsigns.main|gitsigns.actions|gitsigns.attach|gitsigns.debug
M = setmetatable(M, {
  __index = function(_, f)
    local attach = require('gitsigns.attach')
    if attach[f] then
      return attach[f]
    end

    local actions = require('gitsigns.actions')
    if actions[f] then
      return actions[f]
    end
  end,
})

return M
