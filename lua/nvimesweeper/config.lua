local default_config = {
  opts = {
    tab = false,
  },
  prompt_presets = { "easy", "medium", "hard", "insane", "nightmare" },
  presets = {
    easy = {
      width = 9,
      height = 9,
      mines = 10,
    },
    medium = {
      width = 16,
      height = 16,
      mines = 40,
    },
    hard = {
      width = 30,
      height = 16,
      mines = 99,
    },
    insane = {
      width = 40,
      height = 16,
      mines = 192,
    },
    nightmare = {
      width = 60,
      height = 16,
      mines = 384,
    },
  },
  board_chars = {
    unrevealed = " ",
    revealed = " ",
    mine = "💣",
    flag = "🚩",
    flag_wrong = "❌",
    maybe = "❓",
  },
}

local M = {}

local function validate_board_chars(board_chars)
  for name in pairs(default_config.board_chars) do
    local char = board_chars[name]
    if type(char) ~= "string" then
      error('[nvimesweeper] board_chars."' .. name .. '" must be a string')
    elseif vim.fn.strdisplaywidth(char) > 2 then
      error(
        '[nvimesweeper] board_chars."'
          .. name
          .. '" must be at most 2 screen columns wide'
      )
    end
  end
end

function M.apply_config(config)
  local merged = vim.tbl_deep_extend("force", default_config, config)
  validate_board_chars(merged.board_chars)
  M.config = merged
end

return M
