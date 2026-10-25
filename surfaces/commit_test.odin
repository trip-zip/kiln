package surfaces

import rg "../region"
import wl "../wayland"
import "core:testing"

@(test)
commit_sizes_and_damage_follow_transform_scale_and_viewport :: proc(t: ^testing.T) {
	s: Surface; state_init(&s.current); state_init(&s.pending)
	defer state_finish(&s.current); defer state_finish(&s.pending); defer rg.finish(&s.buffer_damage)
	s.pending.buffer_width,s.pending.buffer_height,s.pending.scale,s.pending.transform = 80,120,2,1
	finalize(&s)
	testing.expect(t,s.pending.width==60 && s.pending.height==40)
	s.pending.viewport = {has_src=true,src={3.5,4.25,20,10},has_dst=true,dst_width=40,dst_height=20}
	rg.union_rect(&s.pending.surface_damage,{2,4,6,8})
	rg.union_rect(&s.pending.buffer_damage,{-10,-10,12,12})
	finalize(&s)
	testing.expect(t,s.pending.width==40 && s.pending.height==20)
	update_damage(&s.buffer_damage,&s.pending)
	want: rg.Region; defer rg.finish(&want)
	rg.union_rect(&want,{12,106,8,6}); rg.union_rect(&want,{0,0,2,2})
	for y in 0..<120 { for x in 0..<80 { testing.expect_value(t,rg.contains_point(&s.buffer_damage,i32(x),i32(y)),rg.contains_point(&want,i32(x),i32(y))) } }
	s.current.buffer_width,s.current.buffer_height,s.current.scale,s.current.transform,s.current.viewport = 80,120,2,1,s.pending.viewport
	testing.expect_value(t,source_box(&s),Fbox{8.5,73,20,40})
	s.pending.viewport.has_dst = false; finalize(&s)
	testing.expect(t,s.pending.width==20 && s.pending.height==10)
	s.pending.buffer_width,s.pending.buffer_height = 0,0; finalize(&s)
	testing.expect(t,s.pending.width==0 && s.pending.height==0)
}
@(test)
cache_locks_preserve_commit_order_and_effective_state :: proc(t: ^testing.T) {
	s: Surface; state_init(&s.current); state_init(&s.pending)
	defer state_finish(&s.current); defer state_finish(&s.pending); defer delete(s.cached)
	defer rg.finish(&s.buffer_damage); defer rg.finish(&s.input_region); defer rg.finish(&s.opaque_region)
	for signal in ([]^wl.Signal{&s.events.commit,&s.events.unmap}) { wl.signal_init(signal) }
	s.pending.seq = 4
	first,second := new(State),new(State); state_init(first); state_init(second)
	first.seq,first.locks,first.scale,first.committed = 2,1,2,{.Scale}
	second.seq,second.locks,second.scale = 3,1,2
	first.width,second.width = 10,20
	append(&s.cached,first,second)
	unlock_cached(&s,3)
	testing.expect(t,s.current.seq==0 && len(s.cached)==2)
	unlock_cached(&s,2)
	testing.expect(t,s.current.seq==3 && s.current.width==20 && s.current.scale==2 && len(s.cached)==0)
	seq := lock_pending(&s); unlock_cached(&s,seq)
	testing.expect_value(t,s.pending.locks,0)
}
