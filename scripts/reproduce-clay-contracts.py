#!/usr/bin/env python3
"""Strict ideal-contract probes, compiled only in scratch, against both Clay versions."""
import c_baseline
from pathlib import Path
import hashlib
import re
import argparse
import json
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
SOURCE=r'''
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#undef assert
#define assert(value) printf("%d %s\n", !!(value), #value)
static int callbacks;
static void hover(Clay_ElementId id, Clay_PointerData pointer, void *data) {
    (void)id; (void)pointer; (void)data; callbacks++;
}
static bool has(Clay_ElementId id) {
    Clay_ElementIdArray ids = Clay_GetPointerOverIds();
    for (int i = 0; i < ids.length; i++) if (ids.internalArray[i].id == id.id) return true;
    return false;
}
static void point(float x, float y, bool child) {
    printf("POINT %g %g ideal=%d\n",x,y,child);
    callbacks = 0;
    Clay_SetPointerState((Clay_Vector2){x,y}, false);
    assert(has(CLAY_ID("child")) == child);
    assert(callbacks == (child ? 1 : 0));
}
static Clay_RenderCommandArray declare(bool horizontal, bool vertical, bool nested, bool mixed, bool empty, float offset) {
    printf("CLIP h=%d v=%d nested=%d mixed=%d empty=%d offset=%g\n",horizontal,vertical,nested,mixed,empty,offset);
    Clay_BeginLayout();
    CLAY(CLAY_ID("root"), {.layout = {.sizing = {CLAY_SIZING_FIXED(300), CLAY_SIZING_FIXED(240)}, .padding = {30,0,40,0}}}) {
        CLAY(CLAY_ID("outer"), {.layout = {.sizing = {CLAY_SIZING_FIXED(40), CLAY_SIZING_FIXED(20)}},
                .clip = {.horizontal=horizontal, .vertical=vertical, .childOffset={offset,0}}}) {
            CLAY(CLAY_ID("inner"), {.layout = {.sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(80)}},
                    .clip = {.horizontal=nested && !mixed, .vertical=nested}}) {
                CLAY(CLAY_ID("child"), {.layout = {.sizing = {CLAY_SIZING_FIXED(80), CLAY_SIZING_FIXED(80)}}, .backgroundColor={255,0,0,255}}) {
                    Clay_OnHover(hover, NULL);
                }
            }
        }
        if (empty) {
            CLAY(CLAY_ID("zero"), {.layout={.sizing={CLAY_SIZING_PERCENT(0),CLAY_SIZING_FIXED(20)}}, .clip={.horizontal=true}}) {
                CLAY(CLAY_ID("zero-child"), {.layout={.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(80)}}}) {}
            }
        }
    }
    return Clay_EndLayout(0);
}
static void floats(bool inherited, bool pass, float offset) {
    printf("FLOAT inherited=%d pass=%d offset=%g\n",inherited,pass,offset);
    Clay_BeginLayout();
    CLAY(CLAY_ID("root"), {.layout={.sizing={CLAY_SIZING_FIXED(300),CLAY_SIZING_FIXED(240)}}}) {
        CLAY(CLAY_ID("lower"), {.layout={.sizing={CLAY_SIZING_FIXED(200),CLAY_SIZING_FIXED(200)}}, .backgroundColor={0,0,255,255}}) {
            CLAY(CLAY_ID("outer"), {.layout={.sizing={CLAY_SIZING_FIXED(20),CLAY_SIZING_FIXED(20)}}, .clip={.horizontal=true,.vertical=true}}) {
                CLAY(CLAY_ID("inner"), {.layout={.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(80)}}, .clip={.horizontal=true,.vertical=true}}) {
                    CLAY(CLAY_ID("float"), {.layout={.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(80)}},
                        .floating={.attachTo=CLAY_ATTACH_TO_PARENT, .clipTo=inherited ? CLAY_CLIP_TO_ATTACHED_PARENT : CLAY_CLIP_TO_NONE,
                        .pointerCaptureMode=pass ? CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH : CLAY_POINTER_CAPTURE_MODE_CAPTURE,
                        .offset={offset,offset}, .zIndex=10}}) {
                        CLAY(CLAY_ID("child"), {.layout={.sizing={CLAY_SIZING_FIXED(80),CLAY_SIZING_FIXED(80)}}}) { Clay_OnHover(hover,NULL); }
                    }
                }
            }
        }
    }
    Clay_RenderCommandArray commands=Clay_EndLayout(0);
    if (inherited) {
        bool found=false;
        for (int i=0;i<commands.length;i++) {
            Clay_RenderCommand c=commands.internalArray[i];
            if(c.commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_START && c.zIndex==10) {
                assert(c.renderData.clip.horizontal && c.renderData.clip.vertical);
                assert(c.boundingBox.width==20 && c.boundingBox.height==20); found=true;
            }
        }
        assert(found);
    }
    point(50,50,!inherited);
    assert(has(CLAY_ID("lower")) == (inherited || pass));
    point(10,10,offset==0);
    assert(has(CLAY_ID("lower")) == (pass || offset!=0));
    if (pass && !inherited) {
        Clay_SetPointerState((Clay_Vector2){50,50},false);
        Clay_ElementIdArray ids=Clay_GetPointerOverIds();
        assert(ids.internalArray[0].id==CLAY_ID("float").id);
        assert(ids.internalArray[1].id==CLAY_ID("child").id);
    }
}
static void offscreen(bool cull) {
    printf("OFFSCREEN culling=%d\n",cull);
    Clay_SetCullingEnabled(cull);
    Clay_BeginLayout();
    CLAY(CLAY_ID("root"), {.layout={.sizing={CLAY_SIZING_FIXED(300),CLAY_SIZING_FIXED(240)}}}) {
        CLAY(CLAY_ID("offclip"), {.layout={.sizing={CLAY_SIZING_FIXED(20),CLAY_SIZING_FIXED(20)}},
          .floating={.attachTo=CLAY_ATTACH_TO_ROOT,.offset={-100,-100}},.clip={true,true}}) {
            CLAY(CLAY_ID("visible-float"), {.layout={.sizing={CLAY_SIZING_FIXED(30),CLAY_SIZING_FIXED(30)}},
              .floating={.attachTo=CLAY_ATTACH_TO_PARENT,.clipTo=CLAY_CLIP_TO_ATTACHED_PARENT,.offset={110,110},.zIndex=10},.backgroundColor={255,0,0,255}}) {}
        }
    }
    Clay_RenderCommandArray commands=Clay_EndLayout(0);
    int starts=0,ends=0,children=0;
    for(int i=0;i<commands.length;i++) {
        Clay_RenderCommand c=commands.internalArray[i];
        starts+=c.commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_START;
        ends+=c.commandType==CLAY_RENDER_COMMAND_TYPE_SCISSOR_END;
        children+=c.id==CLAY_ID("visible-float").id;
    }
    assert(starts==ends);
    printf("COMMANDS starts=%d ends=%d children=%d\n",starts,ends,children);
    assert(children==0 || starts>=2);
    Clay_SetCullingEnabled(true);
}
int main(void) {
    uint32_t size=Clay_MinMemorySize();
    void *a=malloc(size), *b=malloc(size);
    Clay_Context *one=Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size,a),(Clay_Dimensions){400,300},(Clay_ErrorHandler){0});
    declare(true,false,false,false,false,0); point(40,80,true); point(90,50,false);
    callbacks=0; Clay_SetPointerState((Clay_Vector2){40,50},false); assert(has(CLAY_ID("outer")));
    declare(false,true,false,false,false,0); point(90,50,true); point(40,80,false);
    declare(true,true,true,false,false,0); point(40,50,true); point(90,90,false);
    declare(true,false,true,true,false,0); point(40,90,true); point(90,50,false); point(40,130,false);
    declare(false,false,false,false,false,0); point(90,90,true);
    declare(true,true,false,false,false,-60); point(40,50,true); point(60,50,false);
    declare(true,true,true,false,false,60); point(95,50,false);
    declare(false,false,false,false,true,0); Clay_SetPointerState((Clay_Vector2){70,45},false); assert(!has(CLAY_ID("zero-child")));
    for(int inherited=0;inherited<2;inherited++) for(int pass=0;pass<2;pass++) {
        floats(inherited,pass,0); floats(inherited,pass,30);
    }
    Clay_Context *two=Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size,b),(Clay_Dimensions){400,300},(Clay_ErrorHandler){0});
    declare(true,false,false,false,false,0); point(40,80,true);
    Clay_SetCurrentContext(one); point(50,50,false);
    Clay_SetCurrentContext(two); point(40,80,true);
    offscreen(true);offscreen(false);
    Clay_SetCurrentContext(NULL); free(a);free(b);

}
'''

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--known-limitations",action="store_true")
    parser.add_argument("--clay-root",type=Path,default=Path.home()/"tools/clay")
    args=parser.parse_args()
    out=Path(tempfile.mkdtemp(prefix='kiln-clay-contracts-',dir='/tmp'));print(out,flush=True)
    records={}
    for name,header in [('upstream',args.clay_root/'clay.h'),('c-kiln',c_baseline.source()/'third_party/clay.h')]:
        folder=out/name;folder.mkdir()
        (folder/'clay.h').write_bytes(header.read_bytes())
        source=SOURCE.replace('Clay_EndLayout(0)','Clay_EndLayout()') if name=='c-kiln' else SOURCE
        if name=='c-kiln':
            source=re.sub(r'CLAY\((CLAY_ID\("[^"]+"\)),\s*\{',r'CLAY({.id=\1,',source)
            source=source.replace('void *data','intptr_t data').replace('hover, NULL','hover, 0').replace('hover,NULL','hover,0')
        (folder/'probe.c').write_text(source)
        subprocess.run(['gcc','-std=c11','-O0',str(folder/'probe.c'),'-lm','-o',str(folder/'probe')],check=True)
        result=subprocess.run([str(folder/'probe')],capture_output=True,text=True,check=True)
        (folder/'result.txt').write_text(result.stdout)
        records[name]=dict(header=str(header),sha256=hashlib.sha256(header.read_bytes()).hexdigest(),checks=result.stdout.splitlines())
    (out/'comparison.json').write_text(json.dumps(records,indent=2)+'\n')
    a,b=records['upstream']['checks'],records['c-kiln']['checks']
    assert len(a)==len(b),(len(a),len(b))
    for i,(x,y) in enumerate(zip(a,b)):
        if x.startswith('0') or y.startswith('0'):print(i,'upstream:',x,'C:',y)
    print('strict failures:',sum(x.startswith('0') for x in a),sum(x.startswith('0') for x in b))
    if args.known_limitations:
        expected=json.loads((ROOT/'scripts/clay-contract-baseline.json').read_text())
        for key in records:
            assert records[key]['sha256']==expected[key]['sha256'],'header provenance changed'
            assert records[key]['checks']==expected[key]['checks'],'Clay contract behavior changed; inspect strict receipts'
        print('PASS: exact inherited contract fingerprint; all other assertions stay required')
    else:raise SystemExit(1 if any(x.startswith('0') for x in a+b) else 0)
if __name__=='__main__':main()
