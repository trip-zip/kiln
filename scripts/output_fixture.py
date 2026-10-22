"""Compile the private Odin backend fixture, absent from ordinary builds."""
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
LUA="""
local ffi=require('ffi')
ffi.cdef[[int64_t kiln_test_resource(int kind);bool kiln_test_output(int action,const char *name,int a,int b);]]
function resource_fixture(kind) return tonumber(ffi.C.kiln_test_resource(kind)) end
function output_fixture(action,name,a,b) return ffi.C.kiln_test_output(action,name,a or 0,b or 0) end
"""

def harness(h):
    binary=h.out/'kiln-output-fixture'
    subprocess.run(['odin','build','.', '-collection:deps=build','-define:KILN_OUTPUT_FIXTURE=true', '-out:'+str(binary),'-extra-linker-flags:-Wl,--export-dynamic'],cwd=ROOT,check=True,timeout=60)
    return type(h)(binary.resolve(),h.original,h.out)
