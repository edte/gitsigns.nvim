local async = require('gitsigns.async')
local git = require('gitsigns.git')
local Hunks = require('gitsigns.hunks')
local manager = require('gitsigns.manager')
local message = require('gitsigns.message')
local popup = require('gitsigns.popup')
local util = require('gitsigns.util')
local run_diff = require('gitsigns.diff')

local config = require('gitsigns.config').config
local mk_repeatable = require('gitsigns.repeat').mk_repeatable
local cache = require('gitsigns.cache').cache

local api = vim.api
local current_buf = api.nvim_get_current_buf

--- @class gitsigns.actions
local M = {}

--- @class Gitsigns.CmdParams.Smods
--- @field vertical boolean
--- @field split 'aboveleft'|'belowright'|'topleft'|'botright'

--- @class Gitsigns.CmdArgs
--- @field vertical? boolean
--- @field split? boolean
--- @field global? boolean

--- @class Gitsigns.CmdParams
--- @field range integer
--- @field line1 integer
--- @field line2 integer
--- @field count integer
--- @field smods Gitsigns.CmdParams.Smods

--- Variations of functions from M which are used for the Gitsigns command
--- @type table<string,fun(args: Gitsigns.CmdArgs, params: Gitsigns.CmdParams)>
local C = {}

local CP = {}

local ns_inline = api.nvim_create_namespace('gitsigns_preview_inline')

--- @param arglead string
--- @return string[]
local function complete_heads(arglead)
  --- @type string[]
  local all =
    vim.fn.systemlist({ 'git', 'rev-parse', '--symbolic', '--branches', '--tags', '--remotes' })
  return vim.tbl_filter(
    --- @param x string
    --- @return boolean
    function(x)
      return vim.startswith(x, arglead)
    end,
    all
  )
end

--- Toggle |gitsigns-config-signbooleancolumn|
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of |gitsigns-config-signcolumn|
M.toggle_signs = function(value)
  if value ~= nil then
    config.signcolumn = value
  else
    config.signcolumn = not config.signcolumn
  end
  M.refresh()
  return config.signcolumn
end

--- Toggle |gitsigns-config-numhl|
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
---
--- @return boolean : Current value of |gitsigns-config-numhl|
M.toggle_numhl = function(value)
  if value ~= nil then
    config.numhl = value
  else
    config.numhl = not config.numhl
  end
  M.refresh()
  return config.numhl
end

--- Toggle |gitsigns-config-linehl|
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of |gitsigns-config-linehl|
M.toggle_linehl = function(value)
  if value ~= nil then
    config.linehl = value
  else
    config.linehl = not config.linehl
  end
  M.refresh()
  return config.linehl
end

--- Toggle |gitsigns-config-word_diff|
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of |gitsigns-config-word_diff|
M.toggle_word_diff = function(value)
  if value ~= nil then
    config.word_diff = value
  else
    config.word_diff = not config.word_diff
  end
  -- Don't use refresh() to avoid flicker
  util.redraw({ buf = 0, range = { vim.fn.line('w0') - 1, vim.fn.line('w$') } })
  return config.word_diff
end

--- Toggle |gitsigns-config-current_line_blame|
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of |gitsigns-config-current_line_blame|
M.toggle_current_line_blame = function(value)
  if value ~= nil then
    config.current_line_blame = value
  else
    config.current_line_blame = not config.current_line_blame
  end
  M.refresh()
  return config.current_line_blame
end

--- @deprecated Use |gitsigns.preview_hunk_inline()|
--- Toggle |gitsigns-config-show_deleted|
---
--- @param value boolean|nil Value to set toggle. If `nil`
---     the toggle value is inverted.
--- @return boolean : Current value of |gitsigns-config-show_deleted|
M.toggle_deleted = function(value)
  if value ~= nil then
    config.show_deleted = value
  else
    config.show_deleted = not config.show_deleted
  end
  M.refresh()
  return config.show_deleted
end

--- @param bufnr? integer
--- @param hunks? Gitsigns.Hunk.Hunk[]?
--- @return Gitsigns.Hunk.Hunk? hunk
--- @return integer? index
local function get_cursor_hunk(bufnr, hunks)
  bufnr = bufnr or current_buf()

  if not hunks then
    if not cache[bufnr] then
      return
    end
    hunks = {}
    vim.list_extend(hunks, cache[bufnr].hunks or {})
    vim.list_extend(hunks, cache[bufnr].hunks_staged or {})
  end

  local lnum = api.nvim_win_get_cursor(0)[1]
  return Hunks.find_hunk(lnum, hunks)
end

--- @param bufnr integer
local function update(bufnr)
  manager.update(bufnr)
  if not manager.schedule(bufnr) then
    return
  end
  if vim.wo.diff then
    require('gitsigns.diffthis').update(bufnr)
  end
end

local function get_range(params)
  local range --- @type {[1]: integer, [2]: integer}?
  if params.range > 0 then
    range = { params.line1, params.line2 }
  end
  return range
end

