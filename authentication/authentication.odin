package authentication

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"
import wl "../wayland"
import pam "../pam"

Attempt :: struct {
    pid:posix.pid_t,
    fd,exitfd:posix.FD,
    source,timer:^wl.Event_Source,
    generation,id:u64,
    reason:string,
    killing:bool,
    data:rawptr,
    complete:proc(rawptr,u64,u64,bool,string),
}
retire :: proc(a:^Attempt) {
    wl.remove_source(a.source);wl.remove_source(a.timer)
    if a.fd>=0 { posix.close(a.fd) }
    if a.exitfd>=0 { posix.close(a.exitfd) }
    a^={}
}
terminate :: proc(a:^Attempt, reason:string) {
    if a.pid<=0 || a.reason!="" { return }
    a.reason=reason
    // The child owns its process group; the direct kill also covers pre-setsid failure.
    posix.kill(-a.pid,.SIGTERM);posix.kill(a.pid,.SIGTERM)
    wl.arm_timer(a.timer,200)
}
timeout :: proc "c" (data:rawptr)->i32 {
    context=runtime.default_context();a:=(^Attempt)(data)
    if a.reason=="" { terminate(a,"timeout") }
    else {
        a.killing=true
        posix.kill(-a.pid,.SIGKILL);posix.kill(a.pid,.SIGKILL)
    }
    if a.source==nil {
        // Registration failure still has a preallocated timer for bounded cleanup.
        exited(-1,0,a)
        if a.pid>0 { wl.arm_timer(a.timer,20) }
    }
    return 0
}
exited :: proc "c" (fd:i32,mask:u32,data:rawptr)->i32 {
    context=runtime.default_context();a:=(^Attempt)(data)
    status:c.int
    pid:posix.pid_t
    for { pid=posix.waitpid(a.pid,&status,{.NOHANG});if pid>=0 || posix.errno()!=.EINTR { break } }
    if pid==0 { return 0 }
    success:=false;reason:=a.reason
    if reason=="" {
        reason="worker"
        if pid==a.pid && posix.WIFEXITED(status) && posix.WEXITSTATUS(status)==0 {
            reply:Reply
            n:=posix.read(a.fd,([^]u8)(&reply),size_of(reply))
            extra:u8
            tail:=posix.read(a.fd,&extra,1)
            if n==size_of(reply) && tail==0 && reply.magic==MAGIC && reply.success<=1 && reply.generation==a.generation && reply.id==a.id {
                success=reply.success==1;reason="success" if success else "rejected"
            } else { reason="invalid-reply" }
        }
    }
    callback,user,generation,id:=a.complete,a.data,a.generation,a.id
    retire(a)
    if callback!=nil { callback(user,generation,id,success,reason) }
    return 0
}
submit :: proc(a:^Attempt,display:^wl.Display,generation,id:u64,password:string,data:rawptr,complete:proc(rawptr,u64,u64,bool,string))->bool {
    if a.pid!=0 || !pam.valid_password(password) { return false }
    probe,err:=linux.pidfd_open(linux.Pid(posix.getpid()),{})
    if err!=nil { return false };posix.close(posix.FD(probe))
    pair:[2]posix.FD
    if posix.socketpair(.UNIX,.STREAM,{},&pair)!=.OK { return false }
    defer { for fd in pair { if fd>=0 { posix.close(fd) } } }
    for fd in pair { if posix.fcntl(fd,.SETFD,c.int(posix.FD_CLOEXEC))<0 { return false } }
    if posix.fcntl(pair[0],.SETFL,c.int(posix.O_NONBLOCK))<0 { return false }
    null:=posix.open("/dev/null",{.RDWR,.CLOEXEC},{})
    if null<0 { return false };defer posix.close(null)
    cleanup_timer:=wl.on_timer(display,timeout,a)
    if cleanup_timer==nil { return false }
    defer { if cleanup_timer!=nil { wl.remove_source(cleanup_timer) } }
    pid:=posix.fork()
    if pid==0 {
        if posix.setsid()<0 { posix._exit(1) }
        empty:posix.sigset_t;posix.sigemptyset(&empty);posix.sigprocmask(.SETMASK,&empty,nil)
        // Preserve sources even when the compositor inherited closed stdio slots.
        channel:=posix.fcntl(pair[1],.DUPFD_CLOEXEC,c.int(4))
        sink:=posix.fcntl(null,.DUPFD_CLOEXEC,c.int(4))
        if channel<0 || sink<0 { posix._exit(1) }
        for fd in 0..<3 { if posix.dup2(posix.FD(sink),posix.FD(fd))<0 { posix._exit(1) } }
        if posix.dup2(posix.FD(channel),3)<0 { posix._exit(1) }
        if linux.close_range(4,max(linux.Fd),{})!=nil { posix._exit(1) }
        argv:=[3]cstring{"kiln","--auth-worker",nil}
        env:=[3]cstring{"PATH=/usr/bin:/bin","LANG=C.UTF-8",nil}
        posix.execve("/proc/self/exe",raw_data(argv[:]),raw_data(env[:]))
        posix._exit(1)
    }
    if pid<0 { return false }
    posix.close(pair[1]);pair[1]=-1
    exitfd,exiterr:=linux.pidfd_open(linux.Pid(pid),{})
    pidfd_failed:=exiterr!=nil
    when FIXTURE {
        if password=="fixture-no-pidfd" {
            if !pidfd_failed { posix.close(posix.FD(exitfd)) }
            pidfd_failed=true
        }
    }
    a^={pid=pid,fd=pair[0],exitfd=-1,timer=cleanup_timer,generation=generation,id=id,data=data,complete=complete}
    pair[0]=-1;cleanup_timer=nil
    if pidfd_failed { terminate(a,"submission");return false }
    a.exitfd=posix.FD(exitfd)
    a.source=wl.on_fd(display,i32(a.exitfd),wl.READABLE,exited,a)
    when FIXTURE {
        if password=="fixture-no-source" { wl.remove_source(a.source);a.source=nil }
    }
    if a.source==nil { terminate(a,"submission");return false }
    bytes:[size_of(Header)+pam.MAX_PASSWORD]u8
    defer pam.clear_secret(bytes[:])
    h:=Header{MAGIC,u32(len(password)),generation,id}
    copy(bytes[:size_of(h)],([^]u8)(&h)[:size_of(h)])
    copy(bytes[size_of(h):],transmute([]u8)password)
    n:=posix.send(a.fd,raw_data(bytes[:]),size_of(h)+len(password),{.NOSIGNAL})
    if n!=size_of(h)+len(password) { terminate(a,"submission");return false }
    posix.shutdown(a.fd,.WR)
    if !wl.arm_timer(a.timer,TIMEOUT_MS) { terminate(a,"submission");return false }
    return true
}
cancel :: proc(a:^Attempt) { terminate(a,"cancelled") }
shutdown :: proc(a:^Attempt) {
    if a.pid<=0 { return }
    a.complete=nil
    terminate(a,"shutdown")
    p:=posix.pollfd{fd=a.exitfd,events={.IN}}
    if posix.poll(([^]posix.pollfd)(&p),1,200)<=0 {
        posix.kill(-a.pid,.SIGKILL);posix.kill(a.pid,.SIGKILL)
        posix.poll(([^]posix.pollfd)(&p),1,1000)
    }
    pid:=a.pid
    exited(i32(a.exitfd),0,a)
    if a.pid!=0 { fmt.eprintf("Authentication helper %d did not retire within shutdown deadline\n",pid) }
}
