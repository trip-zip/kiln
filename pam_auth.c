/* PAM authentication for the native lockscreen. The compositor is the only
 * thing that can flip the unlock gate, and it flips it only when PAM says the
 * password is right, so a rogue rc.lua cannot unlock. One real path plus a
 * build-time test stub, no runtime HAVE_PAM ladder. */

#include "pam_auth.h"

#ifdef KILN_PAM_STUB

#include <string.h>

/* Headless test stub (-Dpam=disabled): one fixed password, no libpam. */
int auth_check(const char *password) {
	return password != NULL && strcmp(password, "kilntest") == 0 ? 1 : 0;
}

#else

#include <security/pam_appl.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <pwd.h>

/* The password for the in-flight PAM conversation. Thread-local so a future
 * off-loop auth cannot cross wires; today the call is synchronous. */
static __thread const char *pam_password = NULL;

/* Answer only password prompts with the stored password; acknowledge info and
 * error messages; refuse anything else. */
static int pam_conversation(int num_msg, const struct pam_message **msg,
		struct pam_response **resp, void *appdata_ptr) {
	(void)appdata_ptr;
	*resp = calloc(num_msg, sizeof(struct pam_response));
	if (*resp == NULL) {
		return PAM_BUF_ERR;
	}
	int i;
	for (i = 0; i < num_msg; i++) {
		switch (msg[i]->msg_style) {
		case PAM_PROMPT_ECHO_OFF:
			(*resp)[i].resp = strdup(pam_password ? pam_password : "");
			if ((*resp)[i].resp == NULL) {
				goto fail;
			}
			break;
		case PAM_PROMPT_ECHO_ON:
			(*resp)[i].resp = strdup("");
			if ((*resp)[i].resp == NULL) {
				goto fail;
			}
			break;
		case PAM_ERROR_MSG:
		case PAM_TEXT_INFO:
			(*resp)[i].resp = NULL;
			break;
		default:
			goto fail;
		}
	}
	return PAM_SUCCESS;

fail:
	for (int j = 0; j < i; j++) {
		free((*resp)[j].resp);
	}
	free(*resp);
	*resp = NULL;
	return PAM_BUF_ERR;
}

/* volatile so the compiler cannot elide the zeroing of the password copy. */
static void secure_clear(char *ptr, size_t len) {
	volatile char *p = (volatile char *)ptr;
	while (len--) {
		*p++ = 0;
	}
}

int auth_check(const char *password) {
	if (password == NULL) {
		return 0;
	}
	/* Copy so we can zero it after: the caller's pointer references LuaJIT's
	 * interned string, which must not be written to. */
	size_t len = strlen(password);
	char *pw_copy = malloc(len + 1);
	if (pw_copy == NULL) {
		return 0;
	}
	memcpy(pw_copy, password, len + 1);

	struct passwd *pw = getpwuid(getuid());
	if (pw == NULL || pw->pw_name == NULL) {
		secure_clear(pw_copy, len);
		free(pw_copy);
		return 0;
	}

	pam_password = pw_copy;
	struct pam_conv conv = { pam_conversation, NULL };
	pam_handle_t *pamh = NULL;
	int ret = pam_start("login", pw->pw_name, &conv, &pamh);
	if (ret != PAM_SUCCESS) {
		pam_password = NULL;
		secure_clear(pw_copy, len);
		free(pw_copy);
		return 0;
	}

	ret = pam_authenticate(pamh, 0);

	pam_end(pamh, ret);
	pam_password = NULL;
	secure_clear(pw_copy, len);
	free(pw_copy);

	return ret == PAM_SUCCESS ? 1 : 0;
}

#endif /* KILN_PAM_STUB */
