// Standalone test seam for the SAME adapter/core; never loads UE4SS.
#include "probe.hpp"
#include <iostream>
#include <string>
#include <fcntl.h>
#include <io.h>
int main(int argc, char**) {
    if (argc != 1) return 20; // no root/scope arguments
    _setmode(_fileno(stdin), _O_BINARY);
    std::string hex;
    char c;
    while (hex.size() <= pwp::file_probe::max_hex && std::cin.get(c)) hex.push_back(c);
    if (std::cin.bad()) return 21;
    const auto r = pwp::file_probe::publish_hex(hex, static_cast<std::int64_t>(hex.size()));
    std::cout << r.status << ' ' << r.error << ' ' << r.thread << ' ' << r.start << ' '
              << r.end << ' ' << r.checksum << ' ' << r.frequency << '\n';
    return static_cast<int>(r.status);
}
