// TEST BINARY ONLY. Compile instead of operation.cpp, never alongside it.
// Include its actual implementation with only the journal call redirected to a
// counted forwarding seam. Counter increments before any journal early return,
// independently of mailbox delivery or successful filesystem publication.
#include "operation.hpp"
#include "operation_test_hooks.hpp"
#include <utility>
#include <stdexcept>
#include <string_view>
#define update counted_update
#include "operation.cpp"
#undef update
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>

namespace pwp::experimental::operation_test {
namespace {
std::atomic<unsigned> calls{0}, publications{0};
std::atomic<Fault> fault{Fault::none};
}
void configure(Fault value) {
    // Tests call only before launching threads, after previous workers join.
    calls = 0; publications = 0; fault = value;
}
unsigned journal_calls() { return calls.load(); }
unsigned published_hooks() { return publications.load(); }
}
namespace pwp::experimental::journal {
DWORD journal_test_point(const char* point) {
    if (std::string_view(point) == "before_disposition" && operation_test::fault == operation_test::Fault::cleanup_warning)
        return ERROR_WRITE_FAULT;
    if (std::string_view(point) == "after_backup_close" && operation_test::fault == operation_test::Fault::cleanup_close_uncertain)
        return ERROR_WRITE_FAULT;
    if (std::string_view(point) == "after_publish") {
        ++operation_test::publications;
        if (operation_test::fault == operation_test::Fault::after_publish) return ERROR_WRITE_FAULT;
    }
    return 0;
}
Result counted_update(const std::wstring& root, std::wstring_view storage, std::wstring_view guild,
                      std::wstring_view stream, const Preimages& expected, std::string_view encoded) {
    ++operation_test::calls;
    const auto result = update(root, storage, guild, stream, expected, encoded);
    if (operation_test::fault == operation_test::Fault::after_return_exception)
        throw std::runtime_error("test transport exception after journal return");
    return result;
}
}
