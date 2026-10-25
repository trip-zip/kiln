package xwayland

import "core:testing"
import "core:os"
import "core:fmt"
import "core:sys/posix"

@(test)
display_reservation_excludes_live_and_malformed_locks_and_reclaims_stale :: proc(t: ^testing.T) {
	root,err := os.make_directory_temp("","kiln-x11-lock-",context.allocator)
	if !testing.expect(t,err==nil) { return }; defer delete(root); defer os.remove_all(root)
	n,a,ok := reserve_display(root); if !testing.expect(t,ok && n==0) { return }
	defer release_display(n,&a,root)
	second,b,second_ok := reserve_display(root); if !testing.expect(t,second_ok && second==1) { return }
	release_display(second,&b,root)
	_ = os.write_entire_file(fmt.tprintf("%s/.X1-lock",root),"malformed")
	third,c,third_ok := reserve_display(root); testing.expect(t,third_ok && third==2)
	release_display(third,&c,root)
	pid := posix.fork(); if pid==0 { posix._exit(0) }; if pid<0 { testing.expect(t,false,"fork"); return }
	posix.waitpid(pid,nil,{})
	_ = os.write_entire_file(fmt.tprintf("%s/.X2-lock",root),fmt.tprintf("%10d\n",pid))
	reused,d,reused_ok := reserve_display(root); testing.expect(t,reused_ok && reused==2)
	release_display(reused,&d,root)
}
