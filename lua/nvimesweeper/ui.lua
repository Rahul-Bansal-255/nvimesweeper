local api, fn, uv = vim.api, vim.fn, vim.loop

local config_mod = require "nvimesweeper.config"
local board_mod = require "nvimesweeper.board"
local game_state = require "nvimesweeper.game_state"

local util = require "nvimesweeper.util"
local error = util.error

local M = {
  uis = {},
}

local ns = api.nvim_create_namespace "nvimesweeper"
local Ui = {}

function Ui:enable_modification(enable)
  api.nvim_buf_set_option(self.buf, "modifiable", enable)
end

local function centering_left_pad(ui, len)
  if not ui.centered then
    return 0
  end
  local pad = (api.nvim_win_get_width(0) - len) / 2
  return math.floor(math.max(0, pad))
end

-- board squares are drawn this many screen columns wide
local CELL_WIDTH = 2

local function pad_cell(char)
  local pad = CELL_WIDTH - fn.strdisplaywidth(char)
  return pad > 0 and (char .. string.rep(" ", pad)) or char
end

function Ui:redraw_status()
  local function time_string(show_ms)
    local nanoseconds = uv.hrtime() - self.game.start_time
    local seconds = math.floor(nanoseconds / 1000000000)
    local minutes = math.floor(seconds / 60)

    local time = string.format("⏰ %02d:%02d", minutes, seconds % 60)
    if show_ms then
      local milliseconds = math.floor(nanoseconds / 1000000)
      time = string.format("%s.%03d", time, milliseconds % 1000)
    end
    return time
  end

  local state = self.game.state
  local hl_col1, hl_col2, hl_group
  local status = { "", "" }
  if state == game_state.GAME_NOT_STARTED then
    status[1] = "🙂 Reveal a square or press F1 for help."
  elseif state == game_state.GAME_STARTED then
    local board = self.game.board
    local flags = string.format("🚩 %d/%d", board.flag_count, board.mine_count)
    status[1] = "🙂 " .. time_string() .. "    " .. flags
    if board.flag_count > board.mine_count then
      hl_col1 = #status[1] - #flags
      hl_col2, hl_group = #status[1], "NvimesweeperTooManyFlags"
    end
  elseif game_state.is_game_over(state) then
    if state == game_state.GAME_WON then
      status[1] = "😎 Congratulations, you win!"
      hl_group = "NvimesweeperWin"
    elseif state == game_state.GAME_LOST then
      status[1] = "💥 KA-BOOM! You explode..."
      hl_group = "NvimesweeperLose"
    end
    hl_col1, hl_col2 = 0, #status[1]
    status[1] = status[1] .. " " .. time_string(true)
    status[2] = "Seed: " .. self.game.seed
  end

  local left_pads = {}
  for i, s in ipairs(status) do
    left_pads[i] = centering_left_pad(self, fn.strdisplaywidth(s))
    status[i] = string.rep(" ", left_pads[i]) .. s
  end

  self:enable_modification(true)
  api.nvim_buf_set_lines(self.buf, 0, 2, false, status)
  self:enable_modification(false)

  if hl_col1 then
    self.status_hl_extmark = api.nvim_buf_set_extmark(
      self.buf,
      ns,
      0,
      hl_col1 + left_pads[1],
      {
        id = self.status_hl_extmark,
        end_col = hl_col2 + left_pads[1],
        hl_group = hl_group,
      }
    )
  elseif self.status_hl_extmark then
    api.nvim_buf_del_extmark(self.buf, ns, self.status_hl_extmark)
    self.status_hl_extmark = nil
  end
end

function Ui:board_square_char(i)
  local board_chars = config_mod.config.board_chars
  local game_over = game_state.is_game_over(self.game.state)
  local state = self.game.board.state[i]
  local mine = self.game.board.mines[i]
  local char = board_chars.unrevealed

  if
    mine
    and (
      state == board_mod.SQUARE_REVEALED
      or (game_over and state ~= board_mod.SQUARE_FLAGGED)
    )
  then
    char = board_chars.mine
  elseif state == board_mod.SQUARE_FLAGGED then
    local flag_wrong = game_over and not mine
    char = flag_wrong and board_chars.flag_wrong or board_chars.flag
  elseif state == board_mod.SQUARE_MAYBE then
    char = board_chars.maybe
  elseif state == board_mod.SQUARE_REVEALED then
    local danger = self.game.board.danger[i]
    char = danger > 0 and tostring(danger) or board_chars.revealed
  end

  return char
