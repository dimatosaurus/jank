#pragma once

// Shared between C++ host and jank script.
// The function is declared here but DEFINED in shared.cpp (compiled into
// the host).  The JIT resolves the symbol from the host binary via
// -export_dynamic, so both callers execute the exact same function.

#include <atomic>

namespace shared
{
  double magnitude(double x, double y, double z);
  int call_count();
}
