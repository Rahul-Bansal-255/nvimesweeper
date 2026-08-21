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

-- board squares are drawn this many screen columns wide
local CELL_WIDTH = 2
-- lines reserved above the board for the status message
local STATUS_HEIGHT = 2
-- floating windows are never narrower than this, so the status message fits
local MIN_FLOAT_WIDTH = 42

-- the window the game is being played in: the current one if it shows the game
-- buffer, else the last known one, else any other window showing it
function Ui:window()
  local current = api.nvim_get_current_win()
  if api.nvim_win_get_buf(current) == self.buf then
    self.win = current
    return current
  end

  if
    self.win
    and api.nvim_win_is_valid(self.win)
    and api.nvim_win_get_buf(self.win) == self.buf
  then
    return self.win
  end

  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == self.buf then
      self.win = win
      return win
    end
  end
  return nil
end

-- whether every square has an extmark marking where it is drawn
function Ui:board_drawn()
  local board = self.game.board
  return self.board_extmarks[board.width * board.height] ~= nil
end

function Ui:width()
  local win = self:window()
  return win and api.nvim_win_get_width(win)
    or self.game.board.width * CELL_WIDTH
end

-- content is centered within the game window, never against another window
local function centering_left_pad(ui, len)
  return math.max(0, math.floor((ui:width() - len) / 2))
end

local function pad_cell(char)
  local pad = CELL_WIDTH - fn.strdisplaywidth(char)
  return pad > 0 and (char .. string.rep(" ", pad)) or char
end

function Ui:redraw_status()
  -- the clock stops once the game is over, so that later redraws (after a
  -- resize, for example) don't keep advancing the final time
  local function elapsed_time()
    if not self.game.start_time then
      return 0
    end
    return self.final_time or (uv.hrtime() - self.game.start_time)
  end

  local function time_string(show_ms)
    local nanoseconds = elapsed_time()
    local seconds = math.floor(nanoseconds / 1000000000)
    local minutes = math.floor(seconds / 60)

    local time = string.format("⏰ %02d:%02d", minutes, seconds % 60)
    if show_ms then
      local milliseconds = math.floor(nanoseconds / 1000000)
      time = string.format("%s.%03d", time, milliseconds % 1000)
    end
    return time
  end

  local board = self.game.board
  -- the flag count is padded so that the status width, and thus the centering
  -- of every line, stays put as flags are placed
  local function flags_string()
    return string.format(
      "🚩 %" .. #tostring(board.mine_count) .. "d/%d",
      board.flag_count,
      board.mine_count
    )
  end

  local state = self.game.state
  local hl_col1, hl_col2, hl_group
  local hl2_col1, hl2_col2, hl2_group
  local status = { "", "" }
  if game_state.is_game_over(state) then
    self.final_time = elapsed_time()
    if state == game_state.GAME_WON then
      status[1] = "😎 Congratulations, you win!"
      hl_group = "NvimesweeperWin"
    else
      status[1] = "💥 KA-BOOM! You explode..."
      hl_group = "NvimesweeperLose"
    end
    hl_col1, hl_col2 = 0, #status[1]
    status[1] = status[1] .. " " .. time_string(true)
    status[2] = "Seed: " .. self.game.seed
    -- redundant for floats that show the controls in their footer (0.10+)
    if not (self.float and fn.has "nvim-0.10" == 1) then
      status[2] = status[2] .. "    q to close"
    end
    hl2_col1, hl2_col2, hl2_group = 0, #status[2], "NvimesweeperDim"
  else
    local flags = flags_string()
    status[1] = "🙂 " .. time_string() .. "    " .. flags
    if board.flag_count > board.mine_count then
      hl_col1 = #status[1] - #flags
      hl_col2, hl_group = #status[1], "NvimesweeperTooManyFlags"
    end
    if state == game_state.GAME_NOT_STARTED then
      status[2] = "Reveal a square to start    F1 for help"
    end
  end

  local left_pads = {}
  for i, s in ipairs(status) do
    left_pads[i] = centering_left_pad(self, fn.strdisplaywidth(s))
    status[i] = string.rep(" ", left_pads[i]) .. s
  end

  self:enable_modification(true)
  api.nvim_buf_set_lines(self.buf, 0, STATUS_HEIGHT, false, status)
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

  if hl2_col1 then
    self.status_hl_extmark2 = api.nvim_buf_set_extmark(
      self.buf,
      ns,
      1,
      hl2_col1 + left_pads[2],
      {
        id = self.status_hl_extmark2,
        end_col = hl2_col2 + left_pads[2],
        hl_group = hl2_group,
      }
    )
  elseif self.status_hl_extmark2 then
    api.nvim_buf_del_extmark(self.buf, ns, self.status_hl_extmark2)
    self.status_hl_extmark2 = nil
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

  self:update_cursor()
