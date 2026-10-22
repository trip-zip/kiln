local input_store = {
	-- Seeded with the compositor's own defaults, not left nil: set_repeat is
	-- a TWO-ARG verb, so writing repeat_rate alone still has to pass a delay,
	-- and a nil delay is an argument error.
	repeat_rate = 25,
	repeat_delay = 600,
}

local pointer_props = {
	tap_to_click = true, natural_scrolling = true, left_handed = true,
	accel_speed = true, accel_profile = true, scroll_method = true,
	click_method = true,
}

return setmetatable({}, {
	__index = function(_, k)
		return input_store[k]
	end,
	__newindex = function(_, k, v)
		input_store[k] = v
		if k == "keymap" then
			core.input.set_keymap(v or {})
		elseif k == "repeat_rate" or k == "repeat_delay" then
			core.input.set_repeat(input_store.repeat_rate,
				input_store.repeat_delay)
		elseif k == "numlock" then
			core.input.set_numlock(v)
		elseif pointer_props[k] then
			core.input.set_pointer({ [k] = v })
		end
	end,
})
