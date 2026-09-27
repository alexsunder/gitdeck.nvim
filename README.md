# gitdeck.nvim

Панель GitDeck для Neovim: все мои git-репозитории и их состояние одним взглядом.
Открывается под деревом NERDTree (если его нет — слева).

```
 GitDeck  14:05
▶git-test         alexsunder   main     ↓2 ✎1
 nolink           alexsunder   main     ? ветка не связана
 proj             some-org     main     ↑1
 Сервис заметок   —            main     ⌂ нет на GitHub
 Enter перейти · r обновить · q закрыть
```

| Значок | Значит |
|---|---|
| `↓N` | на GitHub N новых коммитов — забрать (pull) |
| `↑N` | N моих коммитов не отправлены — отправить (push) |
| `✎N` | N файлов изменены, не закоммичены |
| `✓` | всё синхронно |
| `▶` | текущий репозиторий (где сейчас nvim) |
| `⌂ нет на GitHub` | репозиторий только локальный |
| `? ветка не связана` | GitHub есть, но ветка не связана (`git push -u origin main`) |

Репозитории находятся сами: папки из списка `dirs` и их подпапки первого уровня, где есть `.git`.
Склонировал (`gh repo clone`) или создал (`git init`, `gh repo create`) — появится после обновления.

## Установка (vim-plug)

```vim
Plug 'alexsunder/gitdeck.nvim'
```

## Настройка

```vim
lua << EOF
require("gitdeck").setup({
  dirs = { "~/git-test", "~/Documents/Сервисы", "~/Documents/Projects" },
  interval = 5,          -- минут между автообновлениями
  fetch = true,          -- спрашивать GitHub о новом (git fetch)
  height = 10,           -- высота панели
  open_on_start = true,  -- открывать при запуске nvim
})
EOF
```

## Команды и клавиши

| | |
|---|---|
| `:GitDeck` | открыть / закрыть панель |
| `:GitDeckRefresh` | обновить сейчас |
| `:GitDeckClose` | закрыть панель |
| `Enter` (в панели) | перейти в репозиторий (nvim и дерево) |
| `r` / `q` (в панели) | обновить / закрыть |

С auto-session: добавить `"GitDeckClose"` в `pre_save_cmds`, чтобы панель не попадала в сессию.

Панель обновляется в фоне, даже когда закрыта. Значок текущего репозитория для lualine (по желанию):
`function() return require("gitdeck").status() end`.

Требуется Neovim 0.10+ и git.