end

function Ui:full_redraw()
  self:redraw_status()

  -- usually, only the changed area of the board is updated, which requires the
  -- lines to already exist, so (re)create filler lines to fit the entire board
  local board_cols = self.game.board.width * CELL_WIDTH
  local left_pad = centering_left_pad(self, board_cols)
  local line = string.rep(" ", left_pad + board_cols)
  local lines = {}
  for i = 1, self.game.board.height do
    lines[i] = line
  end

  self:enable_modification(true)
  api.nvim_buf_set_lines(self.buf, STATUS_HEIGHT, -1, false, lines)

  -- place an extmark for the board's top-left corner so it knows where to draw
  self.board_extmarks[1] = api.nvim_buf_set_extmark(
    self.buf,
    ns,
    STATUS_HEIGHT,
    left_pad,
    { id = self.board_extmarks[1] }
  )
  self.layout_width = self:width()
  self:redraw_board()
end

local function set_window_options(win)
  api.nvim_win_set_option(win, "wrap", false)
  api.nvim_win_set_option(win, "list", false)
  api.nvim_win_set_option(win, "spell", false)
  api.nvim_win_set_option(win, "number", false)
  api.nvim_win_set_option(win, "relativenumber", false)
  api.nvim_win_set_option(win, "cursorline", false)
  api.nvim_win_set_option(win, "signcolumn", "no")
  api.nvim_win_set_option(win, "foldcolumn", "0")
  -- keep the view still when moving along the edges of a clipped board
  api.nvim_win_set_option(win, "scrolloff", 0)
  api.nvim_win_set_option(win, "sidescrolloff", 0)
end

-- redraws everything if the window was resized, keeping the game centered
function Ui:relayout()
  local win = self:window()
  if not win or not api.nvim_buf_is_loaded(self.buf) then
    return
  end

  -- window-local options don't follow the buffer: a window the game buffer is
  -- re-shown in (via :b, say) needs them set again
  set_window_options(win)

  if self.float then
    api.nvim_win_set_config(win, self:float_config())
  end
  if self:width() == self.layout_width then
    return
  end

  local square = self:cursor_square()
  self:full_redraw()
  if square then
    self:set_cursor_square(square)
  end
end

function Ui:start_status_redraw()
  if not self.redraw_status_timer then
    return
  end

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
  if self.redraw_status_timer then
    self.redraw_status_timer:stop()
  end
end

-- releases every resource the game holds; safe to call more than once
function Ui:cleanup()
  self:stop_status_redraw()
  if self.redraw_status_timer then
    if not self.redraw_status_timer:is_closing() then
      self.redraw_status_timer:close()
    end
    self.redraw_status_timer = nil
  end
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
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

-- like win_to_board_pos, but positions outside of the board are clamped to the
-- nearest square instead of being rejected
function Ui:clamp_to_board(wx, wy)
  local origin = self:board_square_pos(1)
  local board = self.game.board
  local y = math.min(math.max(wy - origin[1], 0), board.height - 1)

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

function Ui:cursor_square()
  local win = self:window()
  if not win or not self:board_drawn() then
    return nil
  end

  local cursor = api.nvim_win_get_cursor(win)
  local x, y = self:clamp_to_board(cursor[2], cursor[1] - 1)
  return self.game.board:index(x, y)
end

function Ui:set_cursor_square(i)
  local win = self:window()
  if not win or not self.board_extmarks[i] then
    return
  end

  local pos = self:board_square_pos(i)
  api.nvim_win_set_cursor(win, { pos[1] + 1, pos[2] })
end

-- keeps the cursor on a board square and highlights the square it is on
function Ui:update_cursor()
  local win = self:window()
  if not win or not self:board_drawn() then
    return
  end

  local board = self.game.board
  local cursor = api.nvim_win_get_cursor(win)
  local x, y = self:clamp_to_board(cursor[2], cursor[1] - 1)
  local pos = self:board_square_pos(board:index(x, y))
  if pos[1] ~= cursor[1] - 1 or pos[2] ~= cursor[2] then
    api.nvim_win_set_cursor(win, { pos[1] + 1, pos[2] })
  end

  -- the last square of a row extends to the end of its line
  local end_col
  if x + 1 < board.width then
    end_col = self:board_square_pos(board:index(x + 1, y))[2]
  else
    end_col = #api.nvim_buf_get_lines(self.buf, pos[1], pos[1] + 1, true)[1]
  end

  self.cursor_extmark =
    api.nvim_buf_set_extmark(self.buf, ns, pos[1], pos[2], {
      id = self.cursor_extmark,
      end_col = end_col,
      hl_group = "NvimesweeperCursor",
      -- drawn on top of the square's own highlight
      priority = 4200,
    })
