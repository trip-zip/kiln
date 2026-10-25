package seat

import "core:testing"

@(test)
confinement_slides_edges_crosses_adjacent_rectangles_and_stops_at_holes :: proc(t: ^testing.T) {
	c:=Constraint{type=1}
	defer delete(c.region)
	append(&c.region,{0,0,10,20})
	dx,dy:=constraint_confine(&c,5,5,20,10)
	testing.expect_value(t,dx,5.0-1.0/256); testing.expect_value(t,dy,f64(10))
	dx,dy=constraint_confine(&c,5,5,-20,10)
	testing.expect_value(t,dx,f64(-5)); testing.expect_value(t,dy,f64(10))
	append(&c.region,{10,10,10,10})
	dx,dy=constraint_confine(&c,5,15,12,0)
	testing.expect_value(t,dx,f64(12)); testing.expect_value(t,dy,f64(0))
	clear(&c.region); append(&c.region,{0,0,10,20},{20,0,10,20})
	dx,dy=constraint_confine(&c,5,5,23,4)
	testing.expect_value(t,dx,5.0-1.0/256); testing.expect_value(t,dy,f64(4))
	dx,dy=constraint_confine(&c,15,5,2,2)
	testing.expect(t,dx==0 && dy==0)
	c.type=0; dx,dy=constraint_confine(&c,5,5,10,10)
	testing.expect(t,dx==0 && dy==0)
}
