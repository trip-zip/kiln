package input_config
import "core:testing"
@(test)
source_string_mappings :: proc(t: ^testing.T) {
	testing.expect_value(t,profile("flat"),1)
	testing.expect_value(t,profile("other"),2)
	testing.expect_value(t,scroll("two_finger"),1)
	testing.expect_value(t,scroll("edge"),2)
	testing.expect_value(t,scroll("button"),4)
	testing.expect_value(t,scroll("other"),0)
	testing.expect_value(t,click("button_areas"),1)
	testing.expect_value(t,click("clickfinger"),2)
	testing.expect_value(t,click("other"),0)
}
