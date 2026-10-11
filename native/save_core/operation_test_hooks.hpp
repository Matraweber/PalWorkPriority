#pragma once
#include "journal.hpp"
namespace pwp::experimental::operation_test {
enum class Fault { none, after_publish, after_return_exception, cleanup_warning, cleanup_close_uncertain };
void configure(Fault fault);
unsigned journal_calls();
unsigned published_hooks();
}
namespace pwp::experimental::journal {
Result counted_update(const std::wstring&, std::wstring_view, std::wstring_view,
                      std::wstring_view, const Preimages&, std::string_view);
}
