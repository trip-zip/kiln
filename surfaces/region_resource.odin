package surfaces

import rg "../region"
import wl "../wayland"
import p "../protocols"

region_of :: proc(r: ^wl.Resource) -> ^rg.Region { return cast(^rg.Region)r.data if r != nil else nil }
region_create :: proc(client: ^wl.Client, version: i32, id: u32) {
	region := new(rg.Region)
	if wl.resource_create_typed(client,&p.wl_region,version,id,region,region_request,region_destroy) == nil { free(region) }
}
region_destroy :: proc(r: ^wl.Resource) { region := region_of(r); rg.finish(region); free(region) }
region_request :: proc(r: ^wl.Resource, op: p.Wl_Region_Request, args: []wl.Argument) {
	if op == .destroy { wl.resource_destroy(r); return }
	b := rg.Box{i32(args[0].(wl.Int)),i32(args[1].(wl.Int)),i32(args[2].(wl.Int)),i32(args[3].(wl.Int))}
	if op == .add { rg.union_rect(region_of(r),b) } else { rg.subtract_rect(region_of(r),b) }
}
