local bridge = ...
core._ui_guard=bridge.guard
local function finite(v)
    return v == v and v ~= math.huge and v ~= -math.huge
end
local function num(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    assert(finite(n) and math.abs(n) <= 1000000000, 'declaration number out of range')
    return n
end
local function enum(v, names, maximum)
    local n = tonumber(v) or names[v] or 0
    assert(finite(n) and n == math.floor(n) and n >= 0 and n <= maximum,
           'invalid declaration enum')
    return n
end
local sizing = {fit=0, grow=1, percent=2, fixed=3}
local direction = {ltr=0, ttb=1}
local ax = {left=0, right=1, center=2}
local ay = {top=0, bottom=1, center=2}
local function tab(t, k)
    return type(t[k]) == 'table' and t[k] or {}
end
local function axis(v)
    if tonumber(v) then local n=num(v); assert(n>=0, 'negative size'); return 3,n,n end
    if type(v) ~= 'table' then return 0,0,0 end
    local ty=enum(v.type,sizing,3)
    if ty==2 then
        local p=num(v.percent,0)
        assert(p>=0 and p<=1, 'percent must be between 0 and 1')
        return ty,p,0
    end
    if ty==3 then local n=num(v.px,0); assert(n>=0, 'negative size'); return ty,n,n end
    local lo,hi=num(v.min,0),num(v.max,0)
    assert(lo>=0 and hi>=0 and (hi==0 or hi>=lo), 'invalid sizing bounds')
    return ty,lo,hi
end
local function id(value, read)
    local name,index=value,0
    if type(value)=='table' then
        name,index=value[1],value[2]
        assert(type(index)=='number', 'table id index must be a number')
    end
    if not read and type(name)=='number' then name=tostring(name) end
    assert(type(name)=='string', 'expected a string id or { name, index }')
    assert(finite(index) and index>=0 and index<=4294967295 and index==math.floor(index),
           'id index out of range')
    return name,index
end
local function uint(v, default)
    local n=num(v,default or 0)
    assert(n>=0 and n<=65535, 'unsigned field out of range')
    return math.floor(n)
end
local function color(c)
    if type(c)~='table' then return 0,0,0,0 end
    return num(c.r,0),num(c.g,0),num(c.b,0),num(c.a,255)
end
local function radius(v)
    local n=num(v,0)
    assert(n>=0, 'negative corner radius')
    return n
end
local unsupported={
                   'custom','text','overlayColor','transition','userData'}
local points={left_top=0,left_center=1,left_bottom=2,center_top=3,center_center=4,center_bottom=5,right_top=6,right_center=7,right_bottom=8}
local function fill(t, handle)
    assert(type(t)=='table', 'core.open: expected a table')
    for _,k in ipairs(unsupported) do
        assert(t[k]==nil, 'unsupported drawing feature: '..k)
    end
    local name,index=false,0
    if t.id~=nil then name,index=id(t.id) end
    if handle then name,index='core.surface',handle end
    local l=tab(t,'layout')
    local s=tab(l,'sizing')
    local wt,wa,wb=axis(s.width)
    local ht,ha,hb=axis(s.height)
    local p=tab(l,'padding')
    local left,right,top,bottom=num(p.left,0),num(p.right,0),num(p.top,0),num(p.bottom,0)
    local gap=num(l.childGap,0)
    for _,v in ipairs{left,right,top,bottom,gap} do
        assert(v>=0 and v<=65535, 'padding or gap out of range')
    end
    local a=tab(l,'childAlignment')
    local c=tab(t,'backgroundColor')
    local r,g,b,alpha=0,0,0,0
    if type(t.backgroundColor)=='table' then
        r,g,b,alpha=num(c.r,0),num(c.g,0),num(c.b,0),num(c.a,255)
    end
    local cr=tab(t,'cornerRadius')
    local border=tab(t,'border')
    local bw=tab(border,'width')
    local br,bg,bb,ba=color(border.color)
    local path=tab(t,'image').path
    if type(path)=='number' then path=tostring(path) end
    if type(path)~='string' then path=false end
    local f=tab(t,'floating');local fo=tab(f,'offset');local fe=tab(f,'expand');local fp=tab(f,'attachPoints')
    local parent,pi=false,0
    if f.parentId~=nil then parent,pi=id(f.parentId) end
    local z=num(f.zIndex,0);assert(z>=-32768 and z<=32767,'zIndex out of range')
    local clip=tab(t,'clip'); local offset=tab(clip,'childOffset')
    return {name,index,wt,wa,wb,ht,ha,hb,left,right,top,bottom,gap,
            enum(a.x,ax,2),enum(a.y,ay,2),enum(l.layoutDirection,direction,1),r,g,b,alpha,
            radius(cr.topLeft),radius(cr.topRight),radius(cr.bottomLeft),radius(cr.bottomRight),
            br,bg,bb,ba,uint(bw.left),uint(bw.right),uint(bw.top),uint(bw.bottom),uint(bw.betweenChildren),num(t.aspectRatio,0),path,clip.horizontal and 1 or 0,clip.vertical and 1 or 0,num(offset.x,0),num(offset.y,0),
            num(fo.x,0),num(fo.y,0),num(fe.width,0),num(fe.height,0),z,
            enum(fp.element,points,8),enum(fp.parent,points,8),
            enum(f.pointerCaptureMode,{capture=0,passthrough=1},1),
            enum(f.attachTo,{none=0,parent=1,element=2,root=3},3),
            enum(f.clipTo,{none=0,attached_parent=1},1),parent,pi}
end
function core.open(t)
    bridge.guard()
    bridge.open(fill(t),0)
end
function core.close() bridge.close() end
function core.surface(handle,t)
    bridge.guard()
    local h=tonumber(handle)
    assert(h and finite(h) and h>0 and h<=4294967295 and h==math.floor(h),
           'core.surface: invalid handle')
    if type(t)~='table' then
        t={layout={sizing={width={type='grow'},height={type='grow'}}}}
    end
    bridge.open(fill(t,h),h)
end
function core.box(value)
    local name,index=id(value,true)
    return bridge.box(name,index)
end
function core.hits(screen,x,y)
    assert(type(screen)=='string', 'core.hits: expected screen name')
    assert(type(x)=='number' and type(y)=='number' and finite(x) and finite(y),
           'core.hits: expected finite coordinates')
    return bridge.hits(screen,x,y)
end
function core.dirty(screen)
    assert(screen==nil or type(screen)=='string',
           'core.dirty: expected screen name')
    bridge.dirty(screen)
end
function core.font(desc)
    assert(type(desc)=='string', 'core.font: expected a font description string')
    local result=bridge.font(desc)
    if result==-1 then error('core.font: a font description cannot carry a size; pass size = N instead: '..desc,2) end
    assert(result>=0, 'core.font: the font table is full or unavailable')
    return result
end
function core.text(s,cfg)
    bridge.guard()
    if type(s)=='number' then s=tostring(s) end
    assert(type(s)=='string', 'core.text: expected a string')
    cfg=type(cfg)=='table' and cfg or {}
    local r,g,b,a=color(cfg.textColor)
    bridge.text({r,g,b,a,uint(cfg.fontId),uint(cfg.fontSize,16),uint(cfg.letterSpacing),uint(cfg.lineHeight),
        enum(cfg.wrapMode,{words=0,newlines=1,none=2},2),
        enum(cfg.textAlignment,{left=0,center=1,right=2},2),cfg.ellipsize and 1 or 0},s)
end
function core.image_reload(path)
    assert(type(path)=='string' or type(path)=='number', 'core.image_reload: expected path')
    bridge.image_reload(tostring(path))
end

function core._declared(value)
    local name,index=id(value,true)
    return bridge.contains(name,index)
end
