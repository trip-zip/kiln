package seat

import wl "../wayland"
import p "../protocols"

primary_selection_manager_create :: proc(display: ^wl.Display) -> ^Data_Manager {
	m := new(Data_Manager); m.primary = true
	m.global = wl.global_create_typed(display, &p.zwp_primary_selection_device_manager_v1, 1, m, primary_manager_request, data_manager_release, data_manager_bound)
	if m.global == nil { free(m); return nil }
	wl.listen(&display.destroy_signal, &m.destroy, data_manager_destroy)
	return m
}
primary_manager_request :: proc(r: ^wl.Resource, request: p.Zwp_Primary_Selection_Device_Manager_V1_Request, args: []wl.Argument) {
	switch request {
	case .destroy: wl.resource_destroy(r)
	case .create_source: source_create(cast(^Data_Manager)r.data, r, u32(args[0].(wl.New_Id)))
	case .get_device: device_create(cast(^Data_Manager)r.data, r, u32(args[0].(wl.New_Id)), client_of(wl.object(args[1])))
	}
}
primary_source_request :: proc(r: ^wl.Resource, request: p.Zwp_Primary_Selection_Source_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r); case .offer: source_offer(cast(^Source)r.data, args[0].(wl.String).value) }
}
primary_device_request :: proc(r: ^wl.Resource, request: p.Zwp_Primary_Selection_Device_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r); case .set_selection: selection_request(cast(^Device)r.data, source_of(wl.object(args[0])), u32(args[1].(wl.Uint))) }
}
primary_offer_request :: proc(r: ^wl.Resource, request: p.Zwp_Primary_Selection_Offer_V1_Request, args: []wl.Argument) {
	switch request { case .destroy: wl.resource_destroy(r); case .receive: offer_receive(cast(^Offer)r.data, args[0].(wl.String).value, args[1].(wl.Fd)) }
}
