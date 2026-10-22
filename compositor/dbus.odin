package compositor

import services "../desktop_bus"
import vm "../lua_runtime"

dbus_event :: proc(data:rawptr,event:vm.Event) { queue_event((^Server)(data),event) }
runtime_notify_closed :: proc(data:rawptr,id:u32,reason:i32) { services.notify_closed(&(^Server)(data).services,id,reason) }
runtime_notify_action :: proc(data:rawptr,id:u32,key:string) { services.notify_action(&(^Server)(data).services,id,key) }
runtime_tray_activate :: proc(data:rawptr,service,kind:string,a:i32,b:string) { services.activate(&(^Server)(data).services,service,kind,a,b) }
