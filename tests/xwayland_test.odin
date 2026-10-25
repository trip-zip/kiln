package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
xterm_identity_root_properties_and_close_survive_lazy_restart :: proc(t: ^testing.T) {
 rc, _ := os.read_entire_file(ROOT+"kilnrc.lua",context.temp_allocator)
 s,ok := boot(t,string(rc)); if !ok { stop(&s); return }; defer quit(t,&s)
 env := make([dynamic]string,context.temp_allocator)
 for entry in s.env { if !strings.has_prefix(entry,"DISPLAY=") && !strings.has_prefix(entry,"WAYLAND_DISPLAY=") { append(&env,entry) } }
 append(&env,fmt.tprintf("DISPLAY=%s",strings.trim_space(eval(&s,"return os.getenv('DISPLAY')"))))
 log,err := os.open(fmt.tprintf("%s/xterm.log",s.work),{.Write,.Create},os.Permissions_Default)
 if !testing.expect(t,err==nil) { return }; defer os.close(log)
 for cycle in 0..<2 {
  child,start_err := os.process_start({command={"xterm","-class","KilnM1","-name","kiln-m1","-title","kiln-x11-test","-e","sh","-c","sleep 60"},env=env[:],stdout=log,stderr=log})
  if !testing.expect(t,start_err==nil) { return }
  finished := false
  defer if !finished { _=os.process_kill(child); _,_=os.process_wait(child,time.Second) }
  if !expect_eventually(t,&s,"local c=client.all()[1]; return c and c.class,c and c.instance,c and c.pid>0","KilnM1\tkiln-m1\ttrue\n") { return }
  expect_eval(t,&s,fmt.tprintf("return client.all()[1].pid==%d",child.pid),"true\n")
  expect_eval(t,&s,"return client.all()[1].title","kiln-x11-test\n")
  prop_path := fmt.tprintf("%s/root-%d.txt",s.work,cycle)
  prop_log,prop_err := os.open(prop_path,{.Write,.Create},os.Permissions_Default)
  if testing.expect(t,prop_err==nil) {
   prop,pe := os.process_start({command={"xprop","-root","_NET_SUPPORTING_WM_CHECK","_NET_SUPPORTED"},env=env[:],stdout=prop_log,stderr=log})
   if testing.expect(t,pe==nil) {
    status,_ := os.process_wait(prop,5*time.Second)
    if !status.exited { _=os.process_kill(prop); _,_=os.process_wait(prop) }
    testing.expect(t,status.exited && status.exit_code==0)
   }
   os.close(prop_log)
   bytes,_ := os.read_entire_file(prop_path,context.temp_allocator)
   testing.expect(t,strings.contains(string(bytes),"_NET_SUPPORTING_WM_CHECK(WINDOW)") && strings.contains(string(bytes),"_NET_WM_STATE_FULLSCREEN"))
  }
  expect_eval(t,&s,"client.all()[1]:close()","\n")
  expect_eventually(t,&s,"return #client.all()","0\n")
  status,_ := os.process_wait(child,5*time.Second); finished=status.exited
  testing.expect(t,finished,"xterm acknowledged WM_DELETE_WINDOW")
  if cycle==0 {
   // The reserved display persists while the last-client termination delay expires.
   time.sleep(12*time.Second)
  }
 }
 text := read_log(&s)
 count := 0; for line in strings.split_lines(text,context.temp_allocator) { if strings.contains(line,"XWayland ready DISPLAY=") { count+=1 } }
 testing.expect_value(t,count,2)
 testing.expect(t,!strings.contains(text,"error in client communication") && !strings.contains(text,"Assertion"))
 if dir := os.get_env("KILN_TEST_ARTIFACTS",context.temp_allocator); dir!="" {
  testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%v-xterm.log",dir,backend()),text)==nil)
 }
}
