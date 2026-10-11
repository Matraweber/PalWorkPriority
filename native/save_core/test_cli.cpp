// Standalone disposable-folder harness, never loaded into Palworld.
#include "initialization.hpp"
#include <Windows.h>
#include <iostream>
#include <iterator>
#include <string>
#include <fcntl.h>
#include <io.h>
static std::string hook;
namespace pwp::experimental {
DWORD initialization_test_point(const char* point) {
    if (hook == std::string("fail:") + point) return ERROR_WRITE_FAULT;
    if (hook == std::string("pause:") + point) {
        std::cout << "READY\n" << std::flush;
        // Named event permits independent processes to release a paused writer.
        wchar_t name[256];
        if (!GetEnvironmentVariableW(L"PWP_TEST_GATE", name, 256)) return ERROR_INVALID_PARAMETER;
        HANDLE gate = OpenEventW(SYNCHRONIZE, FALSE, name);
        if (!gate) return GetLastError();
        DWORD wait = WaitForSingleObject(gate, 15000);
        CloseHandle(gate);
        if (wait != WAIT_OBJECT_0) return ERROR_TIMEOUT;
    }
    return 0;
}
}
int wmain(int argc, wchar_t** argv) {
    if (argc != 6) return 20;
    for (auto p = argv[5]; *p; ++p) hook += static_cast<char>(*p);
    _setmode(_fileno(stdin), _O_BINARY);
    const std::string bytes{std::istreambuf_iterator<char>(std::cin), {}};
    auto result = pwp::experimental::initialize(argv[1], argv[2], argv[3], argv[4], bytes);
    std::cout << static_cast<int>(result.status) << " " << result.error << "\n" << std::flush;
    return static_cast<int>(result.status);
}
