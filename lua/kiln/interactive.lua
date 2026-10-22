local state = require('kiln.state')
local grab = require('kiln.grab')
return function(owner)
    local active
    local valid_edges={n=true,s=true,e=true,w=true,ne=true,nw=true,se=true,sw=true}
    local function snapshot(c, s)
        local solved = state.client_boxes[s.name] and state.client_boxes[s.name][c.handle]
        local f = (c.floating and c.float) or solved or c.float or {}
        local th = state.theme
        return {x=f.x or 0, y=f.y or 0,
            width=f.width or ((c.width or 0)>0 and c.width or 400)+2*th.border_width,
            height=f.height or ((c.height or 0)>0 and c.height or 300)+2*th.border_width+
                (c.titlebar~=false and th.titlebar_height or 0)}
    end
    local function start(c, edges)
        local p, s = state.current_press, owner(c)
        if not p or not p.pressed or not s then return end
        if edges then assert(valid_edges[edges], 'unknown resize edge') end
        local f = snapshot(c, s)
        c.float, c.floating = f, true
        local g = {c=c, screen=s}
        local function motion(e)
            if owner(c) ~= s then g.claim:stop(); return end
            local dx, dy = math.floor(e.x-p.x+0.5), math.floor(e.y-p.y+0.5)
            local x,y,w,h = f.x,f.y,f.width,f.height
            if edges then
                local minimum = state.theme.min_size
                if edges:find('e') then w=math.max(minimum,f.width+dx) end
                if edges:find('w') then w=math.max(minimum,f.width-dx);x=f.x+f.width-w end
                if edges:find('s') then h=math.max(minimum,f.height+dy) end
                if edges:find('n') then h=math.max(minimum,f.height-dy);y=f.y+f.height-h end
                w,h=math.max(minimum,w),math.max(minimum,h)
            else x,y=x+dx,y+dy end
            c.float = {x=x,y=y,width=w,height=h}
        end
        active = g
        g.claim = grab.mousegrabber{
            motion=motion,
            button=function(e) if not e.pressed and e.button==p.button then g.claim:stop() end end,
            stopped=function() if active==g then active=nil end end,
        }
        if g.claim.active then
            core.input.set_cursor(edges and (state.theme.cursors.resize[edges] or "default") or state.theme.cursors.move)
        end
    end
    function client.methods:grab_move() start(self) end
    function client.methods:grab_resize(edges) start(self, edges) end
    function client.methods:grab_resize_nearest()
        local p,s = state.current_press,owner(self)
        if not p or not p.pressed or not s then return end
        local f = snapshot(self,s)
        local x,y=p.x-(s.x or 0),p.y-(s.y or 0)
        start(self,(y<f.y+f.height/2 and 'n' or 's') .. (x<f.x+f.width/2 and 'w' or 'e'))
    end
    local function stop(c) if active and active.c==c then active.claim:stop() end end
    client.on('unmap',stop)
    client.on('destroy',stop)
    screen.on('removed',function(s) if active and active.screen==s then active.claim:stop() end end)
    client.on('property::tags',function(c) if active and active.c==c and owner(c)~=active.screen then stop(c) end end)
end
