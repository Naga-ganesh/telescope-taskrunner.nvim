local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local config = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local log = require("plenary.log"):new()
log.level = "debug"

local M = {}

-- Usage tracking file path
local usage_file = vim.fn.stdpath("data") .. "/task_usage.json"

-- Function to load usage data
local function load_usage_data()
	local file = io.open(usage_file, "r")
	if not file then
		return {}
	end
	local content = file:read("*all")
	file:close()
	local ok, data = pcall(vim.fn.json_decode, content)
	return ok and data or {}
end

-- Function to save usage data
local function save_usage_data(data)
	local file = io.open(usage_file, "w")
	if file then
		file:write(vim.fn.json_encode(data))
		file:close()
	end
end

-- Function to increment task usage
local function increment_task_usage(task_name)
	local usage_data = load_usage_data()
	local existing_data = usage_data[task_name]
	local current_count = 0

	-- Handle both old format (number) and new format (table)
	if existing_data then
		current_count = type(existing_data) == "table" and existing_data.count or existing_data
	end

	usage_data[task_name] = {
		count = current_count + 1,
		last_used = os.time(),
	}
	save_usage_data(usage_data)
end

-- Function to get the most recently executed task
local function get_recent_task()
	local usage_data = load_usage_data()
	local recent_task = nil
	local latest_time = 0

	for task_name, data in pairs(usage_data) do
		local last_used = type(data) == "table" and data.last_used or 0
		if last_used > latest_time then
			latest_time = last_used
			recent_task = task_name
		end
	end

	return recent_task
end

-- Function to get tasks synchronously for simplicity
local function get_tasks()
	local output = vim.fn.system("task --list-all -j")
	if vim.v.shell_error ~= 0 then
		return {}
	end
	local ok, decoded = pcall(vim.fn.json_decode, output)
	if not ok or type(decoded) ~= "table" or not decoded.tasks then
		return {}
	end

	local tasks = decoded.tasks
	local usage_data = load_usage_data()

	-- Sort tasks by usage count (most used first), then alphabetically
	table.sort(tasks, function(a, b)
		local data_a = usage_data[a.name]
		local data_b = usage_data[b.name]

		-- Handle both old format (number) and new format (table)
		local usage_a = 0
		local usage_b = 0

		if data_a then
			usage_a = type(data_a) == "table" and data_a.count or data_a
		end

		if data_b then
			usage_b = type(data_b) == "table" and data_b.count or data_b
		end

		if usage_a == usage_b then
			return a.name < b.name -- Alphabetical fallback
		end
		return usage_a > usage_b -- Most used first
	end)

	return tasks
end

M.show_available_tasks = function(opts)
	print("Showing available tasks...")

	local tasks = get_tasks()

	pickers
		.new(opts or {}, {
			finder = finders.new_table({
				results = tasks,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.name,
						ordinal = entry.name,
					}
				end,
			}),
			sorter = config.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Task Preview",
				define_preview = function(self, entry)
					local lines = {
						"Task Details:",
						"Name: " .. entry.value.name,
						"Column: " .. entry.value.location.column,
						"Line: " .. entry.value.location.line,
						"Description: " .. (entry.value.desc or ""),
					}
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					log.debug(vim.inspect(selection))

					-- Increment usage counter for this task
					increment_task_usage(selection.display)

					local tmux_cmd = string.format(
						"tmux new-window -n 'Task %s' bash -c 'task %s; echo; read -p \"Press Enter to close...\" -r'",
						selection.display,
						selection.display
					)
					os.execute(tmux_cmd)
				end)
				return true
			end,
		})
		:find()
end

-- Function to execute the most recent task
M.execute_recent_task = function()
	local recent_task = get_recent_task()

	if not recent_task then
		print("No recent task found. Please run a task first.")
		return
	end

	print("Executing recent task: " .. recent_task)

	-- Increment usage counter for this task
	increment_task_usage(recent_task)

	local tmux_cmd = string.format(
		"tmux new-window -n 'Task %s' bash -c 'task %s; echo; read -p \"Press Enter to close...\" -r'",
		recent_task,
		recent_task
	)
	os.execute(tmux_cmd)
end

return M
