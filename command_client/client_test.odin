package main

import "core:testing"

@(test)
reply_status_is_root_property :: proc(t:^testing.T) {
    for sample in ([]struct{wire:string,status:int}{
        {`{"result":{"status":"error"},"status":"ok"}`,0},
        {`{"error":"failure","status":"error"}`,1},
        {"ERROR: dispatch missing\n",1},
        {"OK\na\n\nb\n",0},
    }) {
        got,_:=classify(sample.wire,true)
        testing.expect_value(t,got,sample.status)
    }
}

@(test)
request_keeps_both_quoting_layers :: proc(t:^testing.T) {
    got:=request([]string{"eval","return 'x'\n"},false)
    defer delete(got)
    testing.expect_value(t,got,`return kiln_ipc("eval \"return 'x'\n\"")`)
}
