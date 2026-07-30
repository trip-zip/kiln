#define CLAY_IMPLEMENTATION
#include "clay.h"

#include "core.h"

/* Clay_Context is defined only inside CLAY_IMPLEMENTATION, so the depth of
 * Clay's open-element stack is readable in this translation unit and nowhere
 * else in kiln. With the declare verbs on the Lua side C never counts
 * opens, and this is what core_declare_ref rebalances against when a handler
 * leaves elements open. Called only between Clay_BeginLayout and Clay_EndLayout,
 * where a current context is guaranteed. */
int kiln_clay_open_depth(void) {
	return Clay_GetCurrentContext()->openLayoutElementStack.length;
}
