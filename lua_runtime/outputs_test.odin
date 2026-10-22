package lua_runtime

import "core:testing"
import "core:strings"

record_output :: proc(data:rawptr,name:string,change:Output_Change) { (^int)(data)^+=1 }
@(test)
output_validation_precedes_native_calls :: proc(t:^testing.T) {
    calls:int
    r:=Runtime{data=&calls,output_set=record_output}
    testing.expect(t,init(&r))
    defer destroy(&r)
    for expr in ([]string{"set_scale('A',0/0)","set_scale('A',1/0)","set_scale('A',0)","set_scale('A',9)","set_mode('A',0,10)","set_mode('A',10,10,-1)","set_position('A',1e20,0)","set_position('A',1.5,0)","set_enabled('A',0)","set_adaptive_sync('A',nil)"}) {
        source:=strings.concatenate({"core.output.",expr})
        reply:=evaluate(&r,source)
        testing.expect(t,strings.has_prefix(reply,"ERROR:"))
        delete(source);delete(reply)
    }
    testing.expect_value(t,calls,0)
    reply:=evaluate(&r,`return select('#',core.output.set_mode('A',800,600,59940)),select('#',core.output.set_scale('A',1.5)),select('#',core.output.set_position('A',-10,20)),select('#',core.output.set_enabled('A',false)),select('#',core.output.set_adaptive_sync('A',true))`)
    testing.expect_value(t,reply,"0\t0\t0\t0\t0\n")
    delete(reply)
    testing.expect_value(t,calls,5)
}
