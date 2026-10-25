package tests

import xcb "../xcb"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
x_selections_cross_clipboard_primary_and_incremental_transfers :: proc(t: ^testing.T) {
 rc,_:=os.read_entire_file(ROOT+"kilnrc.lua",context.temp_allocator)
 s,ok:=boot(t,string(rc)); if !ok { stop(&s); return }; defer quit(t,&s)
 env:=make([dynamic]string,context.temp_allocator)
 for e in s.env { if !strings.has_prefix(e,"DISPLAY=") && !strings.has_prefix(e,"WAYLAND_DISPLAY=") { append(&env,e) } }
 append(&env,fmt.tprintf("DISPLAY=%s",strings.trim_space(eval(&s,`return os.getenv('DISPLAY')`))))
 log,_:=os.open(fmt.tprintf("%s/selection.log",s.work),{.Write,.Create},os.Permissions_Default); defer os.close(log)
 x,xe:=os.process_start({command={"xterm","-title","selection-focus","-e","sleep","120"},env=env[:],stdout=log,stderr=log})
 if !testing.expect(t,xe==nil) { return }; defer { _=os.process_kill(x); _,_=os.process_wait(x,time.Second) }
 if !expect_eventually(t,&s,`return #client.all()`,"1\n") { return }
 c:=selection_client_open(t,&s); defer selection_client_close(&c)
 for primary in ([]bool{false,true}) { for size in ([]int{17,1024*1024}) {
  payload:=make([]u8,size,context.temp_allocator); for &b,i in payload { b=u8('a'+i%26) }
  selection_client_own(&c,&s,primary,payload)
  eval(&s,`for _,c in ipairs(client.all()) do if c.title=='selection-focus' then c:focus() end end`)
  outpath:=fmt.tprintf("%s/xout",s.work); out,_:=os.open(outpath,{.Write,.Create,.Trunc},os.Permissions_Default)
  child,err:=os.process_start({command={"xclip","-o","-selection","primary" if primary else "clipboard","-target","UTF8_STRING"},env=env[:],stdout=out,stderr=log})
  assert(err==nil); os.close(out)
  done:=false
  for _ in 0..<10000 { selection_pump(&c); state,_:=os.process_wait(child,0); if state.exited { testing.expect_value(t,state.exit_code,0); done=true; break }; time.sleep(time.Millisecond) }
  if !done { _=os.process_kill(child); _,_=os.process_wait(child) }; testing.expect(t,done,"X requestor finished")
  result,_:=os.read_entire_file(outpath,context.temp_allocator); testing.expect(t,string(result)==string(payload),"selection bytes match")
  selection_words(&c,[]u32{21 if primary else 20,8<<16|1})
  selection_pump(&c)
  inpath:=fmt.tprintf("%s/xin",s.work); assert(os.write_entire_file(inpath,payload)==nil)
  input,_:=os.open(inpath,{.Read}); owner,oe:=os.process_start({command={"xclip","-quiet","-selection","primary" if primary else "clipboard","-target","UTF8_STRING"},env=env[:],stdin=input,stdout=log,stderr=log}); assert(oe==nil); os.close(input)
  time.sleep(200*time.Millisecond)
  selection_client_focus(&c,&s)
  for _ in 0..<100 { selection_pump(&c); if (c.primary_offer if primary else c.offer)!=0 { break }; time.sleep(10*time.Millisecond) }
  result=selection_client_read(&c,primary); testing.expect(t,string(result)==string(payload),"selection bytes match")
  _=os.process_kill(owner); _,_=os.process_wait(owner,time.Second)
  for _ in 0..<100 { selection_pump(&c); if (c.primary_offer if primary else c.offer)==0 { break }; time.sleep(10*time.Millisecond) }
  testing.expect_value(t,c.primary_offer if primary else c.offer,u32(0))
  fmt.printf("Selection %v primary=%v size=%d crossed both ways; owner exit cleared\n",backend(),primary,size)
 } }
 selection_client_own(&c,&s,false,transmute([]u8)string("stalled")); c.hold=true
 eval(&s,`for _,c in ipairs(client.all()) do if c.title=='selection-focus' then c:focus() end end`)
 xc:=xcb.connect_display(strings.trim_space(eval(&s,`return os.getenv('DISPLAY')`))); assert(xc!=nil); defer xcb.disconnect(xc)
 window:=xcb.selection_window(xc,xcb.screen(xc).root)
 clipboard:=xcb.intern(xc,"CLIPBOARD"); target:=xcb.intern(xc,"UTF8_STRING"); property:=xcb.intern(xc,"KILN_TEST_TRANSFER")
 before:=c.sends; xcb.convert_selection(xc,window,clipboard,target,property,0); xcb.flush(xc)
 for _ in 0..<100 { selection_pump(&c); if c.sends>before { break }; time.sleep(10*time.Millisecond) }
 testing.expect(t,c.sends>before,"Wayland source received the pending paste")
 selection_words(&c,[]u32{20,8<<16|1})
 failed:=false
 for _ in 0..<100 {
  selection_pump(&c)
  for { event,have:=xcb.poll(xc); if !have { break }; #partial switch e in event { case xcb.Selection_Notify: failed=e.requestor==window && e.property==0 } }
  if failed { break }; time.sleep(10*time.Millisecond)
 }
 testing.expect(t,failed,"source destruction returns SelectionNotify None while the writer stays open")
 fmt.printf("Selection %v destroyed source: SelectionNotify None received\n",backend())

}
