-- trp.lua — a tiny Neovim plugin that speaks the Terminal Resume Protocol (OSC 88).
--
-- Spec: https://github.com/Otty-sh/osc-88
--
-- What it does:
--   * On entering Neovim / opening a buffer window, it ARMS a relaunch:
--       - if a Session.vim (or a path you configure) exists, `nvim -S <session>`
--       - otherwise `nvim <current file>` (or bare `nvim` for an empty buffer)
--     so that after a terminal restart the editor reopens where you left off.
--   * On a clean quit (VimLeavePre), it CLEARS the spec, so a deliberate `:q`
--     is not resurrected. A crash leaves it armed — exactly when you want resume.
--
-- Install: drop this file in your runtimepath and `require('trp')` from init.lua,
-- or just `:luafile trp.lua`. Self-contained, no dependencies.
--
-- Optional config (all fields optional):
--   require('trp').setup({
--     session = 'Session.vim',  -- session file to look for / arm with -S
--     self_repaint = true,      -- nvim repaints its own screen on resume
--   })

local M = {}

local config = {
	session = "Session.vim",
	self_repaint = true,
}

-- base64 encode (RFC 4648 standard alphabet, with padding). Pure Lua so the
-- plugin has no external dependency.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(data)
	local out = {}
	local len = #data
	local i = 1
	while i <= len do
		local b1 = data:byte(i)
		local b2 = data:byte(i + 1)
		local b3 = data:byte(i + 2)
		local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
		out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
		out[#out + 1] = b2 and B64:sub(c3 + 1, c3 + 1) or "="
		out[#out + 1] = b3 and B64:sub(c4 + 1, c4 + 1) or "="
		i = i + 3
	end
	return table.concat(out)
end

-- Write a raw OSC 88 body to the controlling terminal. Neovim talks to its host
-- terminal over stderr's tty; chansend to v:stderr is the portable way to emit
-- raw escape sequences (and Neovim handles the tmux/Zellij passthrough wrapping
-- for OSC sequences it forwards). We emit ESC ] 88 ; <body> ST.
local function emit(body)
	local ESC = "\027"
	local seq = ESC .. "]" .. body .. ESC .. "\\"
	-- channel 2 is Neovim's stderr, which is the UI tty.
	pcall(vim.fn.chansend, 2, seq)
end

-- Arm a relaunch spec.
local function arm(cmd, args)
	local body = "88;arm;cmd=" .. b64encode(cmd)
	if args and args ~= "" then
		body = body .. ";args=" .. b64encode(args)
	end
	if config.self_repaint then
		body = body .. ";self_repaint=1"
	end
	-- Pin the cwd so resume reopens in the right place.
	body = body .. ";cwd=" .. b64encode(vim.fn.getcwd())
	emit(body)
end

local function clear()
	emit("88;clear")
end

-- Decide what to arm based on the current editor state.
local function arm_current()
	local session = config.session
	if session and session ~= "" and vim.fn.filereadable(session) == 1 then
		arm("nvim", "-S " .. vim.fn.fnameescape(session))
		return
	end

	local file = vim.fn.expand("%:p")
	if file and file ~= "" then
		arm("nvim", vim.fn.fnameescape(file))
	else
		arm("nvim", nil)
	end
end

function M.setup(opts)
	if opts then
		for k, v in pairs(opts) do
			config[k] = v
		end
	end

	local group = vim.api.nvim_create_augroup("TrpResume", { clear = true })

	-- Arm on startup and whenever a buffer is shown in a window (keeps the
	-- armed spec roughly current as you switch files).
	vim.api.nvim_create_autocmd({ "VimEnter", "BufWinEnter" }, {
		group = group,
		callback = arm_current,
	})

	-- Clear on a clean quit.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = clear,
	})
end

-- Allow `:luafile trp.lua` to just work with defaults.
M.setup()

return M
