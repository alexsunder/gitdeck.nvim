-- gitdeck.nvim — панель GitDeck: все мои git-репозитории и их состояние
local M = {}

M.config = {
  dirs = { "~/git-test", "~/Documents/Сервисы", "~/Documents/Projects" }, -- где искать
  interval = 5,          -- минут между автообновлениями
  fetch = true,          -- спрашивать GitHub о новом (git fetch)
  retry = 30,           -- секунд до повторной проверки, если GitHub не ответил
  max_height = 15,       -- наибольшая высота панели (подстраивается под число репозиториев)
  open_on_start = false, -- открывать панель при запуске nvim
}

local ns = vim.api.nvim_create_namespace("gitdeck")
local ensure_init -- объявлена ниже
local st = { retry = {}, buf = nil, win = nil, rows = {}, paths = {}, updated = nil, timer = nil, busy = false, inited = false }

-- ---------- поиск репозиториев ----------
local function expand(p)
  return (vim.fn.fnamemodify(vim.fn.expand(p), ":p"):gsub("/$", ""))
end

local function is_repo(p)
  return vim.fn.isdirectory(p .. "/.git") == 1 or vim.fn.filereadable(p .. "/.git") == 1
end

-- ---------- сохранённые настройки (окно настроек, клавиша s) ----------
-- branches: путь → отслеживаемая ветка (нет записи — текущая ветка)
-- added: репозитории, добавленные вручную; removed: убранные из списка
-- interval: минут между проверками (нет — берётся из setup)
local saved = { branches = {}, added = {}, removed = {}, interval = nil }
local function saved_file() return vim.fn.stdpath("data") .. "/gitdeck.json" end

local function load_saved()
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(saved_file()), "\n"))
  end)
  if ok and type(data) == "table" then
    saved.branches = type(data.branches) == "table" and data.branches or {}
    saved.added = type(data.added) == "table" and data.added or {}
    saved.removed = type(data.removed) == "table" and data.removed or {}
    saved.interval = type(data.interval) == "number" and data.interval or nil
  end
end

local function write_saved()
  vim.fn.mkdir(vim.fn.stdpath("data"), "p")
  -- пустые таблицы — как объекты {}, а не массивы []
  local out = {
    branches = next(saved.branches) and saved.branches or vim.empty_dict(),
    added = saved.added,
    interval = saved.interval,
    removed = next(saved.removed) and saved.removed or vim.empty_dict(),
  }
  vim.fn.writefile({ vim.json.encode(out) }, saved_file())
end

-- сама папка или её подпапки первого уровня, где есть .git,
-- плюс добавленные вручную, минус убранные
function M.find()
  local list, seen = {}, {}
  for _, d in ipairs(M.config.dirs) do
    local dir = expand(d)
    if vim.fn.isdirectory(dir) == 1 then
      local cands = { dir }
      for name, t in vim.fs.dir(dir) do
        if (t == "directory" or t == "link") and name:sub(1, 1) ~= "." then
          table.insert(cands, dir .. "/" .. name)
        end
      end
      for _, p in ipairs(cands) do
        if is_repo(p) and not seen[p] and not saved.removed[p] then
          seen[p] = true
          table.insert(list, p)
        end
      end
    end
  end
  for _, p in ipairs(saved.added) do
    if is_repo(p) and not seen[p] then
      seen[p] = true
      table.insert(list, p)
    end
  end
  table.sort(list, function(a, b)
    return vim.fs.basename(a):lower() < vim.fs.basename(b):lower()
  end)
  return list
end

-- ---------- состояние одного репозитория ----------
local SCRIPT = [[
%s
r=$(git remote 2>/dev/null | head -n1)
[ -n "$r" ] && echo "url=$(git remote get-url "$r" 2>/dev/null)"
cur=$(git branch --show-current 2>/dev/null)
echo "branch=$cur"
b="$GITDECK_BRANCH"
if [ -z "$b" ] || [ "$b" = "$cur" ]; then
  # отслеживаем открытую ветку: сравнить с её парой на GitHub
  ab=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
elif git show-ref --verify --quiet "refs/heads/$b"; then
  # другая ветка, есть на компьютере: сравнить её с её парой на GitHub
  up=$(git rev-parse --abbrev-ref "$b@{upstream}" 2>/dev/null) || up="$r/$b"
  ab=$(git rev-list --left-right --count "refs/heads/$b...$up" 2>/dev/null)
else
  # ветки на компьютере нет: сколько её коммитов на GitHub нет ни в одной моей ветке
  n=$(git rev-list --count "$r/$b" --not --branches 2>/dev/null) && ab="0 $n"
fi
echo "ab=$ab"
echo "dirty=$(git status --porcelain 2>/dev/null | wc -l)"
echo "ok=1"
]]

