package paint

import "core:fmt"
import "core:testing"

@(test)
fonts_parse_intern_measure_and_release :: proc(t: ^testing.T) {
	f: Fonts
	defer destroy_fonts(&f)
	testing.expect_value(t,intern_font(&f,"Sans"),0)
	testing.expect_value(t,intern_font(&f,"Sans\x00 14"),0)
	bold := intern_font(&f,"Sans Bold")
	testing.expect(t,bold>0)
	testing.expect_value(t,intern_font(&f,"Sans Bold"),bold)
	for name in ([]string{"Sans Bold 14","Sans 14px","Sans 12.5"}) { testing.expect_value(t,intern_font(&f,name),-1) }
	testing.expect(t,intern_font(&f,"NoSuchFamilyXYZ")>0)
	m: Measurer
	testing.expect(t,init_measurer(&m))
	defer destroy_measurer(&m)
	text :: "Handgloves WWW iii 0123456789"
	w,h := measure(&m,&f,text,0,18)
	bw,bh := measure(&m,&f,text,u16(bold),18)
	testing.expect(t,bw>w && bh>0 && h>0)
	unknown,uh := measure(&m,&f,text,65535,18)
	testing.expect_value(t,unknown,w)
	testing.expect_value(t,uh,h)
	for _ in 0..<10 {
		measure(&m,&f,"large",u16(bold),36)
		actual,ah := measure(&m,&f,text,0,18)
		testing.expect_value(t,actual,w)
		testing.expect_value(t,ah,h)
	}
	empty,_ := measure(&m,&f,"",0,16)
	testing.expect_value(t,empty,0)
	utf,utfh := measure(&m,&f,"Héllo λ 世界",0,18)
	testing.expect(t,utf>0 && utfh>0)
	for i in 0..<61 {
		name := fmt.aprintf("MissingFamily%d",i)
		id := intern_font(&f,name)
		delete(name)
		testing.expect(t,id>=0)
	}
	testing.expect_value(t,len(f.entries),64)
	testing.expect_value(t,intern_font(&f,"FullTableFamily"),-2)
	testing.expect_value(t,intern_font(&f,"Sans 14"),-1)
	testing.expect_value(t,intern_font(&f,"Sans Bold"),bold)
}

@(test)
premultiplied_ring_and_allocation_failure :: proc(t: ^testing.T) {
	s,ok := create(40,40)
	testing.expect(t,ok)
	defer destroy(s)
	testing.expect(t,shape(s,{1,0.5,0,0.5},{20,20,20,20},40,40,0,0,true,{3,3,3,3}))
	testing.expect_value(t,alpha(s,2,2),0)
	testing.expect_value(t,alpha(s,20,20),0)
	testing.expect_value(t,alpha(s,20,8),0)
	testing.expect(t,alpha(s,20,1)>=127 && alpha(s,20,1)<=128)
	pixel := (cast([^]u32)data(s))[40+20]
	testing.expect(t,(pixel>>16)&255>=127 && (pixel>>16)&255<=128)
	testing.expect(t,(pixel>>8)&255>=63 && (pixel>>8)&255<=65)
	_,ok = create(1000000000,1000000000)
	testing.expect(t,!ok)
	_,ok = create(0,10)
	testing.expect(t,!ok)
}
