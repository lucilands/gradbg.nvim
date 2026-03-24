local M = {}
local uv = vim.loop

function newStack ()
    return {""}   -- starts with an empty string
end
    
function addString (stack, s)
	table.insert(stack, s)    -- push 's' into the the stack
    for i=table.getn(stack)-1, 1, -1 do
		if string.len(stack[i]) > string.len(stack[i+1]) then
			break
		end
		stack[i] = stack[i] .. table.remove(stack)
	end
end

function send_gdbmi(msg)
	M.gdb_proc.stdin:write(msg .. "\n", function(err)
		if err then
			print("Failed to send GDB/MI message: " .. err)
		else
			print(msg)
		end
	end)
end

function frame_function(bufnr, s)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", true)

	M.gdb_proc.stdout:read_start(function(err, data)
		if data then
			for str in string.gmatch(data, "([^".."\n".."]+)") do
				addString(s, str)
			end
		end
	end)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, s)

	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

function M.open_dbg(bin)
	print("Debugging " .. bin)
	local buf_handle = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf_handle, "modifiable", false)

	local ui = vim.api.nvim_list_uis()[1]
	local width = ui.width
	local height = ui.height

	local win_options = {
		relative = 'editor',
		width = width,
		height = height,
		col = 0,
		row = 0,
		border = 'rounded',
		focusable = true,
		zindex = 10,
	}

	local window = vim.api.nvim_open_win(buf_handle, true, win_options)

	send_gdbmi("-file-exec-and-symbols " .. bin)

	local s = newStack()
	local timer = vim.loop.new_timer()
	timer:start(0, 100, vim.schedule_wrap(function()
		if vim.api.nvim_buf_is_valid(buf_handle) then
			frame_function(buf_handle, s)
		else
			timer:stop()
			if not timer:is_closing() then timer:close() end
		end
	end))

	vim.api.nvim_create_autocmd("WinClosed", {
		buffer = buf_handle,
		callback = function()
			timer:stop()
			if not timer:is_closing() then timer:close() end
		end,
	})
end

function M.setup(opts)
	opts = opts or {}

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
		M.open_dbg(opts.fargs[1])
	end, {desc = "Open debug window", nargs = 1})
end

return M
