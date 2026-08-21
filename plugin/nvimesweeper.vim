if !has('nvim-0.7')
    echoerr "[nvimesweeper] Neovim version 0.7 or above is required!"
    if has('nvim-0.5')
        echomsg "Note: a 'nvim-0.5' compatibility git branch exists if you " ..
              \ "still want to play, but it is not maintained."
    endif
    finish
endif

if exists('g:loaded_nvimesweeper')
    finish
endif

let s:save_cpo = &cpoptions
set cpoptions&vim

command! -nargs=* -bar Nvimesweeper
            \ lua require("nvimesweeper").play_cmd(<q-args>)

function! s:DefineHighlights() abort
    highlight default link NvimesweeperWin DiffAdd
    highlight default link NvimesweeperLose ErrorMsg
    highlight default link NvimesweeperTooManyFlags WarningMsg

    " unrevealed squares form a green checkerboard ("Alt" is the other colour)
    highlight default NvimesweeperUnrevealed ctermbg=Green
                \ guibg=#aad751
    highlight default NvimesweeperUnrevealedAlt ctermbg=DarkGreen
                \ guibg=#a2d149
    highlight default NvimesweeperMaybe ctermfg=Black ctermbg=Green
                \ guifg=#1a237e guibg=#aad751
    highlight default NvimesweeperMaybeAlt ctermfg=Black ctermbg=DarkGreen
                \ guifg=#1a237e guibg=#a2d149
    highlight default NvimesweeperFlag ctermfg=Red ctermbg=Green
                \ guifg=#d32f2f guibg=#aad751
    highlight default NvimesweeperFlagAlt ctermfg=Red ctermbg=DarkGreen
                \ guifg=#d32f2f guibg=#a2d149
    highlight default NvimesweeperFlagWrong ctermfg=Red ctermbg=Green
                \ guifg=#b71c1c guibg=#aad751
    highlight default NvimesweeperFlagWrongAlt ctermfg=Red ctermbg=DarkGreen
                \ guifg=#b71c1c guibg=#a2d149

    " revealed squares use a sandy background with the classic number colours
    highlight default NvimesweeperRevealed ctermbg=LightGrey
                \ guibg=#e5c29f
    highlight default NvimesweeperTriggeredMine ctermfg=Black ctermbg=Red
                \ guifg=#000000 guibg=#e53935
    highlight default NvimesweeperMine ctermfg=Black ctermbg=LightGrey
                \ guifg=#212121 guibg=#e5c29f
    highlight default NvimesweeperDanger1 ctermfg=DarkBlue ctermbg=LightGrey
                \ cterm=bold guifg=#1976d2 guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger2 ctermfg=DarkGreen ctermbg=LightGrey
                \ cterm=bold guifg=#388e3c guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger3 ctermfg=Red ctermbg=LightGrey
                \ cterm=bold guifg=#d32f2f guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger4 ctermfg=DarkMagenta ctermbg=LightGrey
                \ cterm=bold guifg=#7b1fa2 guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger5 ctermfg=DarkRed ctermbg=LightGrey
                \ cterm=bold guifg=#ff8f00 guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger6 ctermfg=DarkCyan ctermbg=LightGrey
                \ cterm=bold guifg=#00897b guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger7 ctermfg=Black ctermbg=LightGrey
                \ cterm=bold guifg=#5d4037 guibg=#e5c29f gui=bold
    highlight default NvimesweeperDanger8 ctermfg=DarkGrey ctermbg=LightGrey
                \ cterm=bold guifg=#616161 guibg=#e5c29f gui=bold
endfunction

augroup nvimesweeper_define_highlights
    autocmd!
    " color scheme has probably cleared our default highlights; reload them
    autocmd ColorScheme * call s:DefineHighlights()
augroup END

call s:DefineHighlights()

let &cpoptions = s:save_cpo
unlet s:save_cpo

let g:loaded_nvimesweeper = 1