local function parse(out)
  local s = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^(%w+)=(.*)$")
    if k then s[k] = vim.trim(v) end
  end
  if s.ok ~= "1" then return { failed = true } end
  local r = { branch = s.branch ~= "" and s.branch or "?", dirty = tonumber(s.dirty) or 0 }
  r.url = s.url and s.url ~= "" and s.url or nil
  if r.url then
    r.owner = r.url:match("[:/]([^/:]+)/[^/]+$") or "?"
  end
  local ahead, behind = (s.ab or ""):match("(%d+)%s+(%d+)")
  r.ahead, r.behind = tonumber(ahead), tonumber(behind)
  return r
end

local function check(path, cb)
  -- fetch не дольше ~15 с при плохой сети, чтобы не держать проверку
  local fetch = M.config.fetch
    and "git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet >/dev/null 2>&1"
    or ""
  vim.system({ "sh", "-c", SCRIPT:format(fetch) },
    { cwd = path, text = true, timeout = 30000,
      env = { GIT_TERMINAL_PROMPT = "0", GITDECK_BRANCH = saved.branches[path] or "" } },
    function(res) cb(parse(res.stdout)) end)
end

-- ---------- отрисовка ----------
-- текущий репозиторий = папка nvim внутри него
local function is_current(path)
  local cwd = vim.fn.getcwd()
  return cwd == path or cwd:sub(1, #path + 1) == path .. "/"
end

local function fit(s, w)
  if vim.fn.strdisplaywidth(s) > w then
    s = vim.fn.strcharpart(s, 0, w - 1) .. "…"
  end
  return s .. string.rep(" ", w - vim.fn.strdisplaywidth(s))
end

-- сегменты статуса: { текст, группа подсветки }
local function status_parts(r)
  if not r then return { { "…", "Comment" } } end
  if r.failed then return { { "…", "Comment" } } end
  if not r.url then return { { "⌂", "DiagnosticWarn" } } end
  if not r.ahead then return { { "? не связан", "DiagnosticWarn" } } end
  local p = {}
  if r.behind > 0 then table.insert(p, { "↓" .. r.behind, "DiagnosticInfo" }) end
  if r.ahead > 0 then table.insert(p, { "↑" .. r.ahead, "DiagnosticWarn" }) end
  if r.dirty > 0 then table.insert(p, { "✎" .. r.dirty, "DiagnosticHint" }) end
  if #p == 0 then p = { { "✓", "DiagnosticOk" } } end
  return p
end

local function render()
  if not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
  local lines, hls = {}, {}
  local function add(parts)
    local text, col = "", 0
    for _, seg in ipairs(parts) do
      if seg[2] then table.insert(hls, { #lines, col, col + #seg[1], seg[2] }) end
      text = text .. seg[1]
      col = col + #seg[1]
    end
    table.insert(lines, text)
  end
  add({ { " GitDeck", "Keyword" }, { st.updated and ("  " .. st.updated) or "  …", "Comment" } })
  st.paths = {}
  for _, path in ipairs(st.list or {}) do
    local r = st.rows[path]
    local here = is_current(path)
    local width = (M.is_open() and vim.api.nvim_win_get_width(st.win)) or 40
    local status, stw = {}, 0
    for i, seg in ipairs(status_parts(r)) do
      if i > 1 then table.insert(status, { " " }); stw = stw + 1 end
      table.insert(status, seg)
      stw = stw + vim.fn.strdisplaywidth(seg[1])
    end
    -- имя и отслеживаемая ветка в скобках: «hackathon-lab (main)»
    local namew = math.max(8, math.min(34, width - 2 - math.max(stw, 6) - 1))
    local br = M.tracked(path)
    local brtxt = br and (" (" .. fit(br, math.min(10, vim.fn.strdisplaywidth(br))) .. ")") or ""
    local brw = vim.fn.strdisplaywidth(brtxt)
    local name = vim.fs.basename(path)
    local nw = math.max(1, math.min(vim.fn.strdisplaywidth(name), namew - brw))
    local pad = math.max(0, namew - nw - brw)
    local parts = {
      { here and "▶" or " ", "Title" },
      { fit(name, nw), here and "Title" or "Directory" },
      { brtxt, "Comment" },
      { string.rep(" ", pad) .. " " },
    }
    vim.list_extend(parts, status)
    add(parts)
    st.paths[#lines] = path
  end
  if #(st.list or {}) == 0 then add({ { " (репозиториев не найдено)", "Comment" } }) end
  add({ { " Enter перейти · r обновить", "Comment" } })
  add({ { " s настройки · q скрыть", "Comment" } })
  add({ { "" } })

  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(st.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  M.fix_height()
end

-- высота панели = число строк (не больше max_height), без пустых хвостов
function M.fix_height()
  if not M.is_open() or not (st.buf and vim.api.nvim_buf_is_valid(st.buf)) then return end
  -- менять высоту, только если над панелью есть окно (дерево).
  -- Если панель одна в колонке, лишнее место ушло бы в командную строку.
  local has_above = vim.api.nvim_win_call(st.win, function()
    return vim.fn.winnr("k") ~= vim.fn.winnr()
  end)
  if not has_above then return end
  local want = math.min(vim.api.nvim_buf_line_count(st.buf), M.config.max_height)
  if vim.api.nvim_win_get_height(st.win) ~= want then
    pcall(vim.api.nvim_win_set_height, st.win, want)
  end
end

-- ---------- обновление ----------
-- не ответил → проверять этот репозиторий снова каждые retry секунд,
-- пока не придёт верный статус
local function schedule_retry(path)
  if st.retry[path] then return end
  st.retry[path] = true
  vim.defer_fn(function()
    st.retry[path] = nil
    check(path, function(r)
      vim.schedule(function()
        st.rows[path] = r
        render()
        if r.failed then schedule_retry(path) end
      end)
    end)
  end, M.config.retry * 1000)
end

function M.refresh()
  if st.busy then return end
  st.busy = true
  st.list = M.find()
  render()
  local left = #st.list
  if left == 0 then
    st.busy = false
    st.updated = os.date("%H:%M")
    return render()
  end
  for _, path in ipairs(st.list) do
    check(path, function(r)
      vim.schedule(function()
        st.rows[path] = r
        if r.failed then schedule_retry(path) end
        left = left - 1
        if left == 0 then
          st.busy = false
          st.updated = os.date("%H:%M")
        end
        render()
      end)
    end)
  end
end

-- ---------- окно ----------
local function nerdtree_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "nerdtree" then return w end
  end
end

local function ensure_buf()
  if st.buf and vim.api.nvim_buf_is_valid(st.buf) then return end
  st.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(st.buf, "GitDeck")
  vim.bo[st.buf].filetype = "gitdeck"
  vim.bo[st.buf].bufhidden = "hide"
  local o = { buffer = st.buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", M.open_repo, vim.tbl_extend("force", o, { desc = "Перейти в репозиторий" }))
  vim.keymap.set("n", "r", M.refresh, vim.tbl_extend("force", o, { desc = "Обновить" }))
  vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", o, { desc = "Закрыть панель" }))
  vim.keymap.set("n", "s", function()
    M.settings(st.paths[vim.api.nvim_win_get_cursor(0)[1]])
  end, vim.tbl_extend("force", o, { desc = "Настройки" }))
end

function M.is_open()
  return st.win and vim.api.nvim_win_is_valid(st.win)
end

function M.open()
  ensure_init()
  if M.is_open() then return end
  ensure_buf()
  local back = vim.api.nvim_get_current_win()
  local tree = nerdtree_win()
  if tree then
    vim.api.nvim_set_current_win(tree)
    vim.cmd("belowright 5split")
    st.win = vim.api.nvim_get_current_win()
  else
    vim.cmd("topleft 45vsplit")
    st.win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(st.win, st.buf)
  local wo = vim.wo[st.win]
  wo.number, wo.relativenumber, wo.wrap = false, false, false
  wo.signcolumn, wo.cursorline, wo.winfixheight = "no", true, true
  -- подсвечивать всю строку под курсором (в init.vim может стоять cursorlineopt=number)
  wo.cursorlineopt = "line"
  if vim.api.nvim_win_is_valid(back) then vim.api.nvim_set_current_win(back) end
  M.refresh()
end

-- фоновое обновление: идёт всегда, даже когда панель закрыта
-- минут между проверками: из окна настроек, иначе из setup
local function interval()
  return saved.interval or M.config.interval
end

-- (пере)запустить таймер с текущим интервалом
local function start_timer()
  if st.timer then
    st.timer:stop()
    st.timer:close()
  end
  st.timer = (vim.uv or vim.loop).new_timer()
  local ms = interval() * 60 * 1000
  st.timer:start(ms, ms, vim.schedule_wrap(M.refresh))
end

function M.close()
  if M.is_open() then
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.api.nvim_win_close(st.win, true) end
  end
  st.win = nil
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

function M.open_repo()
  local path = st.paths[vim.api.nvim_win_get_cursor(0)[1]]
  if not path then return end
  vim.cmd.cd(vim.fn.fnameescape(path))
  if vim.fn.exists(":NERDTreeCWD") == 2 then
    vim.cmd("NERDTreeCWD")
    vim.cmd("wincmd p")
  end
  vim.notify("Репозиторий: " .. path)
end

-- ---------- окно настроек (s в панели) ----------
-- отслеживаемая ветка: выбранная в настройках, иначе открытая сейчас
function M.tracked(path)
  if saved.branches[path] then return saved.branches[path] end
  local r = st.rows[path]
  return r and r.branch and r.branch ~= "?" and r.branch or nil
end

-- проверить один репозиторий заново (после смены ветки)
local function recheck(path)
  st.rows[path] = nil
  render()
  check(path, function(r)
    vim.schedule(function()
      st.rows[path] = r
      if r.failed then schedule_retry(path) end
      render()
    end)
  end)
end

-- ветки репозитория: на компьютере и на GitHub (без повторов)
local function branches(path)
  local res = vim.system({ "git", "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes" },
    { cwd = path, text = true }):wait()
  local list, seen = {}, {}
  for ref in (res.stdout or ""):gmatch("[^\n]+") do
    local name = ref:match("^refs/heads/(.+)$") or ref:match("^refs/remotes/[^/]+/(.+)$")
    if name and name ~= "HEAD" and not seen[name] then
      seen[name] = true
      table.insert(list, name)
    end
  end
  table.sort(list)
  return list
end

local function current_branch(path)
  local res = vim.system({ "git", "branch", "--show-current" }, { cwd = path, text = true }):wait()
  local b = vim.trim(res.stdout or "")
  return b ~= "" and b or nil
end

-- Окно настроек. Строка страницы: { текст, подсветка, действие, куски подсветки }.
-- действие = { act = функция по Enter/клику, zones = { {начало, конец, функция}, … } }
-- (начало/конец — байты в строке: клик или Enter на этом месте вызывает функцию зоны).
-- Поля ввода — маленькие окна поверх строки окна настроек: ввод прямо в окне,
-- без командной строки.
local set = {
  buf = nil, win = nil, page = "repos", repo = nil, dir = nil,
  items = {}, fields = {}, msg = nil,
  val = { path = nil, interval = nil },
}
local page_repos, page_repo, page_browse -- объявлены ниже

vim.api.nvim_set_hl(0, "GitDeckField", { default = true, link = "Visual" })

local function ours(win)
  if win == set.win then return true end
  for _, f in pairs(set.fields) do
    if f.win == win then return true end
  end
  return false
end

local function close_fields()
  for _, f in pairs(set.fields) do
    if f.win and vim.api.nvim_win_is_valid(f.win) then vim.api.nvim_win_close(f.win, true) end
  end
  set.fields = {}
end

local function set_close()
  close_fields()
  if set.win and vim.api.nvim_win_is_valid(set.win) then vim.api.nvim_win_close(set.win, true) end
  set.win = nil
  set.msg = nil
end

-- ушли из окна настроек (и его полей) в другое окно → закрыть всё
local function leave_check()
  vim.schedule(function()
    if set.win and not ours(vim.api.nvim_get_current_win()) then set_close() end
  end)
end

local function focus_main()
  if set.win and vim.api.nvim_win_is_valid(set.win) then vim.api.nvim_set_current_win(set.win) end
end

-- выполнить действие строки под курсором (или зоны под курсором)
local function activate()
  if not (set.win and vim.api.nvim_win_is_valid(set.win)) then return end
  local pos = vim.api.nvim_win_get_cursor(set.win)
  local item = set.items[pos[1]]
  if not item then return end
  for _, z in ipairs(item.zones or {}) do
    if pos[2] >= z[1] and pos[2] < z[2] then return z[3]() end
  end
  if item.act then item.act() end
end

-- поле ввода поверх строки row (1-based) с экранной колонки col
-- opts: { name, value, width, on_submit(text), revert_on_esc, complete_path }
local function make_field(row, col, opts)
  local f = { name = opts.name }
  f.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[f.buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { opts.value or "" })
  f.win = vim.api.nvim_open_win(f.buf, false, {
    relative = "win", win = set.win, row = row - 1, col = col,
    width = opts.width, height = 1, style = "minimal", zindex = 60, focusable = true,
  })
  vim.wo[f.win].winhighlight = "Normal:GitDeckField"
  vim.wo[f.win].wrap = false
  local function text() return vim.api.nvim_buf_get_lines(f.buf, 0, 1, false)[1] or "" end
  local o = { buffer = f.buf, silent = true }
  local function submit()
    vim.cmd("stopinsert")
    f.done = true
    local t = text()
    vim.schedule(function()
      focus_main()
      opts.on_submit(t)
    end)
  end
  local function cancel()
    vim.cmd("stopinsert")
    f.done = true
    if opts.revert_on_esc then
      set.val[opts.name] = nil
    else
      set.val[opts.name] = text()
    end
    vim.schedule(function()
      focus_main()
      page_repos()
    end)
  end
  vim.keymap.set("n", "<CR>", submit, o)
  -- в режиме ввода: открыт список дополнения — Enter выбирает вариант, иначе сохраняет
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then return "<C-y>" end
    vim.schedule(submit)
    return ""
  end, { buffer = f.buf, expr = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", cancel, o)
  if opts.complete_path then
    -- Tab — дополнить путь (список папок/файлов), ещё Tab — следующий вариант
    vim.keymap.set("i", "<Tab>", function()
      return vim.fn.pumvisible() == 1 and "<C-n>" or "<C-x><C-f>"
    end, { buffer = f.buf, expr = true })
  end
  -- попали в поле (Enter на строке или клик) → сразу режим ввода, курсор в конец
  vim.api.nvim_create_autocmd("WinEnter", { buffer = f.buf, callback = function()
    vim.schedule(function() vim.cmd("startinsert!") end)
  end })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = f.buf, callback = function()
    -- ушёл из поля пути мышью, не нажав Enter, — запомнить набранное
    if opts.keep_on_leave and not f.done then set.val[opts.name] = text() end
    f.done = false
    leave_check()
  end })
  set.fields[opts.name] = f
  return f
end

local function focus_field(name)
  local f = set.fields[name]
  if f and vim.api.nvim_win_is_valid(f.win) then vim.api.nvim_set_current_win(f.win) end
end

-- нарисовать страницу; fields = { {row, col, opts}, … }
local function set_draw(title, rows, cursor, fields)
  local lines, hls, width = {}, {}, 44
  set.items = {}
  for i, row in ipairs(rows) do
    local text = row[1]
    lines[i] = text
    width = math.max(width, vim.fn.strdisplaywidth(text) + 2)
    if row[2] and #text > 0 then table.insert(hls, { i - 1, 0, #text, row[2] }) end
    for _, seg in ipairs(row[4] or {}) do table.insert(hls, { i - 1, seg[1], seg[2], seg[3] }) end
    if row[3] then set.items[i] = row[3] end
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  if not (set.buf and vim.api.nvim_buf_is_valid(set.buf)) then
    set.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[set.buf].bufhidden = "wipe"
    local o = { buffer = set.buf, silent = true, nowait = true }
    vim.keymap.set("n", "<CR>", activate, o)
    -- клик мышью: курсор уже встал на место клика → то же, что Enter
    vim.keymap.set("n", "<LeftRelease>", function() vim.schedule(activate) end, o)
    vim.keymap.set("n", "d", function()
      local item = set.items[vim.api.nvim_win_get_cursor(0)[1]]
      if item and item.remove then item.remove() end
    end, o)
    vim.keymap.set("n", "<Esc>", function()
      if set.page == "browse" then return page_repos(nil, "add") end
      if set.page == "repo" then return page_repos(set.repo) end
      set_close()
    end, o)
    vim.keymap.set("n", "q", set_close, o)
    vim.api.nvim_create_autocmd("WinLeave", { buffer = set.buf, callback = leave_check })
  end
  close_fields()
  vim.bo[set.buf].modifiable = true
  vim.api.nvim_buf_set_lines(set.buf, 0, -1, false, lines)
  vim.bo[set.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(set.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(set.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  local cfg = {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    title = " " .. title .. " ", title_pos = "center",
  }
  if set.win and vim.api.nvim_win_is_valid(set.win) then
    vim.api.nvim_win_set_config(set.win, cfg)
    vim.api.nvim_set_current_win(set.win)
  else
    set.win = vim.api.nvim_open_win(set.buf, true, cfg)
    vim.wo[set.win].cursorline = true
    vim.wo[set.win].cursorlineopt = "line"
  end
  for _, fd in ipairs(fields or {}) do make_field(fd[1], fd[2], fd[3]) end
  -- курсор на заданную строку или на первую строку с действием
  local first = cursor
  if not first then
    for i = 1, #lines do if set.items[i] then first = i; break end end
  end
  pcall(vim.api.nvim_win_set_cursor, set.win, { first or 1, 0 })
end

-- ---------- действия ----------
local function remove_repo(path)
  saved.branches[path] = nil
  for i, p in ipairs(saved.added) do
    if p == path then table.remove(saved.added, i); break end
  end
  saved.removed[path] = true
  write_saved()
  st.rows[path] = nil
  st.list = M.find()
  render()
  set.msg = { "Убран: " .. vim.fs.basename(path) .. " (вернуть — «Добавить»)", "DiagnosticWarn" }
  page_repos()
end

local function add_repo(input)
  input = vim.trim(input or "")
  set.val.path = input
  if input == "" then
    set.msg = { "Укажи папку репозитория", "DiagnosticWarn" }
    return page_repos(nil, "add")
  end
  local p = expand(input)
  if not is_repo(p) then
    set.msg = { "В этой папке нет git-репозитория", "DiagnosticError" }
    return page_repos(nil, "add")
  end
  saved.removed[p] = nil
  if not vim.tbl_contains(saved.added, p) then table.insert(saved.added, p) end
  write_saved()
  st.list = M.find()
  recheck(p)
  set.val.path = nil
  set.msg = { "Добавлен: " .. vim.fs.basename(p), "DiagnosticOk" }
  page_repos(p)
end

local function save_interval(input)
  input = vim.trim(input or "")
  local n = tonumber(input)
  if not (n and n >= 1 and n == math.floor(n)) then
    set.val.interval = input
    set.msg = { "Нужно целое число минут, от 1", "DiagnosticError" }
    return page_repos(nil, "interval")
  end
  saved.interval = n
  write_saved()
  start_timer()
  set.val.interval = nil
  set.msg = { "Проверка каждые " .. n .. " мин", "DiagnosticOk" }
  page_repos(nil, "interval")
end

-- ---------- страницы ----------
-- список репозиториев, добавление, интервал, значки.
-- cursor_path — репозиторий, на который поставить курсор; at — "add" или "interval"
page_repos = function(cursor_path, at)
  set.page, set.repo = "repos", nil
  local rows, cursor, fields = {}, nil, {}
  local list = st.list or M.find()
  local namew = 11
  for _, p in ipairs(list) do namew = math.max(namew, vim.fn.strdisplaywidth(vim.fs.basename(p))) end

  -- строки репозиториев: имя, ветка, справа кнопка ✕ (убрать из отслеживаемых)
  local texts, widest = {}, 0
  for i, p in ipairs(list) do
    local br = M.tracked(p) or "…"
    local cur = st.rows[p] and st.rows[p].branch
    local text = "  " .. fit(vim.fs.basename(p), namew) .. "  " .. br
    local segs = {}
    if br == cur then
      table.insert(segs, { #text, #text + #" (текущая)", "Comment" })
      text = text .. " (текущая)"
    end
    texts[i] = { text, segs }
    widest = math.max(widest, vim.fn.strdisplaywidth(text))
  end
  table.insert(rows, { "  " .. fit("Репозиторий", namew) .. "  отслеживаемая ветка", "Comment" })
  for i, p in ipairs(list) do
    local text, segs = texts[i][1], texts[i][2]
    text = text .. string.rep(" ", widest - vim.fn.strdisplaywidth(text) + 3)
    local xs = #text
    text = text .. "✕"
    table.insert(segs, { xs, #text, "DiagnosticError" })
    local function rm() remove_repo(p) end
    table.insert(rows, { text, nil, {
      act = function() page_repo(p) end,
      remove = rm,
      zones = { { xs - 1, #text, rm } },
    }, segs })
    if p == cursor_path then cursor = #rows end
  end
  if #list == 0 then table.insert(rows, { "  (пока нет репозиториев)", "Comment" }) end

  -- добавить репозиторий: поле ввода, 📁 — выбрать папку мышью, [ Добавить ]
  table.insert(rows, { "" })
  table.insert(rows, { " Добавить репозиторий", "Title" })
  local fw = math.max(30, widest - 10)
  local pre = "  "
  local text = pre .. string.rep(" ", fw) .. "  "
  local fs, fe = #pre, #pre + fw
  local bs = #text
  text = text .. "📁"
  local be = #text
  text = text .. "  "
  local as = #text
  text = text .. "[ Добавить ]"
  local ae = #text
  local path_row = #rows + 1
  table.insert(rows, { text, nil, {
    act = function() focus_field("path") end,
    zones = {
      { fs, fe, function() focus_field("path") end },
      { bs, be, function() page_browse() end },
      { as, ae, function()
        local f = set.fields.path
        add_repo(f and vim.api.nvim_buf_get_lines(f.buf, 0, 1, false)[1] or set.val.path)
      end },
    },
  }, { { as, ae, "DiagnosticOk" } } })
  table.insert(fields, { path_row, vim.fn.strdisplaywidth(pre), {
    name = "path", width = fw, complete_path = true, keep_on_leave = true,
    value = set.val.path or (expand("~/Documents/Projects") .. "/"),
    on_submit = add_repo,
  } })
  if at == "add" then cursor = path_row end

  -- интервал проверки
  table.insert(rows, { "" })
  local ipre = "  ⏱ Проверять каждые "
  local iw = 5
  local itext = ipre .. string.rep(" ", iw) .. " мин"
  local int_row = #rows + 1
  table.insert(rows, { itext, nil, {
    act = function() focus_field("interval") end,
  } })
  table.insert(fields, { int_row, vim.fn.strdisplaywidth(ipre), {
    name = "interval", width = iw, revert_on_esc = true,
    value = set.val.interval or tostring(interval()),
    on_submit = save_interval,
  } })
  if at == "interval" then cursor = int_row end

  -- сообщение о последнем действии
  if set.msg then
    table.insert(rows, { "" })
    table.insert(rows, { "  " .. set.msg[1], set.msg[2] })
  end

  table.insert(rows, { "" })
  table.insert(rows, { " Enter или клик — выбрать · ✕ или d — убрать · q закрыть", "Comment" })
  table.insert(rows, { " В поле: Enter — сохранить, Esc — выйти, Tab — дополнить путь", "Comment" })
  table.insert(rows, { "" })
  table.insert(rows, { " Значки", "Title" })
  for _, l in ipairs({
    { "↓N", "DiagnosticInfo", "на GitHub N новых коммитов — забрать (pull)" },
    { "↑N", "DiagnosticWarn", "N коммитов не отправлены — отправить (push)" },
    { "✎N", "DiagnosticHint", "N файлов изменены, не закоммичены" },
    { "✓ ", "DiagnosticOk", "всё синхронно" },
    { "⌂ ", "DiagnosticWarn", "только на компьютере, на GitHub нет" },
    { "? ", "DiagnosticWarn", "ветка не связана с GitHub" },
    { "… ", "Comment", "идёт проверка" },
    { "▶ ", "Title", "текущий репозиторий" },
    { "()", "Comment", "отслеживаемая ветка" },
  }) do
    table.insert(rows, { "  " .. l[1] .. "  " .. l[3], nil, nil, { { 2, 2 + #l[1], l[2] } } })
  end
  set_draw("GitDeck · настройки", rows, cursor, fields)
end

-- ветки репозитория: ● — отслеживаемая (пока не выбрана — открытая сейчас),
-- (текущая) — открытая в репозитории сейчас
page_repo = function(path)
  set.page, set.repo = "repo", path
  set.msg = nil
  local cur = current_branch(path)
  local chosen = saved.branches[path] or cur
  local rows, cursor = {}, nil
  table.insert(rows, { " Какую ветку отслеживать:", "Comment" })
  for _, b in ipairs(branches(path)) do
    local text = (chosen == b and "  ● " or "  ○ ") .. b
    local segs = nil
    if b == cur then
      segs = { { #text, #text + #" (текущая)", "Comment" } }
      text = text .. " (текущая)"
    end
    table.insert(rows, { text, nil, { act = function()
      saved.branches[path] = b
      write_saved()
      recheck(path)
      page_repos(path)
    end }, segs })
    if chosen == b then cursor = #rows end
  end
  table.insert(rows, { "" })
  table.insert(rows, { " Enter или клик — выбрать · Esc назад · q закрыть", "Comment" })
  set_draw(vim.fs.basename(path), rows, cursor)
end

-- выбор папки мышью: клик по папке — зайти, «..» — выше, [ Выбрать эту папку ]
page_browse = function(dir)
  if not dir then
    local v = set.val.path
    local f = set.fields.path
    if f and vim.api.nvim_buf_is_valid(f.buf) then v = vim.api.nvim_buf_get_lines(f.buf, 0, 1, false)[1] end
    dir = v and v ~= "" and expand(v) or expand("~/Documents/Projects")
    if vim.fn.isdirectory(dir) ~= 1 then dir = expand("~") end
    set.val.path = v
  end
  set.page, set.dir = "browse", dir
  local rows = {}
  local home = expand("~")
  local shown = dir:sub(1, #home) == home and ("~" .. dir:sub(#home + 1)) or dir
  table.insert(rows, { " " .. (shown == "" and "/" or shown), "Title" })
  if is_repo(dir) then table.insert(rows, { "  это git-репозиторий — можно выбрать", "DiagnosticOk" }) end
  table.insert(rows, { "" })
  local parent = vim.fs.dirname(dir)
  if parent ~= dir then
    table.insert(rows, { "  ⬆ ..", "Directory", { act = function() page_browse(parent) end } })
  end
  local names = {}
  for name, t in vim.fs.dir(dir) do
    if (t == "directory" or t == "link") and name:sub(1, 1) ~= "."
      and vim.fn.isdirectory(vim.fs.joinpath(dir, name)) == 1 then
      table.insert(names, name)
    end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  for _, name in ipairs(names) do
    local p = vim.fs.joinpath(dir, name)
    local text = "  📁 " .. name
    local segs = nil
    if is_repo(p) then
      segs = { { #text, #text + #"  git", "DiagnosticOk" } }
      text = text .. "  git"
    end
    table.insert(rows, { text, nil, { act = function() page_browse(p) end }, segs })
  end
  if #names == 0 then table.insert(rows, { "  (нет папок)", "Comment" }) end
  table.insert(rows, { "" })
  local text = "  [ Выбрать эту папку ]"
  local ce = #text
  text = text .. "   [ Отмена ]"
  local function choose()
    set.val.path = dir
    page_repos(nil, "add")
  end
  local function cancel() page_repos(nil, "add") end
  table.insert(rows, { text, nil, {
    act = choose,
    zones = { { 2, ce, choose }, { ce + 3, #text, cancel } },
  }, { { 2, ce, "DiagnosticOk" }, { ce + 3, #text, "Comment" } } })
  table.insert(rows, { "" })
  table.insert(rows, { " Enter или клик — открыть папку · Esc назад", "Comment" })
  set_draw("Выбор папки", rows, 4)
end

-- открыть настройки (список); курсор — на репозитории path, если он задан
function M.settings(path)
  ensure_init()
  set.msg, set.val = nil, {}
  page_repos(path)
end

-- состояние текущего репозитория строкой (для lualine, по желанию)
function M.status()
  for path, r in pairs(st.rows) do
    if is_current(path) then
      local t = {}
      for _, seg in ipairs(status_parts(r)) do table.insert(t, seg[1]) end
      return table.concat(t, " ")
    end
  end
  return ""
end

-- ---------- настройка ----------
ensure_init = function()
  if st.inited then return end
  st.inited = true
  load_saved()
  local g = vim.api.nvim_create_augroup("gitdeck_nvim", { clear = true })
  -- сменилась папка nvim → перерисовать отметку текущего репозитория
  vim.api.nvim_create_autocmd("DirChanged", { group = g, callback = function() render() end })
  -- после git-команд fugitive, закрытия lazygit/терминала и возврата в окно
  -- терминала → обновить статусы сразу, не дожидаясь таймера
  local function soon() vim.defer_fn(M.refresh, 300) end
  vim.api.nvim_create_autocmd("User", { group = g, pattern = "FugitiveChanged", callback = soon })
  vim.api.nvim_create_autocmd({ "TermClose", "FocusGained" }, { group = g, callback = soon })
  -- открыли/закрыли терминал или другое окно → вернуть панели её высоту
  vim.api.nvim_create_autocmd({ "WinResized", "WinClosed", "WinNew", "VimResized" }, {
    group = g,
    callback = function() vim.schedule(M.fix_height) end,
  })
  -- при выходе: если остались только служебные окна — убрать панель,
  -- чтобы nvim закрывался как обычно
  vim.api.nvim_create_autocmd("QuitPre", {
    group = g,
    callback = function()
      if not M.is_open() then return end
      local cur, normal = vim.api.nvim_get_current_win(), 0
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype
        if w ~= cur and ft ~= "nerdtree" and ft ~= "gitdeck"
          and vim.api.nvim_win_get_config(w).relative == "" then
          normal = normal + 1
        end
      end
      if normal == 0 then M.close() end
    end,
  })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  ensure_init()
  start_timer()
  M.refresh()
  if M.config.open_on_start then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = vim.api.nvim_create_augroup("gitdeck_nvim_start", { clear = true }),
      callback = function() vim.defer_fn(M.open, 150) end,
    })
  end
end

M._state = st
return M
