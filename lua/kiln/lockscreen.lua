-- Appearance and trusted native text handling; Odin owns the unlock gate.
local ui = require('kiln.ui')
local M = { active = false }
local password, status, failed, pending, clock = '', nil, false, nil, nil
local config = {
    bg='#101014', fg='#dcdce6', error='#c05068',
    clock_size=48, date_size=16, dots_size=22, status_size=14,
    clock_format='%H:%M', date_format='%A, %B %d',
    prompt='Enter password to unlock', fail='Authentication failed',
    pending='Authenticating...',
}
function M.configure(cfg)
    for k,v in pairs(cfg or {}) do config[k]=v end
    if M.active then core.dirty() end
end
local function count(s)
    local n=0
    for i=1,#s do local b=s:byte(i);if b<128 or b>=192 then n=n+1 end end
    return n
end
local function backspace(s)
    local i=#s
    while i>0 and s:byte(i)>=128 and s:byte(i)<192 do i=i-1 end
    return s:sub(1,i-1)
end
local function tick()
    if clock or not M.active then return end
    clock=core.timer(1000,function()
        clock=nil
        if M.active then core.dirty();tick() end
    end)
end
local function draw(name,width,height)
    ui.column({id='lock:'..name,w='grow',h='grow',color=config.bg,align='center',gap=14},function()
        ui.text(os.date(config.clock_format),{size=config.clock_size,color=config.fg})
        ui.text(os.date(config.date_format),{size=config.date_size,color=config.fg})
        ui.box({id='lock:dots'},function()
            local dots=string.rep('*',count(password))
            ui.text(dots=='' and ' ' or dots,{size=config.dots_size,color=config.fg})
        end)
        ui.box({id='lock:status'},function()
            ui.text(status or config.prompt,{size=config.status_size,color=failed and config.error or config.fg})
        end)
    end)
end
local function clear()
    if clock then core.timer_cancel(clock);clock=nil end
    M.active=false;password='';pending=nil;status=nil;failed=false
end
function M.reset() clear();core.set_lock_handler(draw) end
function M.on_lock(kind)
    clear()
    if kind~='native' then return end
    M.active=true;status=config.prompt;tick();core.dirty()
end
function M.on_unlock() clear() end
function M.on_authenticated(ev)
    if not M.active or ev.id~=pending then return end
    pending=nil
    if ev.success and core.unlock() then return end
    password='';status=config.fail;failed=true;core.dirty()
end
function M.on_key(ev)
    if not M.active or not ev.pressed or pending then return end
    if ev.key=='Return' or ev.key=='KP_Enter' then
        pending=core.authenticate(password)
        password=''
        status=pending and config.pending or config.fail;failed=not pending
    elseif ev.key=='BackSpace' then
        password=backspace(password);status=config.prompt;failed=false
    elseif ev.key=='Escape' then
        password='';status=config.prompt;failed=false
    elseif ev.utf8 and ev.utf8~='' and not ev.utf8:find('[%z\1-\31\127]') and #password+#ev.utf8<=511 then
        password=password..ev.utf8;status=config.prompt;failed=false
    end
    core.dirty()
end
M.reset()
return M
