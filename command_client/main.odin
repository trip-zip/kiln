package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

usage :: `Usage: kiln-client [OPTIONS] COMMAND [ARGS...]

  --json                 reply as one JSON object
  -s, --socket PATH       address a specific instance (else $KILN_SOCK)
  -h, --help              this text

Run kiln-client help for live verbs and kiln-client reflect [CLASS] for
methods and properties. get/set/call take a class, selector and member.
Selectors include focused, all, previous, names, handles and field:pattern.
An unquoted @class:selector argument resolves to an object.
`

append_arg :: proc(b: ^strings.Builder, arg: string) {
    quoted := len(arg)==0
    for ch in transmute([]u8)arg {
        if strings.index_byte(" \t\n\r\v\f\"'\\",ch)>=0 { quoted=true;break }
    }
    if !quoted { strings.write_string(b,arg);return }
    strings.write_byte(b,'"')
    for ch in transmute([]u8)arg {
        if ch=='"' || ch=='\\' { strings.write_byte(b,'\\') }
        strings.write_byte(b,ch)
    }
    strings.write_byte(b,'"')
}
request :: proc(args: []string, as_json: bool) -> string {
    cmd: strings.Builder
    defer strings.builder_destroy(&cmd)
    if as_json { strings.write_string(&cmd,"--json ") }
    for arg,i in args {
        if i>0 { strings.write_byte(&cmd,' ') }
        append_arg(&cmd,arg)
    }
    out: strings.Builder
    strings.write_string(&out,"return kiln_ipc(\"")
    for ch in transmute([]u8)strings.to_string(cmd) {
        switch ch {
        case '"','\\': strings.write_byte(&out,'\\');strings.write_byte(&out,ch)
        case '\n': strings.write_string(&out,"\\n")
        case '\r': strings.write_string(&out,"\\r")
        case:
            if ch<32 || ch==127 { fmt.sbprintf(&out,"\\%03d",ch) }
            else { strings.write_byte(&out,ch) }
        }
    }
    strings.write_string(&out,"\")")
    return strings.to_string(out)
}

// The caller owns the returned bytes; EOF, not a newline, frames the reply.
exchange :: proc(path, body: string) -> (string, bool) {
    if len(path)==0 || len(path)>=108 || strings.index_byte(path,0)>=0 {
        fmt.eprintln("kiln-client: invalid socket path (empty or longer than 107 bytes)")
        return "",false
    }
    fd:=posix.socket(.UNIX,.STREAM)
    if fd<0 { fmt.eprintln("kiln-client: socket:",posix.errno());return "",false }
    defer posix.close(fd)
    posix.fcntl(fd,.SETFD,posix.FD_CLOEXEC)
    address:posix.sockaddr_un
    address.sun_family=.UNIX
    copy(address.sun_path[:],path)
    for posix.connect(fd,cast(^posix.sockaddr)&address,size_of(address))!=.OK {
        if posix.errno()==.EINTR { continue }
        fmt.eprintf("kiln-client: cannot connect to %s: %v\n",path,posix.errno())
        fmt.eprintln("kiln-client: is kiln running? (set KILN_SOCK to address another instance)")
        return "",false
    }
    sent:=0
    for sent<len(body) {
        n:=posix.send(fd,raw_data(body[sent:]),c.size_t(int(len(body))-sent),{.NOSIGNAL})
        if n>0 { sent+=int(n) }
        else if n<0 && posix.errno()==.EINTR { continue }
        else { fmt.eprintln("kiln-client: write:",posix.errno());return "",false }
    }
    for posix.shutdown(fd,.WR)!=.OK {
        if posix.errno()==.EINTR { continue }
        fmt.eprintln("kiln-client: shutdown:",posix.errno());return "",false
    }
    reply:strings.Builder
    defer strings.builder_destroy(&reply)
    chunk:[4096]u8
    for {
        n:=posix.read(fd,raw_data(chunk[:]),len(chunk))
        if n>0 { strings.write_bytes(&reply,chunk[:int(n)]) }
        else if n==0 { break }
        else if posix.errno()==.EINTR { continue }
        else { fmt.eprintln("kiln-client: read:",posix.errno());return "",false }
    }
    if strings.builder_len(reply)==0 { fmt.eprintln("kiln-client: empty reply");return "",false }
    return strings.clone(strings.to_string(reply)),true
}

classify :: proc(reply: string, as_json: bool) -> (status: int, payload: string) {
    if as_json {
        value,err:=json.parse(reply)
        defer json.destroy_value(value)
        if err==.None {
            if object,ok:=value.(json.Object);ok {
                if status,is_string:=object["status"].(string);is_string {
                    if status=="ok" { return 0,reply }
                    if status=="error" { return 1,reply }
                }
            }
        }
    }
    if strings.has_prefix(reply,"OK\n") { return 0,reply[3:] }
    return 1,reply
}

run :: proc(args: []string) -> int {
    as_json:=false
    path:=os.get_env("KILN_SOCK",context.allocator)
    defer delete(path)
    explicit:=false
    i:=0
    options: for i<len(args) {
        switch args[i] {
        case "--json": as_json=true;i+=1
        case "-h","--help": fmt.print(usage);return 0
        case "-s","--socket":
            if i+1>=len(args) { fmt.eprintln("kiln-client: --socket needs a path");return 2 }
            explicit=true;delete(path);path=strings.clone(args[i+1]);i+=2
        case: break options
        }
    }
    if i>=len(args) { fmt.eprint(usage);return 2 }
    if path=="" && !explicit {
        dir,found:=os.lookup_env("XDG_RUNTIME_DIR",context.allocator)
        defer delete(dir)
        delete(path);path=fmt.aprintf("%s/kiln.sock",dir if found else "/tmp")
    }
    body:=request(args[i:],as_json)
    defer delete(body)
    reply,ok:=exchange(path,body)
    defer delete(reply)
    if !ok { return 2 }
    status,payload:=classify(reply,as_json)
    if status==0 { fmt.print(payload) } else { fmt.eprint(payload) }
    return status
}
main :: proc() { os.exit(run(os.args[1:])) }
