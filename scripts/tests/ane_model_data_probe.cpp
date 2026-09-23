#include "ANEModelData.h"
#include <fstream>
#include <string>

int main(int argc, char **argv) {
    if (argc == 3 && std::string_view(argv[1]) == "identifier") {
        return furnace::ane::validModelIdentifier(argv[2]) ? 0 : 2;
    }
    if (argc == 2 && std::string_view(argv[1]) == "embedded-null") {
        return furnace::ane::validModelIdentifier(std::string_view("AB\0CD", 5)) ? 0 : 2;
    }
    if (argc != 4 || std::string_view(argv[1]) != "weights") return 1;
    const auto blob = furnace::ane::buildWeightBlob(std::stoul(argv[2]));
    std::ofstream output(argv[3], std::ios::binary);
    output.write(reinterpret_cast<const char *>(blob.data()), blob.size());
    return output ? 0 : 1;
}
