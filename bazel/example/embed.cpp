// Embedding example: C++ host and jank script both call the same
// shared::magnitude() function from shared.hpp.  The function prints
// its own address and a call counter to prove it's the same instance.

#include <iostream>

#include <jank/c_api.h>
#include <jank/runtime/context.hpp>
#include <jank/runtime/core/to_string.hpp>

#include <clojure/core_native.hpp>
#include <clojure/string_native.hpp>
#include <jank/compiler_native.hpp>
#include <jank/perf_native.hpp>

#include <shared.hpp>

static int run(int const, char const **)
{
  using namespace jank::runtime;

  jank_load_clojure_core_native();
  __rt_ctx->load_module("clojure.core", module::origin::latest).expect_ok();
  __rt_ctx->eval_file("bazel/example/plugin.jank");

  std::cout << "\n=== Calling shared::magnitude(3, 4, 12) from C++ host ===" << std::endl;
  double const host_result = shared::magnitude(3.0, 4.0, 12.0);

  std::cout << "\n=== Calling shared::magnitude(3, 4, 12) from jank script ===" << std::endl;
  auto const mag_fn{ reinterpret_cast<jank_object_ref>(
    __rt_ctx->find_var("plugin.core", "shared-magnitude")->deref().data) };
  jank_object_ref const jank_result{ jank_call3(
    mag_fn,
    jank_real_create(3.0),
    jank_real_create(4.0),
    jank_real_create(12.0)) };

  std::cout << "\n=== Results ===" << std::endl;
  std::cout << "  Host result:   " << host_result << std::endl;
  std::cout << "  Script result: " << to_string(reinterpret_cast<object *>(jank_result)) << std::endl;
  std::cout << "  Total calls:   " << shared::call_count() << std::endl;

  return 0;
}

int main(int argc, char const **argv)
{
  return jank_init(argc, argv, /*init_default_ctx=*/1, run);
}
