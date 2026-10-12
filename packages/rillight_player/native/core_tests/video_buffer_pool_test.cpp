#include "../core/video_buffer_pool.h"
#include <atomic>
#include <cassert>
#include <cstdlib>
#include <thread>

// Observe real allocation/free operations, independent of allocator address
// reuse. The pool uses nothrow array new; container metadata uses scalar new.
static std::atomic<size_t> allocations{0}, live{0};
void* operator new[](size_t bytes, const std::nothrow_t&) noexcept {
  void* memory = std::malloc(bytes);
  if (memory) { ++allocations; ++live; }
  return memory;
}
void operator delete[](void* memory) noexcept {
  if (memory) { --live; std::free(memory); }
}
void operator delete[](void* memory, size_t) noexcept { operator delete[](memory); }

int main() {
  VideoBufferPool pool;
  constexpr size_t large_bytes = 7680u * 4320u * 4u;
  auto* first = pool.Acquire(large_bytes);
  auto* second = pool.Acquire(large_bytes);
  assert(first && second && live == 2);
  pool.Recycle(first, large_bytes);
  pool.Recycle(second, large_bytes);
  assert(live == 1); // A single oversized spare, not zero or two.
  const auto before = allocations.load();
  for (int frame = 0; frame < 20; ++frame) {
    auto* buffer = pool.Acquire(large_bytes);
    assert(buffer);
    buffer[0] = static_cast<uint8_t>(frame);
    pool.Recycle(buffer, large_bytes);
  }
  assert(allocations == before);

  // Switching output dimensions releases the large idle allocation.
  auto* small = pool.Acquire(1024);
  assert(small && live == 1);
  pool.Recycle(small, 1024);
  pool.Release();
  assert(live == 0);

  auto* late = pool.Acquire(large_bytes);
  assert(late);
  pool.Release();
  std::thread renderer([&] { pool.Recycle(late, large_bytes); });
  renderer.join();
  assert(live == 0); // A retired session cannot retain a late returned frame.

  constexpr size_t small_bytes = 1024 * 1024;
  auto* a = pool.Acquire(small_bytes);
  auto* b = pool.Acquire(small_bytes);
  auto* c = pool.Acquire(small_bytes);
  assert(a && b && c);
  pool.Recycle(a, small_bytes); pool.Recycle(b, small_bytes);
  pool.Recycle(c, small_bytes);
  assert(live == 2); // The existing small-buffer count cap remains in force.
  pool.Release();
  assert(live == 0);
}
