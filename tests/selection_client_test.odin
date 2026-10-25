package tests

import wl "../wayland"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

Selection_Client :: struct {
 peer: wl.Connection,
 globals: map[string]u32,
 serial, offer, primary_offer: u32,
 configured: bool,
 payload: []u8,
 writes: [dynamic]struct { fd: linux.Fd, at: int },
 sends: int,
 hold: bool,
}
selection_words :: proc(c: ^Selection_Client, words: []u32, fds: []linux.Fd = nil) {
 assert(wl.connection_queue(&c.peer, (cast([^]u8)raw_data(words))[:len(words)*4], fds) == .NONE)
 assert(wl.connection_flush(&c.peer) == .NONE)
}
selection_text :: proc(c: ^Selection_Client, id, opcode: u32, value: string, fds: []linux.Fd = nil) {
 bytes := make([]u8, 12+(len(value)+4)&~3, context.temp_allocator)
 wl.word_write(bytes, 0, id); wl.word_write(bytes, 4, u32(len(bytes))<<16|opcode)
 wl.word_write(bytes, 8, u32(len(value)+1)); copy(bytes[12:], value)
 assert(wl.connection_queue(&c.peer, bytes, fds) == .NONE); assert(wl.connection_flush(&c.peer) == .NONE)
}
selection_bind :: proc(c: ^Selection_Client, name: string, version, id: u32) {
 size := 24+(len(name)+4)&~3; bytes := make([]u8, size, context.temp_allocator)
 wl.word_write(bytes,0,2); wl.word_write(bytes,4,u32(size)<<16); wl.word_write(bytes,8,c.globals[name]); wl.word_write(bytes,12,u32(len(name)+1))
 copy(bytes[16:],name); wl.word_write(bytes,size-8,version); wl.word_write(bytes,size-4,id)
 assert(wl.connection_queue(&c.peer,bytes,nil)==.NONE); assert(wl.connection_flush(&c.peer)==.NONE)
}
selection_pump :: proc(c: ^Selection_Client) {
 _, read_err := wl.connection_read(&c.peer); assert(read_err == .NONE || read_err == .EAGAIN)
 for wl.ring_size(&c.peer.input) >= 8 {
  header: [8]u8; wl.ring_copy(&c.peer.input,header[:]); size := int(wl.word_read(header[:],4)>>16)
  if wl.ring_size(&c.peer.input) < size { break }
  bytes := make([]u8,size,context.temp_allocator); wl.ring_copy(&c.peer.input,bytes); c.peer.input.tail += uint(size)
  id, op := wl.word_read(bytes,0),wl.word_read(bytes,4)&0xffff
  if id == 1 && op == 0 { panic(string(bytes)) }
  if id == 2 && op == 0 { n:=wl.word_read(bytes,12); name:=strings.clone(string(bytes[16:16+n-1])); c.globals[name]=wl.word_read(bytes,8) }
  if id == 15 && op == 0 { c.serial=wl.word_read(bytes,8) }
  if id == 7 && op == 0 { selection_words(c,[]u32{7,12<<16|3,wl.word_read(bytes,8)}) }
  if id == 8 && op == 0 {
   selection_words(c,[]u32{8,12<<16|4,wl.word_read(bytes,8)})
   if !c.configured {
    c.configured=true
    selection_words(c,[]u32{6,20<<16|1,12,0,0,6,24<<16|2,0,0,64,48,6,8<<16|6})
   }
  }
  if id == 17 && op == 5 { c.offer=wl.word_read(bytes,8) }
  if id == 19 && op == 1 { c.primary_offer=wl.word_read(bytes,8) }
  if (id == 20 && op == 1) || (id == 21 && op == 0) {
   assert(c.peer.fds_in.head != c.peer.fds_in.tail)
   fd := wl.fd_take(&c.peer.fds_in); flags,_:=linux.fcntl(fd,linux.F_GETFL); assert(linux.fcntl(fd,linux.F_SETFL,flags|{.NONBLOCK})==.NONE)
   append(&c.writes,{fd,0}); c.sends+=1
  }
 }
 if c.hold { return }
 for i:=len(c.writes)-1; i>=0; i-=1 {
  w:=&c.writes[i]; n,err:=linux.write(w.fd,c.payload[w.at:]); if err == .EAGAIN { continue }
  if err == .NONE { w.at+=n }
  if err != .NONE || w.at == len(c.payload) { linux.close(w.fd); ordered_remove(&c.writes,i) }
 }
}
selection_client_close :: proc(c: ^Selection_Client) {
 for w in c.writes { linux.close(w.fd) }; delete(c.writes)
 for name,_ in c.globals { delete(name) }; delete(c.globals); wl.connection_close(&c.peer)
}
selection_client_open :: proc(t: ^testing.T, s: ^Session) -> Selection_Client {
 c: Selection_Client; c.globals=make(map[string]u32)
 fd,err:=linux.socket(.UNIX,.STREAM,{.CLOEXEC},{}); assert(err==.NONE)
 addr: linux.Sock_Addr_Un; addr.sun_family=.UNIX
 path:=fmt.tprintf("%s/runtime/kiln-%d",s.work,s.process.pid); copy(addr.sun_path[:],path)
 assert(linux.connect(fd,&addr)==.NONE); c.peer.fd=fd
 selection_words(&c,[]u32{1,12<<16|1,2})
 for _ in 0..<100 { selection_pump(&c); if len(c.globals)>=26 { break }; time.sleep(10*time.Millisecond) }
 selection_bind(&c,"wl_compositor",4,3); selection_bind(&c,"wl_seat",9,4); selection_bind(&c,"wl_shm",1,5)
 selection_words(&c,[]u32{3,12<<16,6}); selection_bind(&c,"xdg_wm_base",1,7)
 selection_words(&c,[]u32{7,16<<16|2,8,6,8,12<<16|1,9})
 selection_text(&c,9,3,"kiln-selection-test"); selection_text(&c,9,2,"kiln-selection-test")
 // The fixed-size buffer keeps the fixture independent of the layout's configure sizes.
 selection_words(&c,[]u32{9,16<<16|8,64,48,9,16<<16|7,64,48})
 mem,me:=linux.memfd_create("selection-test",{.CLOEXEC}); assert(me==.NONE); assert(linux.ftruncate(mem,64*48*4)==.NONE)
 selection_words(&c,[]u32{5,16<<16,10,64*48*4},[]linux.Fd{mem})
 selection_words(&c,[]u32{1,12<<16,11,10,32<<16,12,0,64,48,256,1})
 selection_words(&c,[]u32{1,12<<16,13,1,12<<16,14,1,12<<16,15})
 selection_bind(&c,"wl_data_device_manager",3,16); selection_words(&c,[]u32{16,16<<16|1,17,4})
 selection_bind(&c,"zwp_primary_selection_device_manager_v1",1,18); selection_words(&c,[]u32{18,16<<16|1,19,4,6,8<<16|6})
 for _ in 0..<200 { selection_pump(&c); if c.configured { break }; time.sleep(10*time.Millisecond) }
 testing.expect(t,c.configured)
 for _ in 0..<20 { selection_pump(&c); time.sleep(10*time.Millisecond) }
 return c
}
selection_client_focus :: proc(c: ^Selection_Client, s: ^Session) {
 eval(s,`for _,c in ipairs(client.all()) do if c.title=='selection-focus' then c:focus() end end`)
 eval(s,`for _,c in ipairs(client.all()) do if c.app_id=='kiln-selection-test' then c:focus() end end`)
 // The focus operation issues a seat serial even without a physical keyboard.
 c.serial=0; selection_words(c,[]u32{1,12<<16,15})
 for _ in 0..<100 { selection_pump(c); if c.serial != 0 { break }; time.sleep(5*time.Millisecond) }
}
selection_client_own :: proc(c: ^Selection_Client, s: ^Session, primary: bool, payload: []u8) {
 selection_client_focus(c,s); c.payload=payload
 id:=u32(21) if primary else 20
 selection_words(c,[]u32{18 if primary else 16,12<<16,id})
 selection_text(c,id,0,"text/plain;charset=utf-8")
 selection_words(c,[]u32{19 if primary else 17,16<<16|(0 if primary else 1),id,c.serial})
 for _ in 0..<10 { selection_pump(c); time.sleep(5*time.Millisecond) }
}
selection_client_read :: proc(c: ^Selection_Client, primary: bool) -> []u8 {
 offer := c.primary_offer if primary else c.offer; if offer==0 { return nil }
 fds:[2]linux.Fd; assert(linux.pipe2(&fds,{.CLOEXEC,.NONBLOCK})==.NONE); defer linux.close(fds[0])
 selection_text(c,offer,0 if primary else 1,"text/plain;charset=utf-8",[]linux.Fd{fds[1]})
 result:=make([dynamic]u8,context.temp_allocator); buffer:[65536]u8
 for _ in 0..<10000 {
  selection_pump(c); n,err:=linux.read(fds[0],buffer[:]); if err==.NONE && n==0 { return result[:] }
  if n>0 { append(&result,..buffer[:n]) }; time.sleep(time.Millisecond)
 }
 assert(false,"selection read timed out"); return nil
}
