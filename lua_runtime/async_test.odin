package lua_runtime

import "core:testing"

@(test)
async_callback_failures_reset_poll_atomicity_and_animation :: proc(t: ^testing.T) {
	r:Runtime
	testing.expect(t,init(&r))
	defer destroy(&r)
	reply:=evaluate(&r,#load("async_spec.lua"))
	defer delete(reply)
	testing.expect_value(t,reply,"async policy ok\n")
}
