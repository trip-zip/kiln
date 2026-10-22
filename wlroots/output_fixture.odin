package wlroots

when #config(KILN_OUTPUT_FIXTURE,false) {
    foreign import fixture_lib "system:wlroots-0.20"
    foreign fixture_lib {
        wlr_output_state_set_transform :: proc(state: ^wlr_output_state, transform: i32) ---
        wlr_output_destroy :: proc(output: ^wlr_output) ---
        wlr_output_set_name :: proc(output: ^wlr_output,name: cstring) ---
        wlr_backend_is_headless :: proc(backend: ^wlr_backend) -> bool ---
        wlr_backend_is_x11 :: proc(backend: ^wlr_backend) -> bool ---
        wlr_headless_add_output :: proc(backend: ^wlr_backend,width,height: u32) -> ^wlr_output ---
        wlr_x11_output_create :: proc(backend: ^wlr_backend) -> ^wlr_output ---
        wlr_multi_for_each_backend :: proc(backend: ^wlr_backend,callback: proc "c" (^wlr_backend,rawptr),data: rawptr) ---
    }
}
