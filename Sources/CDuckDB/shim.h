// The official libduckdb C API (duckdb.h), found through pkg-config (`duckdb.pc`). BackendKit does not carry a copy of
// the header or of the library: Scripts/install-libduckdb.sh installs the pinned, checksum-verified release.
#if __has_include(<duckdb.h>)
#include <duckdb.h>
#else
#error "duckdb.h not found: install libduckdb with Scripts/install-libduckdb.sh and point PKG_CONFIG_PATH at <prefix>/lib/pkgconfig (see README, 'DuckDB on Linux')."
#endif
