#pragma once

namespace cpplib
{
  /// Returns the nth Fibonacci number, computed iteratively in C++.
  inline long fib(long n)
  {
    if(n <= 1)
      return n;
    long a = 0, b = 1;
    for(long i = 2; i <= n; ++i)
    {
      long tmp = a + b;
      a = b;
      b = tmp;
    }
    return b;
  }

  /// Returns a friendly greeting.
  inline const char *greeting() { return "Hello from C++!"; }
}
