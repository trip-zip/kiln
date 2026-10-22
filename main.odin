package main

import "core:fmt"
import "core:os"
import "compositor"
import "authentication"

main :: proc() {
    if len(os.args)==2 && os.args[1]=="--auth-worker" { os.exit(int(authentication.worker_main())) }
	command := ""
	if len(os.args) == 3 && os.args[1] == "-s" {
		command = os.args[2]
	} else if len(os.args) != 1 {
		fmt.println("Usage: kiln [-s command]\nAlt+Escape quits. IPC: $KILN_SOCK or $XDG_RUNTIME_DIR/kiln.sock.")
		if len(os.args) == 2 && os.args[1] == "-h" { return }
		os.exit(2)
	}
	if !compositor.run(command) {
		fmt.eprintln("Compositor failed")
		os.exit(1)
	}
}
