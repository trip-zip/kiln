#ifndef KILN_PAM_AUTH_H
#define KILN_PAM_AUTH_H

/* Verify a password against the current user via PAM (the "login" service).
 * Returns 1 on success, 0 on failure.
 *
 * Synchronous: it blocks for the PAM call's duration. The retry/backoff UX
 * belongs in Lua rather than
 * PAM's freezing fail-delay. The native lockscreen only calls this while the
 * session is already locked, so a brief main-loop stall leaks nothing.
 *
 * With -Dpam=disabled a build-time stub replaces the real path and accepts a
 * single fixed password, so headless tests can drive the C unlock gate without
 * libpam or a real login. */
int auth_check(const char *password);

#endif /* KILN_PAM_AUTH_H */
