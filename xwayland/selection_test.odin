package xwayland
import "core:testing"
@(test)
selection_mime_translation_matches_x_text_and_mime_atoms :: proc(t: ^testing.T) {
 for pair in ([][2]string{{"UTF8_STRING","text/plain;charset=utf-8"},{"TEXT","text/plain"},{"text/uri-list","text/uri-list"},{"image/png","image/png"},{"application/octet-stream","application/octet-stream"}}) {
  testing.expect_value(t,mime_from_name(pair[0]),pair[1]); testing.expect_value(t,mime_to_name(pair[1]),pair[0])
 }
 for name in ([]string{"STRING","COMPOUND_TEXT","TARGETS","TIMESTAMP","DELETE","INCR",""}) { testing.expect_value(t,mime_from_name(name),"") }
}