--- @async
--- @param bufnr integer
--- @param bcache Gitsigns.CacheEntry
--- @param greedy? boolean
--- @param staged? boolean
--- @return Gitsigns.Hunk.Hunk[]? hunks
local function get_hunks(bufnr, bcache, greedy, staged)
  if greedy and config.diff_opts.linematch then
    -- Re-run the diff without linematch
    local buftext = util.buf_lines(bufnr)
    local text --- @type string[]?
    if staged then
      text = bcache.compare_text_head
    else
      text = bcache.compare_text
    end
    if not text then
      return
    end
    local hunks = run_diff(text, buftext, false)
    if not manager.schedule(bufnr) then
      return
    end
    return hunks
  end

  if staged then
    return vim.deepcopy(bcache.hunks_staged)
  end

  return vim.deepcopy(bcache.hunks)
end

--- @param bufnr integer
--- @param range? {[1]: integer, [2]: integer}
--- @param greedy? boolean
--- @param staged? boolean
--- @return Gitsigns.Hunk.Hunk?
local function get_hunk(bufnr, range, greedy, staged)
  local bcache = cache[bufnr]
  if not bcache then
    return
  end
  local hunks = get_hunks(bufnr, bcache, greedy, staged)

  if not range then
    local hunk = get_cursor_hunk(bufnr, hunks)
    return hunk
  end

  table.sort(range)
  local top, bot = range[1], range[2]
  local hunk = Hunks.create_partial_hunk(hunks or {}, top, bot)
  hunk.added.lines = api.nvim_buf_get_lines(bufnr, top - 1, bot, false)
  hunk.removed.lines = vim.list_slice(
    bcache.compare_text,
    hunk.removed.start,
    hunk.removed.start + hunk.removed.count - 1
  )
  return hunk
end

--- Stage the hunk at the cursor position, or all lines in the
--- given range. If {range} is provided, all lines in the given
--- range are staged. This supports partial-hunks, meaning if a
--- range only includes a portion of a particular hunk, only the
--- lines within the range will be staged.
---
--- Attributes: ~
---     {async}
---
--- @param range table|nil List-like table of two integers making
---             up the line range from which you want to stage the hunks.
---             If running via command line, then this is taken from the
---             command modifiers.
--- @param opts table|nil Additional options:
---             • {greedy}: (boolean)
---               Stage all contiguous hunks. Only useful if 'diff_opts'
---               contains `linematch`. Defaults to `true`.
M.stage_hunk = mk_repeatable(async.create(2, function(range, opts)
  --- @cast range {[1]: integer, [2]: integer}?

  opts = opts or {}
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  if bcache:locked() then
    print('Error: busy')
    return
  end

  if not util.path_exists(bcache.file) then
    print('Error: Cannot stage lines. Please add the file to the working tree.')
    return
  end

  local hunk = get_hunk(bufnr, range, opts.greedy ~= false, false)

  local invert = false
  if not hunk then
    invert = true
    hunk = get_hunk(bufnr, range, opts.greedy ~= false, true)
  end

  if not hunk then
    api.nvim_echo({ { 'No hunk to stage', 'WarningMsg' } }, false, {})
    return
  end

  local err = bcache.git_obj:stage_hunks({ hunk }, invert)
  if err then
    message.error(err)
    return
  end
  table.insert(bcache.staged_diffs, hunk)

  bcache:invalidate(true)
  update(bufnr)
end))

C.stage_hunk = function(_, params)
  M.stage_hunk(get_range(params))
end

--- @param bufnr integer
--- @param hunk Gitsigns.Hunk.Hunk
local function reset_hunk(bufnr, hunk)
  local lstart, lend --- @type integer, integer
  if hunk.type == 'delete' then
    lstart = hunk.added.start
    lend = hunk.added.start
  else
    lstart = hunk.added.start - 1
    lend = hunk.added.start - 1 + hunk.added.count
  end

  if hunk.removed.no_nl_at_eof ~= hunk.added.no_nl_at_eof then
    local no_eol = hunk.added.no_nl_at_eof or false
    vim.bo[bufnr].endofline = no_eol
    vim.bo[bufnr].fixendofline = no_eol
  end

  util.set_lines(bufnr, lstart, lend, hunk.removed.lines)
end

--- Reset the lines of the hunk at the cursor position, or all
--- lines in the given range. If {range} is provided, all lines in
--- the given range are reset. This supports partial-hunks,
--- meaning if a range only includes a portion of a particular
--- hunk, only the lines within the range will be reset.
---
--- @param range table|nil List-like table of two integers making
---     up the line range from which you want to reset the hunks.
---     If running via command line, then this is taken from the
---     command modifiers.
--- @param opts table|nil Additional options:
---     • {greedy}: (boolean)
---       Stage all contiguous hunks. Only useful if 'diff_opts'
---       contains `linematch`. Defaults to `true`.
M.reset_hunk = mk_repeatable(async.create(2, function(range, opts)
  --- @cast range {[1]: integer, [2]: integer}?

  opts = opts or {}
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local hunk = get_hunk(bufnr, range, opts.greedy ~= false, false)

  if not hunk then
    api.nvim_echo({ { 'No hunk to reset', 'WarningMsg' } }, false, {})
    return
  end

  reset_hunk(bufnr, hunk)
end))

C.reset_hunk = function(_, params)
  M.reset_hunk(get_range(params))
