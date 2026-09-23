#pragma once
#include <algorithm>
#include <bit>
#include <cstdint>
#include <cstring>
#include <string_view>
#include <vector>

namespace furnace::ane {
inline bool validModelIdentifier(std::string_view identifier) {
    // The framework joins hash components with underscores. Preserve its name
    // exactly, while allowing only a single bounded filesystem component.
    if (identifier.empty() || identifier.size() > 255 || identifier.front() == '_' ||
        identifier.back() == '_' || identifier.find("__") != std::string_view::npos) return false;
    return std::all_of(identifier.begin(), identifier.end(), [](char c) {
        return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    });
}

inline std::vector<uint8_t> buildWeightBlob(size_t channels) {
    constexpr size_t depth = 16;
    const size_t weightSize = channels * channels * 2;
    const size_t chunkSize = 64 + weightSize;
    std::vector<uint8_t> bytes(64 + chunkSize * depth, 0);
    // Core ML MILBlob StorageFormat v2: 64-byte file header, then one
    // 64-byte metadata record and FP16 payload per layer. Metadata stores
    // the byte length and absolute payload offset, not an element-width flag.
    // Schema: apple/coremltools, mlmodel/src/MILBlob/Blob/StorageFormat.hpp.
    static_assert(std::endian::native == std::endian::little);
    const uint32_t count = depth, version = 2, sentinel = 0xDEADBEEF, float16Type = 1;
    std::memcpy(bytes.data(), &count, sizeof(count));
    std::memcpy(bytes.data() + 4, &version, sizeof(version));
    for (size_t layer = 0; layer < depth; ++layer) {
        uint8_t *chunk = bytes.data() + 64 + chunkSize * layer;
        const uint64_t sizeInBytes = weightSize, dataOffset = 128 + chunkSize * layer;
        std::memcpy(chunk, &sentinel, sizeof(sentinel));
        std::memcpy(chunk + 4, &float16Type, sizeof(float16Type));
        std::memcpy(chunk + 8, &sizeInBytes, sizeof(sizeInBytes));
        std::memcpy(chunk + 16, &dataOffset, sizeof(dataOffset));
        _Float16 *values = reinterpret_cast<_Float16 *>(chunk + 64);
        for (size_t row = 0; row < channels; ++row) {
            double sum = 0;
            for (size_t col = 0; col < channels; ++col) sum += 1 + ((row + col + layer) % 7);
            for (size_t col = 0; col < channels; ++col)
                values[row * channels + col] = (_Float16)((1 + ((row + col + layer) % 7)) / sum);
        }
    }
    return bytes;
}
}
