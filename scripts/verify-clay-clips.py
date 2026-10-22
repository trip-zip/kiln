#!/usr/bin/env python3
"""Probe the public Clay clip/hit contract. A mismatch exits 1, blocking clip support."""
from pathlib import Path
import subprocess
import argparse
import json
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r"""
package main
import "core:fmt"
import clay "deps:clay"

has :: proc(name: string, x,y: f32) -> bool {
 clay.SetPointerState({x,y},false)
 ids:=clay.GetPointerOverIds()
 for id in ids.internalArray[:ids.length] {
  if id.id==clay.GetElementId(clay.MakeString(name)).id { return true }
 }
 return false
}
main :: proc() {
 memory:=make([]u8,int(clay.MinMemorySize()))
 defer delete(memory)
 ctx:=clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(len(memory)),raw_data(memory)),{400,300},{})
 clay.SetCurrentContext(ctx)
 clay.BeginLayout()
 if clay.UI(clay.GetElementId(clay.MakeString("root")))({layout={sizing={clay.SizingFixed(400),clay.SizingFixed(300)}}}) {
  if clay.UI(clay.GetElementId(clay.MakeString("horizontal")))({layout={sizing={clay.SizingFixed(40),clay.SizingFixed(20)}},clip={horizontal=true}}) {
   if clay.UI(clay.GetElementId(clay.MakeString("child")))({layout={sizing={clay.SizingFixed(40),clay.SizingFixed(80)}},backgroundColor={255,0,0,255}}) {}
  }
 }
 cmds:=clay.EndLayout(0)
 for c in cmds.internalArray[:cmds.length] { fmt.println(c.commandType,c.boundingBox); if c.commandType==.ScissorStart { fmt.println(c.renderData.clip) } }
 fmt.println("Horizontal-only clip: child at (10,40), expected true, actual",has("child",10,40))
 clay.BeginLayout()
 if clay.UI(clay.GetElementId(clay.MakeString("root")))({layout={sizing={clay.SizingFixed(400),clay.SizingFixed(300)}}}) {
  if clay.UI(clay.GetElementId(clay.MakeString("outer")))({layout={sizing={clay.SizingFixed(20),clay.SizingFixed(20)}},clip={horizontal=true,vertical=true}}) {
   if clay.UI(clay.GetElementId(clay.MakeString("inner")))({layout={sizing={clay.SizingFixed(80),clay.SizingFixed(80)}},clip={horizontal=true,vertical=true}}) {
    if clay.UI(clay.GetElementId(clay.MakeString("child")))({layout={sizing={clay.SizingFixed(80),clay.SizingFixed(80)}},backgroundColor={255,0,0,255}}) {}
   }
  }
 }
 cmds=clay.EndLayout(0)
 for c in cmds.internalArray[:cmds.length] { fmt.println(c.commandType,c.boundingBox); if c.commandType==.ScissorStart { fmt.println(c.renderData.clip) } }
 fmt.println("Nested clips: child at (40,40), expected false, actual",has("child",40,40))
}
"""


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--strict',action='store_true',help='require ideal clipping; inherited failures exit 1')
    args=parser.parse_args()
    pin=json.loads((ROOT/'clay-dependency.json').read_text())
    assert pin['revision']=='e6cc36941ab2af5d81107617039d6f527a1c660b'
    source=json.loads((ROOT/'build/clay/source.json').read_text())
    assert source['revision']==pin['revision'] and source['sha256']==pin['sha256']
    with tempfile.TemporaryDirectory(prefix="kiln-clay-clip-") as tmp:
        work = Path(tmp)
        (work / "main.odin").write_text(SOURCE)
        result = subprocess.run([
            "odin", "run", str(work), "-collection:deps=" + str(ROOT / "build"),
            "-out:" + str(work / "probe")], text=True, capture_output=True, check=True)
        print(result.stdout, end="")
        expected = [
            "Horizontal-only clip: child at (10,40), expected true, actual true",
            "Nested clips: child at (40,40), expected false, actual false",
        ]
        if not args.strict:
            expected=[expected[0].replace('actual true','actual false'),expected[1].replace('actual false','actual true')]
        if not all(line in result.stdout for line in expected):
            raise SystemExit("FAIL: strict clip contract" if args.strict else "FAIL: pinned Clay behavior changed; review rather than widening exceptions")
        if not args.strict: print("INHERITED CLAY LIMITATIONS: horizontal-only visible-child miss; nested outer-clip false positive. Strict probe remains failing.")


if __name__ == "__main__":
    main()
