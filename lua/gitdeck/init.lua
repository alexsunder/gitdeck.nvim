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
  if not r.url then return { { "⌂ локальный", "DiagnosticWarn" } } end
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

local set = { buf = nil, win = nil, page = "repos", repo = nil, items = {} }
local set_interval -- объявлена ниже

local function set_close()
  if set.win and vim.api.nvim_win_is_valid(set.win) then vim.api.nvim_win_close(set.win, true) end
  set.win = nil
end

-- нарисовать страницу: lines = { {текст, группа}, … }, items[номер строки] = действие
local function set_draw(title, rows, cursor)
  local lines, hls, width = {}, {}, 44
  set.items = {}
  for i, row in ipairs(rows) do
    local text = row[1]
    lines[i] = text
    width = math.max(width, vim.fn.strdisplaywidth(text) + 2)
    if row[2] and #text > 0 then table.insert(hls, { i - 1, #text, row[2] }) end
    if row[3] then set.items[i] = row[3] end
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  if not (set.buf and vim.api.nvim_buf_is_valid(set.buf)) then
    set.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[set.buf].bufhidden = "wipe"
    local o = { buffer = set.buf, silent = true, nowait = true }
    vim.keymap.set("n", "<CR>", function() M._set_action("enter") end, o)
    vim.keymap.set("n", "a", function() M._set_action("add") end, o)
    vim.keymap.set("n", "d", function() M._set_action("remove") end, o)
    vim.keymap.set("n", "<Esc>", function() M._set_action("back") end, o)
    vim.keymap.set("n", "q", set_close, o)
    vim.api.nvim_create_autocmd("WinLeave", { buffer = set.buf, callback = function()
      vim.schedule(function() if not set.asking then set_close() end end)
    end })
  end
  vim.bo[set.buf].modifiable = true
  vim.api.nvim_buf_set_lines(set.buf, 0, -1, false, lines)
  vim.bo[set.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(set.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(set.buf, ns, h[1], 0, { end_col = h[2], hl_group = h[3] })
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
  else
    set.win = vim.api.nvim_open_win(set.buf, true, cfg)
    vim.wo[set.win].cursorline = true
  end
  -- курсор на первую строку с действием (или на заданную)
  local first = cursor
  if not first then
    for i = 1, #lines do if set.items[i] then first = i; break end end
  end
  pcall(vim.api.nvim_win_set_cursor, set.win, { first or 1, 0 })
end

local function page_repos(cursor_path)
  set.page, set.repo = "repos", nil
  local rows, cursor = {}, nil
  local list = st.list or M.find()
  local namew = 11
  for _, p in ipairs(list) do namew = math.max(namew, vim.fn.strdisplaywidth(vim.fs.basename(p))) end
  table.insert(rows, { "  " .. fit("Репозиторий", namew) .. "  отслеживаемая ветка", "Comment" })
  for _, p in ipairs(list) do
    local br = saved.branches[p] and saved.branches[p]
      or ("текущая" .. (M.tracked(p) and (": " .. M.tracked(p)) or ""))
    table.insert(rows, { "  " .. fit(vim.fs.basename(p), namew) .. "  " .. br, nil, { repo = p } })
    if p == cursor_path then cursor = #rows end
  end
  table.insert(rows, { "" })
  table.insert(rows, { "  + Добавить репозиторий", "DiagnosticOk", { add = true } })
  table.insert(rows, { "  ⏱ Проверять каждые: " .. interval() .. " мин", nil, { interval = true } })
  table.insert(rows, { "" })
  table.insert(rows, { " Enter выбрать · a добавить · d убрать · q закрыть", "Comment" })
  set_draw("GitDeck · настройки", rows, cursor)
end

local function page_repo(path)
  set.page, set.repo = "repo", path
  local cur = st.rows[path] and st.rows[path].branch
  local chosen = saved.branches[path]
  local rows, cursor = {}, nil
  table.insert(rows, { " Какую ветку отслеживать:", "Comment" })
  table.insert(rows, { (chosen and "  ○ " or "  ● ") .. "текущая" .. (cur and cur ~= "?" and (" (сейчас " .. cur .. ")") or ""),
    nil, { branch = false } })
  if not chosen then cursor = #rows end
  for _, b in ipairs(branches(path)) do
    table.insert(rows, { (chosen == b and "  ● " or "  ○ ") .. b, nil, { branch = b } })
    if chosen == b then cursor = #rows end
  end
  table.insert(rows, { "" })
  table.insert(rows, { "  − Убрать из отслеживаемых", "DiagnosticError", { remove = true } })
  table.insert(rows, { "" })
  table.insert(rows, { " Enter выбрать · Esc назад · q закрыть", "Comment" })
  set_draw(vim.fs.basename(path), rows, cursor)
end

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
  vim.notify("GitDeck: убран " .. path .. " (вернуть — «Добавить репозиторий»)")
  page_repos()
end

local function add_repo()
  set.asking = true
  vim.ui.input({ prompt = "Папка репозитория: ", default = expand("~/Documents/Projects") .. "/", completion = "dir" },
    function(input)
      set.asking = false
      vim.schedule(function()
        if not input or vim.trim(input) == "" then return page_repos() end
        local p = expand(vim.trim(input))
        if not is_repo(p) then
          vim.notify("GitDeck: в папке нет git-репозитория: " .. p, vim.log.levels.WARN)
          return page_repos()
        end
        saved.removed[p] = nil
        if not vim.tbl_contains(saved.added, p) then table.insert(saved.added, p) end
        write_saved()
        st.list = M.find()
        recheck(p)
        page_repos(p)
      end)
    end)
end

-- как часто проверять репозитории (минуты, целое от 1)
set_interval = function()
  set.asking = true
  vim.ui.input({ prompt = "Проверять каждые (минут): ", default = tostring(interval()) }, function(input)
    set.asking = false
    vim.schedule(function()
      local n = tonumber(input and vim.trim(input) or "")
      if input and vim.trim(input) ~= "" and not (n and n >= 1 and n == math.floor(n)) then
        vim.notify("GitDeck: нужно целое число минут, от 1", vim.log.levels.WARN)
      elseif n then
        saved.interval = n
        write_saved()
        start_timer()
        vim.notify("GitDeck: проверка каждые " .. n .. " мин")
      end
      local line = vim.api.nvim_win_is_valid(set.win or -1) and vim.api.nvim_win_get_cursor(set.win)[1]
      page_repos()
      if line then pcall(vim.api.nvim_win_set_cursor, set.win, { line, 0 }) end
    end)
  end)
end

function M._set_action(kind)
  local item = set.items[vim.api.nvim_win_get_cursor(0)[1]]
  if kind == "back" then
    if set.page == "repo" then return page_repos(set.repo) end
    return set_close()
  end
  if kind == "add" then return add_repo() end
  if kind == "remove" then
    local p = (item and item.repo) or (set.page == "repo" and set.repo)
    if p then remove_repo(p) end
    return
  end
  -- enter
  if not item then return end
  if item.add then return add_repo() end
  if item.interval then return set_interval() end
  if item.remove then return remove_repo(set.repo) end
  if item.repo then return page_repo(item.repo) end
  if item.branch ~= nil then
    saved.branches[set.repo] = item.branch or nil
    write_saved()
    recheck(set.repo)
    page_repos(set.repo)
  end
end

-- открыть настройки; path — репозиторий под курсором в панели (если есть)
function M.settings(path)
  ensure_init()
  if path then page_repo(path) else page_repos() end
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