end

function Ui:board_square_hl_group(i)
  local game_over = game_state.is_game_over(self.game.state)
  local board = self.game.board
  local state = board.state[i]

  -- unrevealed squares alternate highlights in a checkerboard pattern
  local x, y = (i - 1) % board.width, math.floor((i - 1) / board.width)
  local alt = (x + y) % 2 == 1 and "Alt" or ""
  local hl_group = "NvimesweeperUnrevealed" .. alt

  if game_over and board.mines[i] then
    if state == board_mod.SQUARE_REVEALED then
      hl_group = "NvimesweeperTriggeredMine"
    elseif state == board_mod.SQUARE_FLAGGED then
      hl_group = "NvimesweeperFlag" .. alt
    else
      hl_group = "NvimesweeperMine"
    end
  elseif state == board_mod.SQUARE_FLAGGED then
    hl_group = (game_over and "NvimesweeperFlagWrong" or "NvimesweeperFlag")
      .. alt
  elseif state == board_mod.SQUARE_MAYBE then
    hl_group = "NvimesweeperMaybe" .. alt
  elseif state == board_mod.SQUARE_REVEALED then
    local danger = board.danger[i]
    hl_group = danger > 0 and ("NvimesweeperDanger" .. danger)
      or "NvimesweeperRevealed"
  end

  return hl_group
end

