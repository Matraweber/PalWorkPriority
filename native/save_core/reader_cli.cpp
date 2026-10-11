#include "record_reader.hpp"
#include <iostream>
#include <fcntl.h>
#include <io.h>
#include <cwchar>
using namespace pwp::experimental;
int wmain(int argc, wchar_t** argv) {
    const bool encoded = argc == 7 && std::wcscmp(argv[6], L"--encoded") == 0;
    if ((argc != 6 && !encoded) || std::wcslen(argv[5]) != 1 || (argv[5][0] != L'A' && argv[5][0] != L'B')) return 4;
    if (_setmode(_fileno(stdout), _O_BINARY) == -1) return 4;
    const auto result = record_reader::read(argv[1], argv[2], argv[3], argv[4], static_cast<char>(argv[5][0]));
    const char* state = "unreadable";
    switch (result.read.state) {
    case records::State::valid: state = "valid"; break;
    case records::State::missing: state = "missing"; break;
    case records::State::corrupt: state = "corrupt"; break;
    case records::State::unsupported: state = "unsupported"; break;
    case records::State::foreign: state = "foreign"; break;
    default: break;
    }
    std::cout << state << '\n' << result.error << '\n' << result.read.record.generation << '\n';
    // Default format remains unchanged. Opt-in mode exposes presence separately
    // from length so empty corrupt files cannot be confused with absent bytes.
    if (encoded) {
        std::cout << (result.encoded ? 1 : 0) << '\n';
        if (result.encoded)
            std::cout.write(result.encoded->data(), static_cast<std::streamsize>(result.encoded->size()));
    } else {
        std::cout.write(result.read.record.payload.data(), static_cast<std::streamsize>(result.read.record.payload.size()));
    }
    return std::cout ? 0 : 3;
}
