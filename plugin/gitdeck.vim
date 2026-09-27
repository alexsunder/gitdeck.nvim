" gitdeck.nvim — команды панели GitDeck
if exists('g:loaded_gitdeck') | finish | endif
let g:loaded_gitdeck = 1

command! GitDeck        lua require('gitdeck').toggle()
command! GitDeckRefresh lua require('gitdeck').refresh()
command! GitDeckClose   lua require('gitdeck').close()