end

-- moves the cursor by the given number of squares, clamped to the board
function Ui:move_cursor(dx, dy)
  local i = self:cursor_square()
  if not i then
    return
  end

  local board = self.game.board
  local x, y = (i - 1) % board.width, math.floor((i - 1) / board.width)
  x = math.min(math.max(x + dx, 0), board.width - 1)
  y = math.min(math.max(y + dy, 0), board.height - 1)
  self:set_cursor_square(board:index(x, y))
end

function Ui:close()
  local win = self:window()
  if not win then
    return
  end

  -- the last window cannot be closed
  if #api.nvim_list_wins() == 1 then
    vim.notify(
      "[nvimesweeper] cannot close the last window!",
      vim.log.levels.WARN
    )
    return
  end
  pcall(api.nvim_win_close, win, true)
end

-- the game is always centered on the screen and never larger than it, so that
-- resizing the editor can never leave part of the board off-screen
function Ui:float_config()
  local board = self.game.board
  local columns, lines =
    api.nvim_get_option "columns", api.nvim_get_option "lines"

  local width = math.max(MIN_FLOAT_WIDTH, board.width * CELL_WIDTH)
  width = math.max(1, math.min(width, columns - 4))
  local height = math.max(1, math.min(board.height + STATUS_HEIGHT, lines - 4))

  local config = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2) - 1),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = "rounded",
  }
  if fn.has "nvim-0.9" == 1 then
    config.title = {
      {
        string.format(
          " nvimesweeper %dx%d, %d mines ",
          board.width,
          board.height,
          board.mine_count
        ),
        "NvimesweeperFloatTitle",
      },
    }
    config.title_pos = "center"
  end
  if fn.has "nvim-0.10" == 1 then
    config.footer = { { " q: close │ F1: help ", "NvimesweeperFloatFooter" } }
    config.footer_pos = "center"
  end
  return config
end

local function create_window(ui, float)
  local win
  if float then
    win = api.nvim_open_win(ui.buf, true, ui:float_config())
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

  if float then
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
      group = ui.augroup,
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
  end

  ui.win = win
  ui.float = float
  set_window_options(win)
  return true
end

-- moves the cursor to the clicked position and returns the clicked board
-- position; returns nothing if the click happened in another window
local function move_cursor_to_click(ui)
  fn.getchar()
  if api.nvim_get_vvar "mouse_winid" ~= api.nvim_get_current_win() then
    return
  end

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

  -- resolve the square before moving the cursor: the CursorMoved autocommand
  -- snaps the cursor onto the nearest board square, and clicks outside of the
  -- board must not act on it
  local x, y = ui:win_to_board_pos(byte, lnum - 1)
  api.nvim_win_set_cursor(0, { lnum, byte })
  return x, y
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
    augroup = api.nvim_create_augroup("nvimesweeper_ui_" .. buf, {}),
  }, {
    __index = Ui,
  })
  M.uis[buf] = ui

  if not create_window(ui, not open_tab) then
    api.nvim_buf_delete(buf, { force = true })
    ui:cleanup()
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
    game_mod.reveal(nil, move_cursor_to_click(ui))
  end, "Reveal square using the mouse")
  util.nnoremap(buf, "<RightMouse>", function()
    game_mod.place_marker(nil, nil, move_cursor_to_click(ui))
  end, "Cycle square marker using the mouse")

  util.nnoremap(buf, { "<CR>", "x" }, game_mod.reveal, "Reveal square")
  util.nnoremap(buf, "<Space>", game_mod.place_marker, "Cycle square marker")

  util.nnoremap(buf, "!", function()
    game_mod.place_marker(board_mod.SQUARE_FLAGGED)
  end, "Flag square")
  util.nnoremap(buf, "?", function()
    game_mod.place_marker(board_mod.SQUARE_MAYBE)
  end, "Mark square")

  util.nnoremap(buf, "q", function()
    ui:close()
  end, "Close the game window")

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
    group = ui.augroup,
    buffer = buf,
    once = true,
    callback = function()
      local buf_ui = M.uis[buf]
      if buf_ui then
        buf_ui:cleanup()
      end
    end,
  })

  -- the cursor always sits on a square, even after motions that don't know
  -- about the board, such as those of the mouse or a search
  api.nvim_create_autocmd("CursorMoved", {
    group = ui.augroup,
    buffer = buf,
    callback = function()
      ui:update_cursor()
    end,
  })

  -- the game is centered, so it must be redrawn whenever its width may change
  api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = ui.augroup,
    buffer = buf,
    callback = function()
      ui:relayout()
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = ui.augroup,
    callback = function()
      ui:relayout()
    end,
  })

  ui:full_redraw()
  ui:set_cursor_square(1)
  return ui
end

return M