end

--- Reset the lines of all hunks in the buffer.
M.reset_buffer = function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local hunks = bcache.hunks
  if not hunks or #hunks == 0 then
    api.nvim_echo({ { 'No unstaged changes in the buffer to reset', 'WarningMsg' } }, false, {})
    return
  end

  for i = #hunks, 1, -1 do
    reset_hunk(bufnr, hunks[i])
  end
end

--- @deprecated use |gitsigns.stage_hunk()| on staged signs
--- Undo the last call of stage_hunk().
---
--- Note: only the calls to stage_hunk() performed in the current
--- session can be undone.
---
--- Attributes: ~
---     {async}
M.undo_stage_hunk = async.create(function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  if bcache:locked() then
    print('Error: busy')
    return
  end

  local hunk = table.remove(bcache.staged_diffs)
  if not hunk then
    print('No hunks to undo')
    return
  end

  local err = bcache.git_obj:stage_hunks({ hunk }, true)
  if err then
    message.error(err)
    return
  end
  bcache:invalidate(true)
  update(bufnr)
end)

--- Stage all hunks in current buffer.
---
--- Attributes: ~
---     {async}
M.stage_buffer = async.create(function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  if bcache:locked() then
    print('Error: busy')
    return
  end

  -- Only process files with existing hunks
  local hunks = bcache.hunks
  if not hunks or #hunks == 0 then
    print('No unstaged changes in file to stage')
    return
  end

  if not util.path_exists(bcache.git_obj.file) then
    print('Error: Cannot stage file. Please add it to the working tree.')
    return
  end

  local err = bcache.git_obj:stage_hunks(hunks)
  if err then
    message.error(err)
    return
  end

  for _, hunk in ipairs(hunks) do
    table.insert(bcache.staged_diffs, hunk)
  end

  bcache:invalidate(true)
  update(bufnr)
end)

--- Unstage all hunks for current buffer in the index. Note:
--- Unlike |gitsigns.undo_stage_hunk()| this doesn't simply undo
--- stages, this runs an `git reset` on current buffers file.
---
--- Attributes: ~
---     {async}
M.reset_buffer_index = async.create(function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  if bcache:locked() then
    print('Error: busy')
    return
  end

  -- `bcache.staged_diffs` won't contain staged changes outside of current
  -- neovim session so signs added from this unstage won't be complete They will
  -- however be fixed by gitdir watcher and properly updated We should implement
  -- some sort of initial population from git diff, after that this function can
  -- be improved to check if any staged hunks exists and it can undo changes
  -- using git apply line by line instead of resetting whole file
  bcache.staged_diffs = {}

  bcache.git_obj:unstage_file()
  bcache:invalidate(true)
  update(bufnr)
end)

--- @class Gitsigns.NavOpts
--- @field wrap boolean
--- @field foldopen boolean
--- @field navigation_message boolean
--- @field greedy boolean
--- @field preview boolean
--- @field count integer
--- @field target 'unstaged'|'staged'|'all'

--- @param x string
--- @param word string
--- @return boolean
local function findword(x, word)
  return string.find(x, '%f[%w_]' .. word .. '%f[^%w_]') ~= nil
end

--- @param opts? Gitsigns.NavOpts
--- @return Gitsigns.NavOpts
local function process_nav_opts(opts)
  opts = opts or {}

  -- show navigation message
  if opts.navigation_message == nil then
    opts.navigation_message = vim.o.shortmess:find('S') == nil
  end

  -- wrap around
  if opts.wrap == nil then
    opts.wrap = vim.o.wrapscan
  end

  if opts.foldopen == nil then
    opts.foldopen = findword(vim.o.foldopen, 'search')
  end

  if opts.greedy == nil then
    opts.greedy = true
  end

  if opts.count == nil then
    opts.count = vim.v.count1
  end

  if opts.target == nil then
    opts.target = 'unstaged'
  end

  return opts
end

