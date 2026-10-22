package compositor

import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"
import vm "../lua_runtime"
import wl "../wayland"

Pipe_Stream :: struct { pipe: ^Pipe, fd: posix.FD, number: i32, source: ^wl.Event_Source }
Pipe :: struct {
	server: ^Server,
	allocator: runtime.Allocator,
	id, generation: u64,
	pid: posix.pid_t,
	streams: [2]Pipe_Stream,
	exitfd: posix.FD,
	exit_source: ^wl.Event_Source,
	reaped: bool,
	code: i32,
}
close_stream :: proc(s: ^Pipe_Stream) {
	wl.remove_source(s.source);s.source=nil
	if s.fd>=0 { posix.close(s.fd);s.fd=-1 }
}
close_exit :: proc(p: ^Pipe) {
	wl.remove_source(p.exit_source);p.exit_source=nil
	if p.exitfd>=0 { posix.close(p.exitfd);p.exitfd=-1 }
}
drop_pipe :: proc(p: ^Pipe) {
	for &stream in p.streams { close_stream(&stream) }
	close_exit(p)
	delete_key(&p.server.pipes,p.id)
	free(p,p.allocator)
}
finish_pipe :: proc(p: ^Pipe) {
	if !p.reaped || p.streams[0].fd>=0 || p.streams[1].fd>=0 { return }
	queue_event(p.server,vm.Event{class="spawn",name="exit",id=p.id,generation=p.generation,exit_code=p.code})
	drop_pipe(p)
}
pipe_readable :: proc "c" (fd: i32, mask: u32, data: rawptr) -> i32 {
	context=runtime.default_context()
	stream:=(^Pipe_Stream)(data)
	p:=stream.pipe
	context.allocator=p.allocator
	buf: [8192]u8
	// Level-triggered readiness resumes draining next dispatch. No byte cap or loss.
	for _ in 0..<8 {
		n:=posix.read(stream.fd,raw_data(buf[:]),len(buf))
		if n>0 {
			queue_event(p.server,vm.Event{class="spawn",name="out",id=p.id,generation=p.generation,fd=stream.number,bytes=string(buf[:n])})
			continue
		}
		if n<0 && posix.errno()==.EINTR { continue }
		if n<0 && posix.errno()==.EAGAIN { return 0 }
		if n<0 { fail(p.server,"Async pipe read failed") }
		close_stream(stream)
		finish_pipe(p)
		return 0
	}
	return 0
}
pipe_exited :: proc "c" (fd: i32, mask: u32, data: rawptr) -> i32 {
	context=runtime.default_context()
	p:=(^Pipe)(data)
	context.allocator=p.allocator
	status: i32
	pid: posix.pid_t
	for {
		pid=posix.waitpid(p.pid,&status,{.NOHANG})
		if pid>=0 || posix.errno()!=.EINTR { break }
	}
	if pid==0 { return 0 }
	if pid!=p.pid {
		fail(p.server,"Async child lost its owned wait status")
		return 0
	}
	p.reaped=true
	p.code=posix.WEXITSTATUS(status) if posix.WIFEXITED(status) else 128+i32(posix.WTERMSIG(status))
	close_exit(p)
	finish_pipe(p)
	return 0
}
runtime_spawn_pipe :: proc(data: rawptr, argv: []cstring) -> u64 {
	s:=(^Server)(data)
	if s.shutting_down || s.next_pipe==vm.MAX_ASYNC_ID { return 0 }
	// Fail before launching anything on kernels or sandboxes without pidfds.
	probe,err:=linux.pidfd_open(linux.Pid(posix.getpid()),{})
	if err!=nil { return 0 }
	posix.close(posix.FD(probe))
	fds: [2][2]linux.Fd
	for &pair in fds { pair={-1,-1} }
	defer { for pair in fds { for fd in pair { if fd>=0 { posix.close(posix.FD(fd)) } } } }
	for &pair in fds {
		if linux.pipe2(&pair,{.CLOEXEC})!=nil { return 0 }
		for &fd in pair {
			if fd<3 {
				moved:=posix.fcntl(posix.FD(fd),.DUPFD_CLOEXEC,i32(3))
				if moved<0 { return 0 }
				posix.close(posix.FD(fd));fd=linux.Fd(moved)
			}
		}
		// Only the parent's read description is nonblocking. Writers retain blocking I/O.
		if posix.fcntl(posix.FD(pair[0]),.SETFL,posix.O_NONBLOCK)!=0 { return 0 }
	}
	pid:=posix.fork()
	if pid<0 { return 0 }
	if pid==0 {
		if posix.dup2(posix.FD(fds[0][1]),1)<0 || posix.dup2(posix.FD(fds[1][1]),2)<0 { posix._exit(127) }
		for pair in fds { for fd in pair { if fd>2 { posix.close(posix.FD(fd)) } } }
		empty: posix.sigset_t
		posix.sigemptyset(&empty)
		posix.sigprocmask(.SETMASK,&empty,nil)
		posix.setsid()
		posix.execvp(argv[0],raw_data(argv))
		posix._exit(127)
	}
	for &pair in fds { posix.close(posix.FD(pair[1]));pair[1]=-1 }
	p:=new(Pipe)
	s.next_pipe+=1
	p^={server=s,allocator=context.allocator,id=s.next_pipe,generation=s.lua.config_generation,pid=pid,exitfd=-1}
	for &stream,i in p.streams {
		stream={pipe=p,fd=posix.FD(fds[i][0]),number=i32(i+1)}
		fds[i][0]=-1
		stream.source=wl.on_fd(s.display,i32(stream.fd),wl.READABLE,pipe_readable,&stream)
	}
	exitfd,exit_err:=linux.pidfd_open(linux.Pid(pid),{})
	if exit_err==nil {
		p.exitfd=posix.FD(exitfd)
		p.exit_source=wl.on_fd(s.display,i32(p.exitfd),wl.READABLE,pipe_exited,p)
	}
	if p.streams[0].source==nil || p.streams[1].source==nil || p.exit_source==nil {
		// An unregistered child has no consumer. Terminate and account for this PID alone.
		posix.kill(pid,.SIGKILL)
		for posix.waitpid(pid,nil,{})<0 && posix.errno()==.EINTR {}
		drop_pipe(p)
		return 0
	}
	if s.pipes==nil { s.pipes=make(map[u64]^Pipe) }
	s.pipes[p.id]=p
	return p.id
}
shutdown_pipes :: proc(s: ^Server) {
	for _,p in s.pipes {
		// Retire callbacks immediately. Still-running applications become orphans at exit.
		if !p.reaped { posix.waitpid(p.pid,nil,{.NOHANG}) }
		drop_pipe(p)
	}
	delete(s.pipes);s.pipes=nil
	fmt.printf("Async cleanup: timers %d, pipes %d\n",len(s.timers),len(s.pipes))
}
