#include "shared.hpp"
#include <cmath>
#include <cstdio>

namespace shared
{
  static std::atomic<int> g_call_count{ 0 };

  double magnitude(double x, double y, double z)
  {
    int const n = ++g_call_count;
    auto const result = std::sqrt(x * x + y * y + z * z);
    std::printf("  [shared::magnitude] call #%d  magnitude(%g, %g, %g) = %g  (fn=%p)\n",
                n, x, y, z, result,
                reinterpret_cast<void *>(&magnitude));
    return result;
  }

  int call_count() { return g_call_count.load(); }
}
