Upstream: https://github.com/adegtyarev/streebog
Commit: 62e2120042fae0bb19381a8acb1b8dc425b761f7
License selected: BSD-2-Clause (LICENSE).
Portable C core/headers copied from upstream. Local config selects portable implementation;
Bridge.c exposes a one-shot function. The core initializes one temporary union to zero
to satisfy Clang's strict Release warning; the value is overwritten by XLPS before use.
Digest encoding: bytes returned by upstream Final, lowercase hexadecimal (conventional file digest order).
