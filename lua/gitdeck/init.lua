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

-- сама папка или её подпапки первого уровня, где есть .git
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
        if is_repo(p) and not seen[p] then
          seen[p] = true
          table.insert(list, p)
        end
      end
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
echo "branch=$(git branch --show-current 2>/dev/null)"
echo "ab=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)"
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
    { cwd = path, text = true, env = { GIT_TERMINAL_PROMPT = "0" }, timeout = 30000 },
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
    local namew = math.max(8, math.min(22, width - 2 - math.max(stw, 6) - 1))
    local parts = {
      { here and "▶" or " ", "Title" },
      { fit(vim.fs.basename(path), namew) .. " ", here and "Title" or "Directory" },
    }
    vim.list_extend(parts, status)
    add(parts)
    st.paths[#lines] = path
  end
  if #(st.list or {}) == 0 then add({ { " (репозиториев не найдено)", "Comment" } }) end
  add({ { " Enter перейти · r обновить · q скрыть", "Comment" } })
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
local function start_timer()
  if st.timer then return end
  st.timer = (vim.uv or vim.loop).new_timer()
  local ms = M.config.interval * 60 * 1000
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
