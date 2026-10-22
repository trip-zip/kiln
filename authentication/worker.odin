package authentication

import "base:runtime"
import "core:c"
import "core:sys/posix"
import "core:sys/linux"
import time "core:time"
_ :: time
import pam "../pam"

FIXTURE :: #config(KILN_AUTH_FIXTURE,false)
when FIXTURE { TIMEOUT_MS :: 1500 } else { TIMEOUT_MS :: 30000 }
MAGIC :: u32(0x4b415531)
// Same executable, native endian, fixed-size frame with a bounded payload.
Header :: struct { magic,length:u32, generation,id:u64 }
Reply :: struct { magic,success:u32, generation,id:u64 }
#assert(size_of(Header)==24 && size_of(Reply)==24)
read_all :: proc(fd:posix.FD,bytes:[]u8)->bool {
    offset:=0
    for offset<len(bytes) {
        n:=posix.read(fd,raw_data(bytes[offset:]),uint(len(bytes))-uint(offset))
        if n<0 && posix.errno()==.EINTR { continue }
        if n<=0 { return false };offset+=int(n)
    }
    return true
}
worker_secret: [pam.MAX_PASSWORD+1]u8
worker_cancel :: proc "c" (sig:linux.Signal) {
    context=runtime.default_context()
    pam.clear_secret(worker_secret[:])
    posix._exit(1)
}
worker_main :: proc() -> i32 {
    if posix.fcntl(3,.SETFD,c.int(posix.FD_CLOEXEC))<0 { return 1 }
    if linux.prctl(4,0,0,0,0)!=nil { return 1 }
    action:=linux.Sig_Action{handler=worker_cancel,flags={.RESTART}}
    if linux.rt_sigaction(.SIGTERM,&action,nil)!=nil { return 1 }
    defer pam.clear_secret(worker_secret[:])
    h:Header
    if !read_all(3,([^]u8)(&h)[:size_of(h)]) || h.magic!=MAGIC || h.length>pam.MAX_PASSWORD { return 1 }
    if !read_all(3,worker_secret[:h.length]) { return 1 }
    for b in worker_secret[:h.length] { if b==0 { return 1 } }
    extra:u8
    if posix.read(3,&extra,1)!=0 { return 1 }
    success:=false
    when FIXTURE {
        password:=string(worker_secret[:h.length])
        switch password {
        case "fixture-success":success=true
        case "fixture-delay":time.sleep(700*time.Millisecond);success=true
        case "fixture-timeout":time.sleep(5*time.Second);success=true
        case "fixture-crash":return 17
        case "fixture-partial":
            b:u8=1;posix.send(3,&b,1,{.NOSIGNAL});return 0
        case "fixture-stale":h.generation-=1;success=true
        case "fixture-old-request":h.id-=1;success=true
        }
    } else { success=pam.check(worker_secret[:h.length]) }
    pam.clear_secret(worker_secret[:])
    reply:=Reply{MAGIC,u32(success),h.generation,h.id}
    bytes:=([^]u8)(&reply)[:size_of(reply)]
    offset:=0
    for offset<len(bytes) {
        n:=posix.send(3,raw_data(bytes[offset:]),uint(len(bytes))-uint(offset),{.NOSIGNAL})
        if n<0 && posix.errno()==.EINTR { continue }
        if n<=0 { return 1 };offset+=int(n)
    }
    return 0
}
