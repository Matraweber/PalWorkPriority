// Standalone offline seam. Fixture preimage files are read, never modified.
#include "journal.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <fcntl.h>
#include <io.h>

#ifdef PWP_JOURNAL_TESTING
namespace pwp::experimental::journal {
static std::string hook;
DWORD journal_test_point(const char* point) {
    if (hook == std::string("fail:") + point) return ERROR_WRITE_FAULT;
    if (hook == std::string("crash:") + point) TerminateProcess(GetCurrentProcess(), 91);
    if (hook == std::string("pause:") + point) {
        wchar_t name[256]{};
        const DWORD length = GetEnvironmentVariableW(L"PWP_JOURNAL_TEST_GATE", name, 256);
        if (!length || length >= 256) return ERROR_INVALID_PARAMETER;
        HANDLE gate = OpenEventW(SYNCHRONIZE, FALSE, name);
        if (!gate) return GetLastError();
        std::cout << "READY\n" << std::flush;
        const DWORD waited = WaitForSingleObject(gate, 15000);
        const BOOL closed = CloseHandle(gate);
        return waited == WAIT_OBJECT_0 && closed ? 0 : ERROR_TIMEOUT;
    }
    return 0;
}
}
#endif
using namespace pwp::experimental;
static std::string bounded(std::istream& input) {
    std::string bytes(records::max_record + 1, '\0');
    input.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    bytes.resize(static_cast<std::size_t>(input.gcount()));
    if (input.bad() || bytes.size() > records::max_record) throw std::runtime_error("input unreadable/oversize");
    return bytes;
}
int wmain(int argc, wchar_t** argv) {
    try {
        if (argc != 7
#ifdef PWP_JOURNAL_TESTING
            && argc != 8
#endif
        ) return 20;
        if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1) return 20;
#ifdef PWP_JOURNAL_TESTING
        if (argc == 8) {
            for (const wchar_t* p = argv[7]; *p; ++p) {
                if (*p > 127) return 20;
                journal::hook.push_back(static_cast<char>(*p));
            }
        }
#endif
        journal::Preimages expected;
        for (int i = 0; i < 2; ++i) {
            if (std::wstring_view(argv[5 + i]) == L"MISSING") continue;
            std::ifstream input(std::filesystem::path(argv[5 + i]), std::ios::binary);
            if (!input) return 20;
            expected[i] = bounded(input);
        }
        const auto encoded = bounded(std::cin);
        const auto result = journal::update(argv[1], argv[2], argv[3], argv[4], expected, encoded);
        const char* name = "uncertain";
        switch (result.status) {
        case journal::Status::initialized: name = "initialized"; break;
        case journal::Status::updated: name = "updated"; break;
        case journal::Status::conflict: name = "conflict"; break;
        case journal::Status::io_error: name = "io_error"; break;
        default: break;
        }
        std::cout << name << ' ' << result.error << ' ' << result.slot << ' ' << result.generation
                  << ' ' << result.cleanup_error << '\n';
        if (!std::cout) return 21;
        return static_cast<int>(result.status);
    } catch (...) { return 22; }
}
