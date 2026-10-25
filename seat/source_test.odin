package seat
import wl "../wayland"
import "core:sys/linux"
import "core:testing"

@(test)
external_sources_send_cancel_destroy_and_selection_signals :: proc(t: ^testing.T) {
 display:=wl.create(); defer wl.destroy(display)
 s:=create(display,"source-test")
 for primary in ([]bool{false,true}) {
  source:=source_new(primary); source_offer(source,"text/plain")
  sent,cancelled,destroyed:=false,false,false
  flags:=[3]^bool{&sent,&cancelled,&destroyed}; source.data=&flags
  source.send=proc(s: ^Source,mime: string,fd: wl.Fd) { f:=cast(^[3]^bool)s.data; f[0]^=mime=="text/plain"; linux.write(linux.Fd(fd),[]u8{42}) }
  source.cancel=proc(s: ^Source) { (cast(^[3]^bool)s.data)[1]^=true }
  listener: wl.Listener
  wl.listen(&source.events.destroy,&listener,proc(l: ^wl.Listener,data: rawptr) { source:=cast(^Source)data; (cast(^[3]^bool)source.data)[2]^=true; wl.unlisten(l) })
  selection_set(s,source,wl.next_serial(display),primary)
  fds:[2]linux.Fd; assert(linux.pipe2(&fds,{.CLOEXEC,.NONBLOCK})==.NONE); defer linux.close(fds[0])
  offer:=Offer{source=source,mimes=source.mimes}; offer_receive(&offer,"text/plain",wl.Fd(fds[1]))
  bytes:[1]u8; n,err:=linux.read(fds[0],bytes[:]); testing.expect(t,sent && n==1 && err==.NONE && bytes[0]==42)
  selection_set(s,nil,wl.next_serial(display),primary); testing.expect(t,cancelled)
  source_release(source); testing.expect(t,destroyed)
 }
}
