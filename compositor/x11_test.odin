package compositor

import "core:strings"
import "core:testing"
import vm "../lua_runtime"
import wl "../wayland"
import wlr "../wlroots"

@(test)
x11_snapshots_use_associated_commits_and_owned_metadata :: proc(t: ^testing.T) {
    s:=Server{display=wl.create()}
    testing.expect(t,vm.init(&s.lua))
    defer destroy(&s)
    tree:wlr.wlr_scene_tree
    surface:=wlr.wlr_surface{current={width=301,height=207}}
    title:=strings.clone_to_cstring("title")
    class:=strings.clone_to_cstring("Class")
    instance:=strings.clone_to_cstring("instance")
    defer delete(title);defer delete(class);defer delete(instance)
    parent_handle:wlr.wlr_xwayland_surface
    parent_x:=X11_View{handle=&parent_handle}
    parent:=View{server=&s,protocol=&parent_x,tree=&tree,id=1,mapped=true,map_epoch=1}
    parent_x.view=&parent
    xs:=wlr.wlr_xwayland_surface{title=title,class=class,instance=instance,pid=1234,x=31,y=47,width=600,height=500,
        parent=&parent_handle,fullscreen=true,maximized_vert=true,maximized_horz=false,minimized=true}
    role:=strings.clone("test-role")
    defer delete(role)
    x:=X11_View{handle=&xs,surface=&surface,role=role,icon="xwl-icon:2"}
    v:=View{server=&s,protocol=&x,tree=&tree,id=2,mapped=true,map_epoch=7}
    x.view=&v
    append(&s.views,&v,&parent)
    defer clear(&s.views)
    queue_client(&v,"map")
    record_size(&v)
    e:=s.events[0]
    testing.expect(t,e.width==600 && e.height==500 && e.x==31 && e.y==47 && e.parent==1)
    testing.expect(t,e.pid==1234 && e.fullscreen && e.minimized && !e.maximized && !e.has_app_id)
    testing.expect(t,s.events[1].width==301 && s.events[1].height==207)
    (([^]u8)(title))[0]='X';(([^]u8)(class))[0]='X';(([^]u8)(instance))[0]='X'
    (transmute([]u8)role)[0]='X'
    testing.expect_value(t,e.role,"test-role");testing.expect_value(t,e.icon,"xwl-icon:2")
    testing.expect_value(t,e.title,"title");testing.expect_value(t,e.wm_class,"Class");testing.expect_value(t,e.wm_instance,"instance")
    expect_eval(t,&s,"facts={};core.set_event_handler(function(e)facts[#facts+1]=e end)","\n")
    wl.remove_source(s.event_source);drain_pending(&s)
    expect_eval(t,&s,"return facts[1].wm_class,facts[1].wm_instance,facts[1].pid,facts[1].app_id,facts[2].width","Class\tinstance\t1234\tnil\t301\n")
    configure:=wlr.wlr_xwayland_surface_configure_event{x=200,y=300,width=400,height=500}
    x11_configure(&x.configure,&configure)
    configure.width=999
    testing.expect_value(t,s.events[0].width,i32(400))
    queue_client(&v,"metadata")
    x11_urgency(&x)
    queue_client(&v,"request::fullscreen")
    v.map_epoch+=1
    wl.remove_source(s.event_source);drain_pending(&s)
    expect_eval(t,&s,"return #facts","2\n")
    runtime_replay(&s)
    testing.expect(t,len(s.events)==4 && s.events[0].handle==1 && s.events[2].handle==2)
    // A dissociated object remains a handle, but no longer exposes a surface.
    x.surface=nil
    testing.expect(t,view_surface(&v)==nil && view_geometry(&v).width==0)
    testing.expect_value(t,view_parent(&v),u32(1))
}

@(test)
x11_configure_rejects_unrepresentable_values_before_ffi :: proc(t: ^testing.T) {
    for box in ([6][4]i32{{-32769,0,1,1},{32768,0,1,1},{0,-32769,1,1},{0,32768,1,1},{0,0,65536,1},{0,0,1,65536}}) {
        testing.expect(t,!wlr.xwayland_configure(nil,box[0],box[1],box[2],box[3]))
    }
    testing.expect(t,!wlr.xwayland_configure(nil,0,0,0,1))
}
