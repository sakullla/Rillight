// Shared by every client. Keep transfer chunks small, but coalesce completed
// bytes into 4 MiB disk files (about 512 full blocks for a 2 GiB cache).
const maxCacheBlockBytes = 4 * 1024 * 1024;

// Two publication reservations and one foreground read. Each reservation
// includes the isolate message copy and the worker's media buffer.
const defaultCachePendingBytes = 6 * maxCacheBlockBytes;