-- Defer function to the next main event
--- @param fn function
local function defer(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    vim.defer_fn(fn, 1)
  end
end

--- @param bufnr integer
--- @return boolean
local function has_preview_inline(bufnr)
  return #api.nvim_buf_get_extmarks(bufnr, ns_inline, 0, -1, { limit = 1 }) > 0
end

--- @param bufnr integer
--- @param target 'unstaged'|'staged'|'all'
--- @param greedy boolean
--- @return Gitsigns.Hunk.Hunk[]
local function get_nav_hunks(bufnr, target, greedy)
  local bcache = assert(cache[bufnr])
  local hunks_main = get_hunks(bufnr, bcache, greedy, false) or {}

  local hunks --- @type Gitsigns.Hunk.Hunk[]
  if target == 'unstaged' then
    hunks = hunks_main
  else
    local hunks_head = get_hunks(bufnr, bcache, greedy, true) or {}
    hunks_head = Hunks.filter_common(hunks_head, hunks_main) or {}
    if target == 'all' then
      hunks = hunks_main
      vim.list_extend(hunks, hunks_head)
      table.sort(hunks, function(h1, h2)
        return h1.added.start < h2.added.start
      end)
    elseif target == 'staged' then
      hunks = hunks_head
    end
  end
  return hunks
end

--- @async
--- @param direction 'first'|'last'|'next'|'prev'
--- @param opts? Gitsigns.NavOpts
local function nav_hunk(direction, opts)
  opts = process_nav_opts(opts)
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local hunks = get_nav_hunks(bufnr, opts.target, opts.greedy)

  if not hunks or vim.tbl_isempty(hunks) then
    if opts.navigation_message then
      api.nvim_echo({ { 'No hunks', 'WarningMsg' } }, false, {})
    end
    return
  end

  local line = api.nvim_win_get_cursor(0)[1]
  local index --- @type integer?

  local forwards = direction == 'next' or direction == 'last'

  for _ = 1, opts.count do
    index = Hunks.find_nearest_hunk(line, hunks, direction, opts.wrap)

    if not index then
      if opts.navigation_message then
        api.nvim_echo({ { 'No more hunks', 'WarningMsg' } }, false, {})
      end
      local _, col = vim.fn.getline(line):find('^%s*')
      api.nvim_win_set_cursor(0, { line, col })
      return
    end

    line = forwards and hunks[index].added.start or hunks[index].vend
  end

  -- Handle topdelete
  line = math.max(line, 1)

  vim.cmd([[ normal! m' ]]) -- add current cursor position to the jump list

  local _, col = vim.fn.getline(line):find('^%s*')
  api.nvim_win_set_cursor(0, { line, col })

  if opts.foldopen then
    vim.cmd('silent! foldopen!')
  end

  if opts.preview or popup.is_open('hunk') ~= nil then
    -- Use defer so the cursor change can settle, otherwise the popup might
    -- appear in the old position
    defer(function()
      -- Close the popup in case one is open which will cause it to focus the
      -- popup
      popup.close('hunk')
      M.preview_hunk()
    end)
  elseif has_preview_inline(bufnr) then
    defer(M.preview_hunk_inline)
  end

  if index and opts.navigation_message then
    api.nvim_echo({ { string.format('Hunk %d of %d', index, #hunks), 'None' } }, false, {})
  end
end

--- Jump to hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the next hunk.
---
--- Attributes: ~
---     {async}
---
--- @param direction 'first'|'last'|'next'|'prev'
--- @param opts table|nil Configuration table. Keys:
---     • {wrap}: (boolean)
---       Whether to loop around file or not. Defaults
---       to the value 'wrapscan'
---     • {navigation_message}: (boolean)
---       Whether to show navigation messages or not.
---       Looks at 'shortmess' for default behaviour.
---     • {foldopen}: (boolean)
---       Expand folds when navigating to a hunk which is
---       inside a fold. Defaults to `true` if 'foldopen'
---       contains `search`.
---     • {preview}: (boolean)
---       Automatically open preview_hunk() upon navigating
---       to a hunk.
---     • {greedy}: (boolean)
---       Only navigate between non-contiguous hunks. Only useful if
---       'diff_opts' contains `linematch`. Defaults to `true`.
---     • {target}: (`'unstaged'|'staged'|'all'`)
---       Which kinds of hunks to target. Defaults to `'unstaged'`.
---     • {count}: (integer)
---       Number of times to advance. Defaults to |v:count1|.
M.nav_hunk = async.create(2, function(direction, opts)
  nav_hunk(direction, opts)
end)

C.nav_hunk = function(args, _)
  M.nav_hunk(args[1], args)
end

--- @deprecated use |gitsigns.nav_hunk()|
--- Jump to the next hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the next hunk.
---
--- Attributes: ~
---     {async}
---
--- Parameters: ~
---     See |gitsigns.nav_hunk()|.
M.next_hunk = async.create(1, function(opts)
  nav_hunk('next', opts)
end)

C.next_hunk = function(args, _)
  M.nav_hunk('next', args)
end

--- @deprecated use |gitsigns.nav_hunk()|
--- Jump to the previous hunk in the current buffer. If a hunk preview
--- (popup or inline) was previously opened, it will be re-opened
--- at the previous hunk.
---
--- Attributes: ~
---     {async}
---
--- Parameters: ~
---     See |gitsigns.nav_hunk()|.
M.prev_hunk = async.create(1, function(opts)
  nav_hunk('prev', opts)
end)

C.prev_hunk = function(args, _)
  M.nav_hunk('prev', args)
end

--- @param fmt Gitsigns.LineSpec
--- @param info table
--- @return Gitsigns.LineSpec
local function lines_format(fmt, info)
  local ret = vim.deepcopy(fmt)

  for _, line in ipairs(ret) do
    for _, s in ipairs(line) do
      s[1] = util.expand_format(s[1], info)
    end
  end

  return ret
end

--- @param hunk Gitsigns.Hunk.Hunk
--- @param fileformat string
--- @return Gitsigns.LineSpec
local function linespec_for_hunk(hunk, fileformat)
  local hls = {} --- @type Gitsigns.LineSpec

  local removed, added = hunk.removed.lines, hunk.added.lines

  for _, spec in ipairs({
    { sym = '-', lines = removed, hl = 'GitSignsDeletePreview' },
    { sym = '+', lines = added, hl = 'GitSignsAddPreview' },
  }) do
    for _, l in ipairs(spec.lines) do
      if fileformat == 'dos' then
        l = l:gsub('\r$', '') --[[@as string]]
      end
      hls[#hls + 1] = {
        {
          spec.sym .. l,
          {
            {
              hl_group = spec.hl,
              end_row = 1, -- Highlight whole line
            },
          },
        },
      }
    end
  end

  if config.diff_opts.internal then
    local removed_regions, added_regions =
      require('gitsigns.diff_int').run_word_diff(removed, added)

    for _, region in ipairs(removed_regions) do
      local i = region[1]
      table.insert(hls[i][1][2], {
        hl_group = 'GitSignsDeleteInline',
        start_col = region[3],
        end_col = region[4],
      })
    end

    for _, region in ipairs(added_regions) do
      local i = hunk.removed.count + region[1]
      table.insert(hls[i][1][2], {
        hl_group = 'GitSignsAddInline',
        start_col = region[3],
        end_col = region[4],
      })
    end
  end

  return hls
end

local function noautocmd(f)
  return function()
    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    f()
    vim.o.eventignore = ei
  end
end

--- Preview the hunk at the cursor position in a floating
--- window. If the preview is already open, calling this
--- will cause the window to get focus.
M.preview_hunk = noautocmd(function()
  -- Wrap in noautocmd so vim-repeat continues to work

  if popup.focus_open('hunk') then
    return
  end

  local bufnr = current_buf()

  local hunk, index = get_cursor_hunk(bufnr)

  if not hunk then
    return
  end

  local preview_linespec = {
    { { 'Hunk <hunk_no> of <num_hunks>', 'Title' } },
    unpack(linespec_for_hunk(hunk, vim.bo[bufnr].fileformat)),
  }

  local lines_spec = lines_format(preview_linespec, {
    hunk_no = index,
    num_hunks = #cache[bufnr].hunks,
  })

  popup.create(lines_spec, config.preview_config, 'hunk')
end)

local function clear_preview_inline(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns_inline, 0, -1)
end

--- @param keys string
local function feedkeys(keys)
  local cy = api.nvim_replace_termcodes(keys, true, false, true)
  api.nvim_feedkeys(cy, 'n', false)
end

--- @param bufnr integer
--- @param greedy? boolean
--- @return Gitsigns.Hunk.Hunk? hunk
--- @return boolean? staged
local function get_hunk_with_staged(bufnr, greedy)
  local hunk = get_hunk(bufnr, nil, greedy, false)
  if hunk then
    return hunk, false
  end

  hunk = get_hunk(bufnr, nil, greedy, true)
  if hunk then
    return hunk, true
  end
end

--- Preview the hunk at the cursor position inline in the buffer.
M.preview_hunk_inline = async.create(function()
  local bufnr = current_buf()

  local hunk, staged = get_hunk_with_staged(bufnr, true)

  if not hunk then
    return
  end

  clear_preview_inline(bufnr)

  local winid --- @type integer
  manager.show_added(bufnr, ns_inline, hunk)
  if hunk.removed.count > 0 then
    winid = manager.show_deleted_in_float(bufnr, ns_inline, hunk, staged)
  end

  api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter' }, {
    buffer = bufnr,
    desc = 'Clear gitsigns inline preview',
    callback = function()
      if winid then
        pcall(api.nvim_win_close, winid, true)
      end
      clear_preview_inline(bufnr)
    end,
    once = true,
  })

  -- Virtual lines will be hidden if they are placed on the top row, so
  -- automatically scroll the viewport.
  if hunk.added.start <= 1 then
    feedkeys(hunk.removed.count .. '<C-y>')
  end
end)

--- Select the hunk under the cursor.
---
--- @param opts table|nil Additional options:
---             • {greedy}: (boolean)
---               Select all contiguous hunks. Only useful if 'diff_opts'
---               contains `linematch`. Defaults to `true`.
M.select_hunk = function(opts)
  local bufnr = current_buf()
  opts = opts or {}
  local hunk = get_hunk(bufnr, nil, opts.greedy ~= false)
  if not hunk then
    return
  end

  vim.cmd('normal! ' .. hunk.added.start .. 'GV' .. hunk.vend .. 'G')
end

--- Get hunk array for specified buffer.
---
--- @param bufnr integer Buffer number, if not provided (or 0)
---             will use current buffer.
--- @return table|nil : Array of hunk objects.
---     Each hunk object has keys:
---         • `"type"`: String with possible values: "add", "change",
---           "delete"
---         • `"head"`: Header that appears in the unified diff
---           output.
---         • `"lines"`: Line contents of the hunks prefixed with
---           either `"-"` or `"+"`.
---         • `"removed"`: Sub-table with fields:
---           • `"start"`: Line number (1-based)
---           • `"count"`: Line count
---         • `"added"`: Sub-table with fields:
---           • `"start"`: Line number (1-based)
---           • `"count"`: Line count
M.get_hunks = function(bufnr)
  bufnr = bufnr or current_buf()
  if not cache[bufnr] then
    return
  end
  local ret = {} --- @type Gitsigns.Hunk.Hunk_Public[]
  -- TODO(lewis6991): allow this to accept a greedy option
  for _, h in ipairs(cache[bufnr].hunks or {}) do
    ret[#ret + 1] = {
      head = h.head,
      lines = Hunks.patch_lines(h, vim.bo[bufnr].fileformat),
      type = h.type,
      added = h.added,
      removed = h.removed,
    }
  end
  return ret
end

--- @param repo Gitsigns.Repo
--- @param info Gitsigns.BlameInfoPublic
--- @return Gitsigns.Hunk.Hunk?, integer?, integer
local function get_blame_hunk(repo, info)
  local a = {}
  -- If no previous so sha of blame added the file
  if info.previous_sha and info.previous_filename then
    a = repo:get_show_text(info.previous_sha .. ':' .. info.previous_filename)
  end
  local b = repo:get_show_text(info.sha .. ':' .. info.filename)
  local hunks = run_diff(a, b, false)
  local hunk, i = Hunks.find_hunk(info.orig_lnum, hunks)
  return hunk, i, #hunks
end

--- @param is_committed boolean
--- @param full boolean
--- @return {[1]: string, [2]: string}[][]
local function create_blame_fmt(is_committed, full)
  if not is_committed then
    return {
      { { '<author>', 'Label' } },
    }
  end

  return {
    {
      { '<abbrev_sha> ', 'Directory' },
      { '<author> ', 'MoreMsg' },
      { '(<author_time:%Y-%m-%d %H:%M>)', 'Label' },
      { ':', 'NormalFloat' },
    },
    { { full and '<body>' or '<summary>', 'NormalFloat' } },
  }
end

--- Run git blame on the current line and show the results in a
--- floating window. If already open, calling this will cause the
--- window to get focus.
---
--- Attributes: ~
---     {async}
---
--- @param opts table|nil Additional options:
---     • {full}: (boolean)
---       Display full commit message with hunk.
---     • {ignore_whitespace}: (boolean)
---       Ignore whitespace when running blame.
---     • {extra_opts}: (string[])
---       Extra options passed to `git-blame`.
M.blame_line = async.create(1, function(opts)
  if popup.focus_open('blame') then
    return
  end

  --- @type Gitsigns.LineBlameOpts
  opts = opts or {}

  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local loading = vim.defer_fn(function()
    popup.create({ { { 'Loading...', 'Title' } } }, config.preview_config)
  end, 1000)

  if not manager.schedule(bufnr) then
    return
  end

  local fileformat = vim.bo[bufnr].fileformat
  local lnum = api.nvim_win_get_cursor(0)[1]
  local result = bcache:get_blame(lnum, opts)
  pcall(function()
    loading:close()
  end)

  if not manager.schedule(bufnr) then
    return
  end

  result = util.convert_blame_info(assert(result))

  local is_committed = result.sha and tonumber('0x' .. result.sha) ~= 0

  local blame_linespec = create_blame_fmt(is_committed, opts.full)

  if is_committed and opts.full then
    local body = bcache.git_obj.repo:command(
      { 'show', '-s', '--format=%B', result.sha },
      { text = true }
    )
    local hunk, hunk_no, num_hunks = get_blame_hunk(bcache.git_obj.repo, result)
    assert(hunk and hunk_no and num_hunks)

    result.hunk_no = hunk_no
    result.body = body
    result.num_hunks = num_hunks
    result.hunk_head = hunk.head

    vim.list_extend(blame_linespec, {
      { { 'Hunk <hunk_no> of <num_hunks>', 'Title' }, { ' <hunk_head>', 'LineNr' } },
      unpack(linespec_for_hunk(hunk, fileformat)),
    })
  end

  if not manager.schedule(bufnr) then
    return
  end

  popup.create(lines_format(blame_linespec, result), config.preview_config, 'blame')
end)

C.blame_line = function(args, _)
  M.blame_line(args)
end

--- Run git-blame on the current file and open the results
--- in a scroll-bound vertical split.
---
--- Mappings:
---   <CR> is mapped to open a menu with the other mappings
---        Note: <Alt> must be held to activate the mappings whilst the menu is
---        open.
---   s   [Show commit] in a vertical split.
---   S   [Show commit] in a new tab.
---   r   [Reblame at commit]
---
--- Attributes: ~
---     {async}
M.blame = async.create(0, function()
  return require('gitsigns.blame').blame()
end)

--- @param bcache Gitsigns.CacheEntry
--- @param base string?
local function update_buf_base(bcache, base)
  bcache.file_mode = base == 'FILE'
  if not bcache.file_mode then
    bcache.git_obj:update_revision(base)
  end
  bcache:invalidate(true)
  update(bcache.bufnr)
end

--- Change the base revision to diff against. If {base} is not
--- given, then the original base is used. If {global} is given
--- and true, then change the base revision of all buffers,
--- including any new buffers.
---
--- Attributes: ~
---     {async}
---
--- Examples: >vim
---   " Change base to 1 commit behind head
---   :lua require('gitsigns').change_base('HEAD~1')
---
---   " Also works using the Gitsigns command
---   :Gitsigns change_base HEAD~1
---
---   " Other variations
---   :Gitsigns change_base ~1
---   :Gitsigns change_base ~
---   :Gitsigns change_base ^
---
---   " Commits work too
---   :Gitsigns change_base 92eb3dd
---
---   " Revert to original base
---   :Gitsigns change_base
--- <
---
--- For a more complete list of ways to specify bases, see
--- |gitsigns-revision|.
---
--- @param base string|nil The object/revision to diff against.
--- @param global boolean|nil Change the base of all buffers.
M.change_base = async.create(2, function(base, global)
  base = util.norm_base(base)

  if global then
    config.base = base

    for _, bcache in pairs(cache) do
      update_buf_base(bcache, base)
    end
  else
    local bufnr = current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end

    update_buf_base(bcache, base)
  end
end)

C.change_base = function(args, _)
  M.change_base(args[1], (args[2] or args.global))
end

CP.change_base = complete_heads

--- Reset the base revision to diff against back to the
--- index.
---
--- Alias for `change_base(nil, {global})` .
M.reset_base = function(global)
  M.change_base(nil, global)
end

C.reset_base = function(args, _)
  M.change_base(nil, (args[1] or args.global))
end

--- Perform a |vimdiff| on the given file with {base} if it is
--- given, or with the currently set base (index by default).
---
--- If {base} is the index, then the opened buffer is editable and
--- any written changes will update the index accordingly.
---
--- Examples: >vim
---   " Diff against the index
---   :Gitsigns diffthis
---
---   " Diff against the last commit
---   :Gitsigns diffthis ~1
--- <
---
--- For a more complete list of ways to specify bases, see
--- |gitsigns-revision|.
---
--- Attributes: ~
---     {async}
---
--- @param base string|nil Revision to diff against. Defaults to index.
--- @param opts table|nil Additional options:
---     • {vertical}: {boolean}. Split window vertically. Defaults to
---       config.diff_opts.vertical. If running via command line, then
---       this is taken from the command modifiers.
---     • {split}: {string}. One of: 'aboveleft', 'belowright',
---       'botright', 'rightbelow', 'leftabove', 'topleft'. Defaults to
---       'aboveleft'. If running via command line, then this is taken
---       from the command modifiers.
M.diffthis = function(base, opts)
  -- TODO(lewis6991): can't pass numbers as strings from the command line
  if base ~= nil then
    base = tostring(base)
  end
  opts = opts or {}
  if opts.vertical == nil then
    opts.vertical = config.diff_opts.vertical
  end
  require('gitsigns.diffthis').diffthis(base, opts)
end

C.diffthis = function(args, params)
  -- TODO(lewis6991): validate these
  local opts = {
    vertical = args.vertical,
    split = args.split,
  }

  if params.smods then
    if params.smods.split ~= '' and opts.split == nil then
      opts.split = params.smods.split
    end
    if opts.vertical == nil then
      opts.vertical = params.smods.vertical
    end
  end

  M.diffthis(args[1], opts)
end

CP.diffthis = complete_heads

-- C.test = function(pos_args: {any}, named_args: {string:any}, params: api.UserCmdParams)
--    print('POS ARGS:', vim.inspect(pos_args))
--    print('NAMED ARGS:', vim.inspect(named_args))
--    print('PARAMS:', vim.inspect(params))
-- end

--- Show revision {base} of the current file, if it is given, or
--- with the currently set base (index by default).
---
--- If {base} is the index, then the opened buffer is editable and
--- any written changes will update the index accordingly.
---
--- Examples: >vim
---   " View the index version of the file
---   :Gitsigns show
---
---   " View revision of file in the last commit
---   :Gitsigns show ~1
--- <
---
--- For a more complete list of ways to specify bases, see
--- |gitsigns-revision|.
---
--- Attributes: ~
---     {async}
M.show = function(revision, callback)
  local bufnr = api.nvim_get_current_buf()
  if not cache[bufnr] then
    print('Error: Buffer is not attached.')
    return
  end
  local diffthis = require('gitsigns.diffthis')
  diffthis.show(bufnr, revision, callback)
end

C.show = function(args, _)
  M.show(args[1])
end

CP.show = complete_heads

--- @param buf_or_filename string|integer
--- @param hunks Gitsigns.Hunk.Hunk[]
--- @param qflist table[]?
local function hunks_to_qflist(buf_or_filename, hunks, qflist)
  for i, hunk in ipairs(hunks) do
    qflist[#qflist + 1] = {
      bufnr = type(buf_or_filename) == 'number' and buf_or_filename or nil,
      filename = type(buf_or_filename) == 'string' and buf_or_filename or nil,
      lnum = hunk.added.start,
      text = string.format('Lines %d-%d (%d/%d)', hunk.added.start, hunk.vend, i, #hunks),
    }
  end
end

--- @param target 'all'|'attached'|integer|nil
--- @return table[]?
local function buildqflist(target)
  target = target or current_buf()
  if target == 0 then
    target = current_buf()
  end
  local qflist = {} --- @type table[]

  if type(target) == 'number' then
    local bufnr = target
    if not cache[bufnr] then
      return
    end
    hunks_to_qflist(bufnr, cache[bufnr].hunks, qflist)
  elseif target == 'attached' then
    for bufnr, bcache in pairs(cache) do
      hunks_to_qflist(bufnr, bcache.hunks, qflist)
    end
  elseif target == 'all' then
    local repos = {} --- @type table<string,Gitsigns.Repo>
    for _, bcache in pairs(cache) do
      local repo = bcache.git_obj.repo
      if not repos[repo.gitdir] then
        repos[repo.gitdir] = repo
      end
    end

    local repo = git.Repo.get(assert(vim.loop.cwd()))
    if repo and not repos[repo.gitdir] then
      repos[repo.gitdir] = repo
    end

    for _, r in pairs(repos) do
      for _, f in ipairs(r:files_changed(config.base)) do
        local f_abs = r.toplevel .. '/' .. f
        local stat = vim.loop.fs_stat(f_abs)
        if stat and stat.type == 'file' then
          ---@type string
          local obj
          if config.base and config.base ~= ':0' then
            obj = config.base .. ':' .. f
          else
            obj = ':0:' .. f
          end
          local a = r:get_show_text(obj)
          async.scheduler()
          local hunks = run_diff(a, util.file_lines(f_abs))
          hunks_to_qflist(f_abs, hunks, qflist)
        end
      end
    end
  end
  return qflist
end

--- Populate the quickfix list with hunks. Automatically opens the
--- quickfix window.
---
--- Attributes: ~
---     {async}
---
--- @param target integer|string
---     Specifies which files hunks are collected from.
---     Possible values.
---     • [integer]: The buffer with the matching buffer
---       number. `0` for current buffer (default).
---     • `"attached"`: All attached buffers.
---     • `"all"`: All modified files for each git
---       directory of all attached buffers in addition
---       to the current working directory.
--- @param opts table|nil Additional options:
---     • {use_location_list}: (boolean)
---       Populate the location list instead of the
---       quickfix list. Default to `false`.
---     • {nr}: (integer)
---       Window number or ID when using location list.
---       Expand folds when navigating to a hunk which is
---       inside a fold. Defaults to `0`.
---     • {open}: (boolean)
---       Open the quickfix/location list viewer.
---       Defaults to `true`.
M.setqflist = async.create(2, function(target, opts)
  opts = opts or {}
  if opts.open == nil then
    opts.open = true
  end
  local qfopts = {
    items = buildqflist(target),
    title = 'Hunks',
  }
  async.scheduler()
  if opts.use_location_list then
    local nr = opts.nr or 0
    vim.fn.setloclist(nr, {}, ' ', qfopts)
    if opts.open then
      if config.trouble then
        require('trouble').open('loclist')
      else
        vim.cmd.lopen()
      end
    end
  else
    vim.fn.setqflist({}, ' ', qfopts)
    if opts.open then
      if config.trouble then
        require('trouble').open('quickfix')
      else
        vim.cmd.copen()
      end
    end
  end
end)

C.setqflist = function(args, _)
  local target = tonumber(args[1]) or args[1]
  M.setqflist(target, args)
end

--- Populate the location list with hunks. Automatically opens the
--- location list window.
---
--- Alias for: `setqflist({target}, { use_location_list = true, nr = {nr} }`
---
--- Attributes: ~
---     {async}
---
--- @param nr? integer Window number or the |window-ID|.
---     `0` for the current window (default).
--- @param target integer|string See |gitsigns.setqflist()|.
M.setloclist = function(nr, target)
  M.setqflist(target, {
    nr = nr,
    use_location_list = true,
  })
end

C.setloclist = function(args, _)
  local target = tonumber(args[2]) or args[2]
  M.setloclist(tonumber(args[1]), target)
end

--- Get all the available line specific actions for the current
--- buffer at the cursor position.
---
--- @return table|nil : Dictionary of action name to function which when called
---     performs action.
M.get_actions = function()
  local bufnr = current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end
  local hunk = get_cursor_hunk()

  --- @type string[]
  local actions_l = {}

  if hunk then
    vim.list_extend(actions_l, {
      'stage_hunk',
      'reset_hunk',
      'preview_hunk',
      'select_hunk',
    })
  else
    actions_l[#actions_l + 1] = 'blame_line'
  end

  if not vim.tbl_isempty(bcache.staged_diffs) then
    actions_l[#actions_l + 1] = 'undo_stage_hunk'
  end

  local actions = {} --- @type table<string,function>
  for _, a in ipairs(actions_l) do
    actions[a] = M[a] --[[@as function]]
  end

  return actions
end

for name, f in
  pairs(M --[[@as table<string,function>]])
do
  if vim.startswith(name, 'toggle') then
    C[name] = function(args)
      f(args[1])
    end
  end
end

--- Refresh all buffers.
---
--- Attributes: ~
---     {async}
M.refresh = async.create(function()
  manager.reset_signs()
  require('gitsigns.highlight').setup_highlights()
  require('gitsigns.current_line_blame').setup()
  for k, v in pairs(cache) do
    v:invalidate(true)
    manager.update(k)
  end
end)

--- @param name string
--- @return fun(args: table, params: Gitsigns.CmdParams)
function M._get_cmd_func(name)
  return C[name]
end

--- @param name string
--- @return fun(arglead: string): string[]
function M._get_cmp_func(name)
  return CP[name]
end

return M
