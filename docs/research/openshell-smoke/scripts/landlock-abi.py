import ctypes, os
libc = ctypes.CDLL(None, use_errno=True)
# SYS_landlock_create_ruleset = 444 on x86_64; flag LANDLOCK_CREATE_RULESET_VERSION = 1<<0
r = libc.syscall(444, None, 0, 1)
print("uname:", os.uname().release, "| landlock ABI:", r if r >= 0 else f"ERR errno={ctypes.get_errno()} ({os.strerror(ctypes.get_errno())})")