-- squares may have varying byte widths, so affected rows are always redrawn
-- in full; the x range arguments are accepted for compatibility, but unused
function Ui:redraw_board(_, y1, _, y2)
  y1, y2 = y1 or 0, y2 or self.game.board.height - 1

  local board = self.game.board
  local origin = self:board_square_pos(1)

  -- Replacing a full row preserves byte columns, which may point at a
  -- different square when cells change byte width. Remember logical squares
  -- and restore their cursors after rebuilding the extmarks.
  local cursors = {}
  if self.board_extmarks[board.width * board.height] then
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_buf(win) == self.buf then
        local cursor = api.nvim_win_get_cursor(win)
        local x, y = self:win_to_board_pos(cursor[2], cursor[1] - 1)
        local i = board:index(x, y)
        if i and y >= y1 and y <= y2 then
          cursors[#cursors + 1] = { win = win, square = i }
        end
      end
    end
  end

  self:enable_modification(true)
  local cells, offsets = {}, {}
  for y = y1, y2 do
    local row_i = board:index(0, y)
    local lnum = origin[1] + y

    -- build the row, remembering the byte offset of each square
    local offset = 0
    for x = 0, board.width - 1 do
      local cell = pad_cell(self:board_square_char(row_i + x))
      cells[x + 1] = cell
      offsets[x + 1] = offset
      offset = offset + #cell
    end
    offsets[board.width + 1] = offset

    local line = api.nvim_buf_get_lines(self.buf, lnum, lnum + 1, true)[1]
    api.nvim_buf_set_text(
      self.buf,
      lnum,
      origin[2],
      lnum,
      #line,
      { table.concat(cells, "", 1, board.width) }
    )

    -- update extended marks
    for x = 0, board.width - 1 do
      local i = row_i + x
      local mark_x = origin[2] + offsets[x + 1]
      self.board_extmarks[i] = api.nvim_buf_set_extmark(
        self.buf,
        ns,
        lnum,
        mark_x,
        {
          id = self.board_extmarks[i],
          end_col = origin[2] + offsets[x + 2],
          hl_group = self:board_square_hl_group(i),
        }
      )
    end
  end
  self:enable_modification(false)

  for _, cursor in ipairs(cursors) do
    if
      api.nvim_win_is_valid(cursor.win)
      and api.nvim_win_get_buf(cursor.win) == self.buf
    then
      local pos = self:board_square_pos(cursor.square)
      api.nvim_win_set_cursor(cursor.win, { pos[1] + 1, pos[2] })
    end
  end
end

function Ui:full_redraw()
  self:redraw_status()

  -- usually, only the changed area of the board is updated, which requires the
  -- lines to already exist, so create filler lines to fit the entire board
  local board_cols = self.game.board.width * CELL_WIDTH
  local left_pad = centering_left_pad(self, board_cols)
  local line = string.rep(" ", left_pad + board_cols)
  local lines = {}
  for i = 1, self.game.board.height do
    lines[i] = line
  end

  self:enable_modification(true)
  api.nvim_buf_set_lines(self.buf, -1, -1, false, lines)

  -- place an extmark for the board's top-left corner so it knows where to draw
  self.board_extmarks[1] = api.nvim_buf_set_extmark(self.buf, ns, 2, left_pad, {
    id = self.board_extmarks[1],
  })
  self:redraw_board()
end

function Ui:start_status_redraw()
  self.redraw_status_timer:start(
    0,
    1000,
    vim.schedule_wrap(function()
      if api.nvim_buf_is_loaded(self.buf) then
        self:redraw_status()
      end
    end)
  )
end

function Ui:stop_status_redraw()
  self.redraw_status_timer:stop()
end

function Ui:cleanup()
  self:stop_status_redraw()
  M.uis[self.buf] = nil
end

function Ui:board_square_pos(i)
  local pos = api.nvim_buf_get_extmark_by_id(
    self.buf,
    ns,
    self.board_extmarks[i],
    {}
  )
  return pos
end

-- uses current window cursor position if wx is nil
function Ui:win_to_board_pos(wx, wy)
  local origin = self:board_square_pos(1)
  if not wx then
    local cursor_pos = api.nvim_win_get_cursor(0)
    -- nvim_win_get_cursor gives 1-indexed rows
    wx, wy = cursor_pos[2], cursor_pos[1] - 1
  end

  local board = self.game.board
  local y = wy - origin[1]
  if y < 0 or y >= board.height or wx < origin[2] then
    return -1, -1
  end

  -- squares may have varying byte widths; find the one containing this column
  local x = 0
  for bx = board.width - 1, 1, -1 do
    local pos = self:board_square_pos(board:index(bx, y))
    if wx >= pos[2] then
      x = bx
      break
    end
  end
  return x, y
end

-- moves the cursor by the given number of squares, clamped to the board
function Ui:move_cursor(dx, dy)
  local x, y = self:win_to_board_pos()
  local board = self.game.board
  x = math.min(math.max(x + dx, 0), board.width - 1)
  y = math.min(math.max(y + dy, 0), board.height - 1)
  local pos = self:board_square_pos(board:index(x, y))
  api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
end

local function create_window(ui, float_opts)
  local win
  if float_opts then
    win = api.nvim_open_win(ui.buf, true, {
      relative = "editor",
      width = float_opts.width,
      height = float_opts.height,
      row = math.max(
        0,
        math.floor((api.nvim_get_option "lines" - float_opts.height) / 2) - 1
      ),
      col = math.floor((api.nvim_get_option "columns" - float_opts.width) / 2),
      style = "minimal",
      border = "single",
    })
    win = win ~= 0 and win or nil
  else
    local ok, _ = pcall(vim.cmd, "tab sbuffer " .. ui.buf)
    if ok then
      win = api.nvim_get_current_win()
    end
  end

  if not win then
    return false
  end

  if float_opts then
    api.nvim_buf_set_option(ui.buf, "bufhidden", "wipe")

    -- Schedule the deletion. NOTE: if we don't schedule, this can cause issues
    -- when starting a new game in a float if we are already playing a game in a
    -- different float: both floats will be closed.
    --
    -- Backstory: this is inherited from Vim's windowing behaviour; the new
    -- float briefly edits the current buffer before it edits its intended
    -- buffer (similiar to :split, then :buffer <buf>). The current buffer's
    -- WinLeave autocmd (intended for the previous float) will delete the
    -- buffer while the new float is still momentarily editing it, causing both
    -- floats to close! By delaying the deletion, we allow the new float to
    -- switch to its intended buffer first.
    --
    -- Funnily enough, this uncovered a crash in nvim_open_win() when I used
    -- BufLeave instead: https://github.com/neovim/neovim/pull/15549 -- So, you
    -- can say this silly Minesweeper clone helped improve Neovim... :P
    api.nvim_create_autocmd("WinLeave", {
      buffer = ui.buf,
      once = true,
      callback = function()
        vim.schedule(function()
          if api.nvim_buf_is_valid(ui.buf) then
            api.nvim_buf_delete(ui.buf, { force = true })
          end
        end)
      end,
    })
  else
    -- float "minimal" style already sets these
    api.nvim_win_set_option(win, "list", false)
    api.nvim_win_set_option(win, "spell", false)
  end
  ui.centered = float_opts ~= nil

  api.nvim_win_set_option(win, "wrap", false)
  return true
end

local function move_cursor_to_click()
  fn.getchar()
  if api.nvim_get_vvar "mouse_winid" == api.nvim_get_current_win() then
    local lnum = api.nvim_get_vvar "mouse_lnum"
    local vcol = api.nvim_get_vvar "mouse_col"

    -- convert the clicked screen column to a byte column
    local line = api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    local width, byte = 0, 0
    for _, char in ipairs(fn.split(line, "\\zs")) do
      local char_width = fn.strdisplaywidth(char)
      if width + char_width >= vcol then
        break
      end
      width = width + char_width
      byte = byte + #char
    end

    api.nvim_win_set_cursor(0, { lnum, byte })
  end
end

function M.new_ui(game, open_tab)
  local buf = api.nvim_create_buf(open_tab, true)
  if buf == 0 then
    error "failed to create game buffer!"
  end

  local ui = setmetatable({
    buf = buf,
    game = game,
    board_extmarks = {},
    redraw_status_timer = uv.new_timer(),
  }, {
    __index = Ui,
  })

  if
    not create_window(ui, not open_tab and {
      width = math.max(42, game.board.width * CELL_WIDTH),
      height = game.board.height + 2,
    } or nil)
  then
    api.nvim_buf_delete(buf, { force = true })
    error "failed to open game window!"
  end

  api.nvim_buf_set_name(
    buf,
    string.format(
      "[nvimesweeper %dx%d %d mines (%d)]",
      game.board.width,
      game.board.height,
      game.board.mine_count,
      buf
    )
  )

  util.nnoremap(buf, "<F1>", "<Cmd>help nvimesweeper-maps<CR>")

  local game_mod = require "nvimesweeper.game"
  util.nnoremap(buf, "<LeftMouse>", function()
    move_cursor_to_click()
    game_mod.reveal()
  end, "Reveal square using the mouse")
  util.nnoremap(buf, "<RightMouse>", function()
    move_cursor_to_click()
    game_mod.place_marker()
  end, "Cycle square marker using the mouse")

  util.nnoremap(buf, { "<CR>", "x" }, game_mod.reveal, "Reveal square")
  util.nnoremap(buf, "<Space>", game_mod.place_marker, "Cycle square marker")

  util.nnoremap(buf, "!", function()
    game_mod.place_marker(board_mod.SQUARE_FLAGGED)
  end, "Flag square")
  util.nnoremap(buf, "?", function()
    game_mod.place_marker(board_mod.SQUARE_MAYBE)
  end, "Mark square")

  -- squares are wider than one character, so move the cursor square-wise
  local movements = {
    { { "h", "<Left>" }, -1, 0, "Move to the square to the left" },
    { { "l", "<Right>" }, 1, 0, "Move to the square to the right" },
    { { "j", "<Down>" }, 0, 1, "Move to the square below" },
    { { "k", "<Up>" }, 0, -1, "Move to the square above" },
  }
  for _, movement in ipairs(movements) do
    util.nnoremap(buf, movement[1], function()
      ui:move_cursor(movement[2], movement[3])
    end, movement[4])
  end

  api.nvim_create_autocmd({ "BufDelete", "VimLeavePre" }, {
    buffer = buf,
    once = true,
    callback = function()
      M.uis[buf]:cleanup()
    end,
  })

  ui:full_redraw()
  local board_pos = ui:board_square_pos(1)
  board_pos[1] = board_pos[1] + 1 -- nvim_win_set_cursor takes a 1-indexed row
  api.nvim_win_set_cursor(0, board_pos)

  M.uis[buf] = ui
  return ui
end

return M
