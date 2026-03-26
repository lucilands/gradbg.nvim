local M = {}
local gdbmi = require("gradbg.gdbmi")
local uv = vim.loop


local next_id = 0
M.breakpoints = {}

function send_gdbmi(msg)
	next_id = next_id + 1
	local id = next_id
	local result = nil
	M.gdb_proc.stdin:write(id .. msg .. "\n", function(err)
		if err then
			print("Failed to send GDB/MI message: " .. err)
			result = {}
		end
	end)
	M.gdb_proc.stdout:read_start(function(err, data)
		if not data then return end
		for line in data:gmatch("[^\n]+") do
			if line:match("^" .. id .. "%^") then
				local token, class, results = gdbmi.parse_mi_record(line)
				result = { token = token, class = class, results = results }
				M.gdb_proc.stdout:read_stop()
				return
			end
		end
	end)
	vim.wait(5000, function() return result ~= nil end, 10)
	return result or { token = id, class = "error", results = { msg = "timeout" } }
end

local function get_buffer_by_name(name)
    for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
        local buf_name = vim.api.nvim_buf_get_name(buf_id)
        
        if buf_name == name then
            return buf_id
        end
    end
    return nil
end

function update_signs(bufnr)
	vim.fn.sign_unplace('GraDBGBreakpoint', {buffer = '%'})
	for _, file in ipairs(M.breakpoints) do
		for _, bkpt in ipairs(file) do
			print("Setting breakpoint in line "..bktp.line)
			vim.fn.sign_place(0, "gradbg", "GraDBGBreakpoint", bufnr, { lnum = bkpt.line, priority = 20 })
		end
	end
end

function _G.GraDBG_sign_click(minwid, clicks, button, mods)
    if button == "l" then
		local pos = vim.fn.getmousepos()
		local bufnr = pos.screenrow and vim.api.nvim_get_current_buf() or pos.winid
	    bufnr = vim.api.nvim_get_current_buf()
		local line = pos.line

		if M.curbin then
			M.toggle_breakpoint(line)
		else
			vim.notify("Can only add breakpoint when debugging process is set", "ERROR")
		end
    end
end

function M.toggle_breakpoint(line)
	local bufnr = vim.api.nvim_get_current_buf()
	local existing = vim.fn.sign_getplaced(bufnr, { group = "gradbg", lnum = line })[1].signs
	if #existing > 0 then
		send_gdbmi("-break-delete " .. M.breakpoints[vim.api.nvim_buf_get_name(bufnr)].id)
	else
		local res = send_gdbmi("-break-insert " .. vim.fn.bufname() .. ":" .. line)
		if res.class == "done" then
			if not M.breakpoints[res.results.bkpt.file] then M.breakpoints[res.results.bkpt.file] = {} end
			table.insert(M.breakpoints[res.results.bkpt.file], {line = line, id = res.results.bkpt.number})
		else
			vim.notify("Failed to add breakpoint: " .. res.results.msg, "ERROR")
		end
	end
	update_signs(bufnr)
end

function M.init_dbg(bin)
	M.curbin = bin
	send_gdbmi("-file-exec-and-symbols " .. bin)
end

function M.reset()
	send_gdbmi("-file-exec-and-symbols")
	breakpoints = {}
	M.curbin = nil
end

function M.start(args)
	--local buf_handle = vim.api.nvim_create_buf(false, true)
	--vim.api.nvim_buf_set_option(buf_handle, "modifiable", false)

	local ui = vim.api.nvim_list_uis()[1]
	local width = ui.width
	local height = ui.height

	local win_options = {
		relative = 'editor',
		width = width / 2,
		height = height,
		col = width / 2,
		row = 0,
		border = 'rounded',
		focusable = true,
		zindex = 10,
	}
	
	--local window = vim.api.nvim_open_win(buf_handle, true, win_options)

	local lines = {}
	local timer = vim.uv.new_timer()


	local ns = vim.api.nvim_create_namespace("gradbg_debug_highlights")

	if args then
		send_gdbmi("-exec-arguments " .. table.concat(args, " "))
	end

	send_gdbmi("-exec-run")

	timer:start(100, 100, function()
		vim.schedule(function()
			M.gdb_proc.stdout:read_start(function(err, data)
				if data then
					lines = {}
					for line in data:gmatch("[^\n]+") do
						local token, class, result = gdbmi.parse_mi_record(line)
						if class == "stopped" then
							if result.reason == "breakpoint-hit" then
								vim.schedule(function()
									local file_buf = get_buffer_by_name(result.frame.file)
									if not file_buf then
										vim.cmd.edit(result.frame.fullname)
									else
										vim.cmd("buffer " .. file_buf)
									end
									vim.api.nvim_buf_add_highlight(vim.api.nvim_get_current_buf(), ns, "Visual", tonumber(result.frame.line)-1, 0, -1)
								end)
							end
							print(result.reason)
						end
					end
				end
			end)

			if lines then
				--vim.api.nvim_buf_set_lines(buf_handle, 0, -1, false, lines)
			end
		end)
	end)

	--vim.api.nvim_create_autocmd("WinClosed", {
		--buffer = buf_handle,
		--callback = function()
			--send_gdbmi("-exec-abort")
			--timer:stop()
			--timer:close()
		--end,
	--})
end

function M.stop()
	local ns = vim.api.nvim_create_namespace("gradbg_debug_highlights")
	send_gdbmi("-exec-abort")
	vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
end

function M.setup(opts)
	opts = opts or {}

	vim.fn.sign_define("GraDBGBreakpoint", { text = "●", texthl = "Error" })
	vim.o.statuscolumn = '%@v:lua.GraDBG_sign_click@ %s%=%l '

	M.gdb_proc = {}
	M.gdb_proc.stdin = uv.new_pipe(true)
	M.gdb_proc.stdout = uv.new_pipe(false)
	M.gdb_proc.stderr = uv.new_pipe(false)

	local handle, pid = uv.spawn("gdb", {
		args = {"-quiet", "--interpreter=mi3", "-nx"},
		stdio = {M.gdb_proc.stdin, M.gdb_proc.stdout, M.gdb_proc.stderr},
	}, function(code, signal) 
		print("gdb exited with code: " .. code)
		uv.close(handle)
	end)

	M.gdb_proc.handle = handle
	M.gdb_proc.pid = pid

	vim.api.nvim_create_user_command("GraDBG", function(opts)
		M.init_dbg(opts.fargs[1])
	end, {desc = "Start a debugging process", nargs = 1, complete = "file"})

	vim.api.nvim_create_user_command("GraDBGbreak", function(opts)
		M.toggle_breakpoint(opts.fargs[1])
	end, {desc = "Toggle breakpoint at line", nargs = 1})

	vim.api.nvim_create_user_command("GraDBGreset", function(opts)
		M.reset()
	end, {desc = "Reset the debugging process"})

	vim.api.nvim_create_user_command("GraDBGstart", function(opts)
		M.start(opts.fargs)
	end, {desc = "Start debugging", nargs = "*"})

	vim.api.nvim_create_user_command("GraDBGstop", function(opts)
		M.stop()
	end, {desc = "Stop the debugging process"})

end

return M
