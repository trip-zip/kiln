package lua_runtime

import "core:testing"
import "../keymap"

@(test)
model_signals_membership_and_lifetime :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, #load("model_spec.lua"))
	defer delete(reply)
	testing.expect_value(t, reply, "model ok\n")
}

@(test)
event_payloads_preserve_optional_fields :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, "events={};core.set_event_handler(function(e) events[#events+1]=e end)")
	delete(reply)
	events := []Event{
		{class="output",name="add",output="TEST"},
		{name="metadata",handle=9,title="new",has_title=true},
		{name="commit_size",handle=9,width=100,height=200},
		{name="request::fullscreen",handle=9,on=false},
		{class="input",name="key",keysym=97,key="a",utf8="a",pressed=true,mods=77},
		{class="input",name="key",key="a",pressed=false},
		{class="input",name="motion",px=12.5,py=40,output="TEST",has_output=true,handle=9},
		{class="input",name="button",button=272,pressed=true},
		{class="input",name="axis",dx=1.5,dy=-2,mods=4},
		{class="input",name="pointer_enter"},
	}
	for &event in events { testing.expect(t, deliver(&r, &event)) }
	reply = evaluate(&r, `local e=events
assert(e[1].class=='output' and e[1].output=='TEST' and e[1].handle==nil)
assert(e[2].title=='new' and e[2].app_id==nil and e[2].width==nil)
assert(e[3].width==100 and e[3].height==200 and e[3].title==nil)
assert(e[4].on==false and e[4].handle==9)
assert(e[5].keysym==97 and e[5].key=='a' and e[5].utf8=='a' and e[5].pressed)
assert(e[5].mods.shift and e[5].mods.ctrl and e[5].mods.alt and e[5].mods.super)
assert(e[6].utf8=='' and not e[6].pressed and not e[6].mods.shift)
assert(e[7].x==12.5 and e[7].screen=='TEST' and e[7].client==9 and e[7].mods==nil)
assert(e[8].button==272 and e[8].pressed and e[8].screen==nil and e[8].client==nil)
assert(e[9].dx==1.5 and e[9].dy==-2 and e[9].mods.ctrl)
assert(e[10].handle==nil)
collectgarbage('collect');return #e`)
	defer delete(reply)
	testing.expect_value(t, reply, "10\n")
}

@(test)
bindings_rules_actions_and_focus_policy :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, #load("policy_spec.lua"))
	defer delete(reply)
	testing.expect_value(t, reply, "policy ok\n")
}

@(test)
consume_registry_replacement_is_atomic :: proc(t: ^testing.T) {
	r: Runtime
	testing.expect(t, init(&r))
	defer destroy(&r)
	reply := evaluate(&r, `core.set_key_bindings{{mods={'super'},key='a'}}
assert(not pcall(core.set_key_bindings,{{key='b'},{key='not-a-key'}}))
assert(not pcall(core.set_key_bindings,{setmetatable({}, {__index=function() error('metatable') end})}))
for _,f in ipairs{core.client.close,core.client.kill} do
 for _,v in ipairs{0,-1,0.5,0/0,1/0,4294967296,false,{}} do assert(not pcall(f,v)) end
 assert(not pcall(f,nil));f(4294967295)
end
return 'atomic'`)
	defer delete(reply)
	testing.expect_value(t, reply, "atomic\n")
	testing.expect_value(t, len(r.bindings), 1)
	testing.expect(t, keymap.bound(r.bindings, 97, 64))
}

@(test)
input_properties_claims_and_geometry :: proc(t: ^testing.T) {
	r:Runtime
	testing.expect(t,init(&r))
	defer destroy(&r)
	reply:=evaluate(&r,#load("input_spec.lua"))
	defer delete(reply)
	testing.expect_value(t,reply,"input policy ok\n")
}
