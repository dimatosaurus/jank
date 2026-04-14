#include "cpplib.hpp"

// Force the symbols into the library even under LTO / dead-stripping.
// This is only needed because we build a static archive that the JIT
// links at runtime.
namespace cpplib
{
  long (*volatile fib_ptr)(long) = &fib;
  const char *(*volatile greeting_ptr)() = &greeting;
}
