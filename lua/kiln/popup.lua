
local ui = require("kiln.ui")
local state = require("kiln.state")
local grab = require("kiln.grab")
local hook = require("kiln.hook")

local popup = {}
local services=require("kiln.desktop_services")
local Bus=require("kiln.bus")

local live = {}
local marked = nil

local Popup = {}
Popup.__index = Popup

function Popup:release()
	local c = self.claim
	if c == nil then
		return
	end
	self.claim = nil
	c:stop()
end

function Popup:on_key(ev)
	if not ev.pressed then
		return
	end
	local keys = self.spec.keys
	if type(keys) == "function" then
		keys(ev, self)
		return
	end
	local act = keys[ev.key] or keys.any
	if act == "close" then
		self:close()
	elseif type(act) == "function" then
		act(ev, self)
	end
end

function Popup:show(s)
    if live[self.id]~=self or services.resetting then return end
	s = s or self.spec.screen or screen.focused or screen.all()[1]
	if not services.live(s) then
		return
	end
	if self.open and self.open~=s then core.dirty(self.open.name) end
	self.open = s
	if self.spec.keys ~= nil then
		self:release()
		local c
		c = grab.keygrabber {
			key = function(ev)
				self:on_key(ev)
			end,
			stopped = function()
				if self.claim == c then
					self.claim = nil
					self:close()
				end
			end,
		}
		self.claim = c
        if not c.active then self.claim=nil; self:close(); return end
	end
	core.dirty(s.name)
	return self
end

function Popup:close()
	if self.open == nil then
		return
	end
	core.dirty(self.open.name)
	self.open = nil
	self:release()
	if self.spec.on_close ~= nil then
		local ok,err=pcall(self.spec.on_close,self)
        if not ok then pcall(Bus.on_error,"popup close",err) end
	end
end

function Popup:toggle(s)
	if self.open ~= nil then
		self:close()
	else
		self:show(s)
	end
end

function Popup:destroy()
    if live[self.id]~=self then return end
    live[self.id]=nil
	self:close()
	hook.remove(self.hook)
end

function Popup:float(spec)
	local f = {
		band = spec.band or "overlay",
		fit = spec.fit ~= false,
		z = 1,
	}
	if spec.under ~= nil then
		f.to, f.parent = "element", spec.under
		f.anchor = spec.anchor
			or { parent = "left_bottom", element = "left_top" }
	elseif spec.at ~= nil then
		f.to = "root"
		f.offset = { x = spec.at.x or spec.at[1], y = spec.at.y or spec.at[2] }
		f.anchor = spec.anchor
	else
		f.to = "root"
		f.anchor = spec.anchor or "center"
	end
	return f
end

function Popup:declare(s)
	if live[self.id]~=self or self.open ~= s then
		return
	end
	local spec = self.spec
	if spec.style ~= nil then
		spec = setmetatable(spec.style(self) or {}, { __index = self.spec })
	end
    if spec.under and not core._declared(spec.under) then self:close(); return end
	if spec.scrim then
		ui.box({
			id = self.id .. ":scrim",
			float = { to = "root", band = spec.band or "overlay" },
			w = s.width, h = s.height,
			color = spec.scrim == true and "#00000001" or spec.scrim,
			on_press = function()
				self:close()
			end,
		})
	end
	ui.column({
		id = self.id,
		float = self:float(spec),
		w = spec.w, h = spec.h,
		color = spec.color, radius = spec.radius,
		pad = spec.pad, gap = spec.gap, align = spec.align,
		border = spec.border,
		clip = spec.clip,
	}, spec.fn and function()
		spec.fn(self, s)
	end or nil)
end

function popup.new(spec)
    assert(not services.resetting,"popup construction during reset")
	local id = spec.id
	if type(id) ~= "string" then
		error("ui.popup needs a plain string id", 2)
	end
	if live[id] ~= nil then
		error("ui.popup: id already in use: " .. id, 2)
	end
	local self = setmetatable({
		id = id,
		spec = spec,
		open = nil,
		claim = nil,
	}, Popup)
	live[id] = self
	self.hook = hook.add(function(s)
		self:declare(s)
	end)
	return self
end

function popup.mark()
    if marked then return end
	local m = {}
	for id, p in pairs(live) do
		m[id] = p
	end
	marked = m
end

function popup.reset()
    local snapshot={}
    for _,p in pairs(live) do snapshot[#snapshot+1]=p end
    for _,p in ipairs(snapshot) do p:close() end
    local fresh={}
    for id,p in pairs(marked or {}) do fresh[id]=p end
    live=fresh
end
function popup.remove(s)
    local snapshot={}
    for _,p in pairs(live) do if p.open==s then snapshot[#snapshot+1]=p end end
    for _,p in ipairs(snapshot) do p:close() end
end
return popup
