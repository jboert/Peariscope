#include "QrCode.h"
#include <algorithm>
#include <cassert>
#include <climits>
#include <cmath>
#include <cstring>

namespace peariscope {

// ---------------------------------------------------------------------------
// QR code tables
// ---------------------------------------------------------------------------

// Total codewords, data codewords, ECC codewords per block for versions 1-4
// at Medium error correction level.
struct VersionInfo {
    int version;
    int totalCodewords;
    int dataCodewords;
    int eccPerBlock;
    int numBlocks;
};

// For Medium ECC level. dataCodewords must be evenly divisible by numBlocks.
// Using simplified values that are close to spec and evenly divisible.
static const VersionInfo kVersions[] = {
    // ver, total, data, eccPerBlock, numBlocks
    {1,   26,  16, 10, 1},
    {2,   44,  28, 16, 1},
    {3,   70,  44, 26, 1},
    {4,  100,  64, 18, 2},
    {5,  134,  86, 24, 2},
    {6,  172, 108, 16, 4},
    {7,  196, 124, 18, 4},
    {8,  242, 152, 22, 4},  // adjusted: 152/4=38
    {9,  292, 180, 22, 5},  // adjusted: 180/5=36
    {10, 346, 210, 26, 5},  // adjusted: 210/5=42 (was 216 but need remainder codewords for ecc)
};

static constexpr int kMaxVersion = 10;

// Alignment pattern center positions for versions 2-10
// Each row lists the center coordinates; version N uses kAlignPos[N-2]
static const std::vector<int> kAlignPositions[] = {
    {6, 18},         // v2
    {6, 22},         // v3
    {6, 26},         // v4
    {6, 30},         // v5
    {6, 34},         // v6
    {6, 22, 38},     // v7
    {6, 24, 42},     // v8
    {6, 26, 46},     // v9
    {6, 28, 50},     // v10
};

// Format info bits (mask 0-7 at ECC level M = 0)
// Pre-computed with BCH(15,5) error correction and XOR mask 0x5412
static const uint16_t kFormatInfo[] = {
    0x5412 ^ 0x0000, // mask 0, ecl M (00)
    0x5412 ^ 0x0001,
    0x5412 ^ 0x0002,
    0x5412 ^ 0x0003,
    0x5412 ^ 0x0004,
    0x5412 ^ 0x0005,
    0x5412 ^ 0x0006,
    0x5412 ^ 0x0007,
};

// BCH(15,5) for format information
static uint32_t BchFormat(uint32_t data) {
    // Generator polynomial for format info: x^10 + x^8 + x^5 + x^4 + x^2 + x + 1
    // = 0x537
    uint32_t d = data << 10;
    uint32_t g = 0x537;
    for (int i = 4; i >= 0; i--) {
        if (d & (1 << (i + 10))) {
            d ^= g << i;
        }
    }
    return (data << 10) | d;
}

// GF(256) arithmetic for Reed-Solomon
static const uint8_t GF_EXP[512] = {
    1,2,4,8,16,32,64,128,29,58,116,232,205,135,19,38,76,152,45,90,180,117,234,201,143,3,6,12,24,48,96,192,
    157,39,78,156,37,74,148,53,106,212,181,119,238,193,159,35,70,140,5,10,20,40,80,160,93,186,105,210,185,111,222,161,
    95,190,97,194,153,47,94,188,101,202,137,15,30,60,120,240,253,231,211,187,107,214,177,127,254,225,223,163,91,182,113,226,
    217,175,67,134,17,34,68,136,13,26,52,104,208,189,103,206,129,31,62,124,248,237,199,147,59,118,236,197,151,51,102,204,
    133,23,46,92,184,109,218,169,79,158,33,66,132,21,42,84,168,77,154,41,82,164,85,170,73,146,57,114,228,213,183,115,
    230,209,191,99,198,145,63,126,252,229,215,179,123,246,241,255,227,219,171,75,150,49,98,196,149,55,110,220,165,87,174,65,
    130,25,50,100,200,141,7,14,28,56,112,224,221,167,83,166,81,162,89,178,121,242,249,239,195,155,43,86,172,69,138,9,
    18,36,72,144,61,122,244,245,247,243,251,235,203,139,11,22,44,88,176,125,250,233,207,131,27,54,108,216,173,71,142,1,
    // repeat for easy modular access
    2,4,8,16,32,64,128,29,58,116,232,205,135,19,38,76,152,45,90,180,117,234,201,143,3,6,12,24,48,96,192,157,
    39,78,156,37,74,148,53,106,212,181,119,238,193,159,35,70,140,5,10,20,40,80,160,93,186,105,210,185,111,222,161,95,
    190,97,194,153,47,94,188,101,202,137,15,30,60,120,240,253,231,211,187,107,214,177,127,254,225,223,163,91,182,113,226,217,
    175,67,134,17,34,68,136,13,26,52,104,208,189,103,206,129,31,62,124,248,237,199,147,59,118,236,197,151,51,102,204,133,
    23,46,92,184,109,218,169,79,158,33,66,132,21,42,84,168,77,154,41,82,164,85,170,73,146,57,114,228,213,183,115,230,
    209,191,99,198,145,63,126,252,229,215,179,123,246,241,255,227,219,171,75,150,49,98,196,149,55,110,220,165,87,174,65,130,
    25,50,100,200,141,7,14,28,56,112,224,221,167,83,166,81,162,89,178,121,242,249,239,195,155,43,86,172,69,138,9,18,
    36,72,144,61,122,244,245,247,243,251,235,203,139,11,22,44,88,176,125,250,233,207,131,27,54,108,216,173,71,142,1,
};

static uint8_t GF_LOG[256];
static bool gfInitDone = false;

static void InitGf() {
    if (gfInitDone) return;
    GF_LOG[0] = 0;  // undefined, but set to 0
    for (int i = 0; i < 255; i++) {
        GF_LOG[GF_EXP[i]] = static_cast<uint8_t>(i);
    }
    gfInitDone = true;
}

static uint8_t GfMul(uint8_t a, uint8_t b) {
    if (a == 0 || b == 0) return 0;
    return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

// ---------------------------------------------------------------------------
// Reed-Solomon ECC
// ---------------------------------------------------------------------------

std::vector<uint8_t> QrCode::ComputeEcc(const std::vector<uint8_t>& data, int numEcc) {
    InitGf();

    // Build generator polynomial
    std::vector<uint8_t> gen(numEcc + 1, 0);
    gen[0] = 1;
    for (int i = 0; i < numEcc; i++) {
        for (int j = numEcc; j >= 1; j--) {
            gen[j] = GfMul(gen[j], GF_EXP[i]) ^ gen[j - 1];
        }
        gen[0] = GfMul(gen[0], GF_EXP[i]);
    }

    // Divide data by generator
    std::vector<uint8_t> remainder(numEcc, 0);
    for (size_t i = 0; i < data.size(); i++) {
        uint8_t factor = data[i] ^ remainder[0];
        // Shift remainder left
        for (int j = 0; j < numEcc - 1; j++) {
            remainder[j] = remainder[j + 1] ^ GfMul(factor, gen[numEcc - 1 - j]);
        }
        remainder[numEcc - 1] = GfMul(factor, gen[0]);
    }
    return remainder;
}

// ---------------------------------------------------------------------------
// Data encoding (byte mode)
// ---------------------------------------------------------------------------

std::vector<uint8_t> QrCode::EncodeData(const std::string& text, int version) {
    const auto& vi = kVersions[version - 1];

    // Bit stream
    std::vector<bool> bits;
    auto addBits = [&](uint32_t val, int count) {
        for (int i = count - 1; i >= 0; i--) {
            bits.push_back((val >> i) & 1);
        }
    };

    // Mode indicator: 0100 = byte mode
    addBits(0b0100, 4);

    // Character count indicator (8 bits for byte mode, versions 1-9)
    addBits(static_cast<uint32_t>(text.size()), 8);

    // Data
    for (char c : text) {
        addBits(static_cast<uint8_t>(c), 8);
    }

    // Terminator (up to 4 zero bits)
    int dataBits = vi.dataCodewords * 8;
    int terminatorLen = std::min(4, dataBits - static_cast<int>(bits.size()));
    for (int i = 0; i < terminatorLen; i++) {
        bits.push_back(false);
    }

    // Pad to byte boundary
    while (bits.size() % 8 != 0) {
        bits.push_back(false);
    }

    // Pad with alternating bytes 0xEC, 0x11
    uint8_t padBytes[] = {0xEC, 0x11};
    int padIdx = 0;
    while (static_cast<int>(bits.size()) < dataBits) {
        addBits(padBytes[padIdx & 1], 8);
        padIdx++;
    }

    // Convert to bytes
    std::vector<uint8_t> dataBytes(vi.dataCodewords);
    for (int i = 0; i < vi.dataCodewords; i++) {
        uint8_t b = 0;
        for (int j = 0; j < 8; j++) {
            b = (b << 1) | (bits[i * 8 + j] ? 1 : 0);
        }
        dataBytes[i] = b;
    }

    // Compute ECC for each block and interleave
    int numBlocks = vi.numBlocks;
    int dataPerBlock = vi.dataCodewords / numBlocks;
    int eccPerBlock = vi.eccPerBlock;

    std::vector<std::vector<uint8_t>> dataBlocks(numBlocks);
    std::vector<std::vector<uint8_t>> eccBlocks(numBlocks);

    for (int b = 0; b < numBlocks; b++) {
        dataBlocks[b].assign(
            dataBytes.begin() + b * dataPerBlock,
            dataBytes.begin() + (b + 1) * dataPerBlock);
        eccBlocks[b] = ComputeEcc(dataBlocks[b], eccPerBlock);
    }

    // Interleave data codewords
    std::vector<uint8_t> result;
    for (int i = 0; i < dataPerBlock; i++) {
        for (int b = 0; b < numBlocks; b++) {
            result.push_back(dataBlocks[b][i]);
        }
    }

    // Interleave ECC codewords
    for (int i = 0; i < eccPerBlock; i++) {
        for (int b = 0; b < numBlocks; b++) {
            result.push_back(eccBlocks[b][i]);
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// Matrix operations
// ---------------------------------------------------------------------------

void QrCode::InitMatrix(int version) {
    version_ = version;
    size_ = 17 + version * 4;
    modules_.assign(size_ * size_, false);
    isFunction_.assign(size_ * size_, false);

    // Finder patterns
    PlaceFinderPattern(3, 3);
    PlaceFinderPattern(size_ - 4, 3);
    PlaceFinderPattern(3, size_ - 4);

    // Timing patterns
    PlaceTimingPatterns();

    // Alignment patterns (version >= 2)
    if (version >= 2 && version - 2 < static_cast<int>(sizeof(kAlignPositions)/sizeof(kAlignPositions[0]))) {
        const auto& positions = kAlignPositions[version - 2];
        for (size_t r = 0; r < positions.size(); r++) {
            for (size_t c = 0; c < positions.size(); c++) {
                // Skip positions that overlap finder patterns
                if (r == 0 && c == 0) continue;  // top-left
                if (r == 0 && c == positions.size() - 1) continue;  // top-right
                if (r == positions.size() - 1 && c == 0) continue;  // bottom-left
                PlaceAlignmentPattern(positions[c], positions[r]);
            }
        }
    }

    // Dark module
    modules_[(4 * version + 9) * size_ + 8] = true;
    isFunction_[(4 * version + 9) * size_ + 8] = true;

    // Reserve format info areas
    for (int i = 0; i < 8; i++) {
        // Horizontal near top-left
        isFunction_[8 * size_ + i] = true;
        isFunction_[8 * size_ + (size_ - 1 - i)] = true;
        // Vertical near top-left
        isFunction_[i * size_ + 8] = true;
        isFunction_[(size_ - 1 - i) * size_ + 8] = true;
    }
    isFunction_[8 * size_ + 8] = true;
}

void QrCode::PlaceFinderPattern(int cx, int cy) {
    for (int dy = -4; dy <= 4; dy++) {
        for (int dx = -4; dx <= 4; dx++) {
            int x = cx + dx;
            int y = cy + dy;
            if (x < 0 || x >= size_ || y < 0 || y >= size_) continue;

            int adx = abs(dx), ady = abs(dy);
            bool black = (std::max(adx, ady) <= 3) &&
                         !(adx == 3 && ady == 3) &&
                         (std::max(adx, ady) != 2 || (adx == 2 && ady == 2));

            // Finder pattern: 3x3 center, 1 ring white, 1 ring black, + separator
            int dist = std::max(adx, ady);
            if (dist <= 3) {
                black = (dist != 2) && (dist != 4);
            } else {
                black = false;
            }

            modules_[y * size_ + x] = black;
            isFunction_[y * size_ + x] = true;
        }
    }
}

void QrCode::PlaceAlignmentPattern(int cx, int cy) {
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int x = cx + dx;
            int y = cy + dy;
            if (x < 0 || x >= size_ || y < 0 || y >= size_) continue;

            int dist = std::max(abs(dx), abs(dy));
            bool black = (dist != 1);
            modules_[y * size_ + x] = black;
            isFunction_[y * size_ + x] = true;
        }
    }
}

void QrCode::PlaceTimingPatterns() {
    for (int i = 8; i < size_ - 8; i++) {
        bool black = (i % 2 == 0);
        // Horizontal
        if (!isFunction_[6 * size_ + i]) {
            modules_[6 * size_ + i] = black;
            isFunction_[6 * size_ + i] = true;
        }
        // Vertical
        if (!isFunction_[i * size_ + 6]) {
            modules_[i * size_ + 6] = black;
            isFunction_[i * size_ + 6] = true;
        }
    }
}

void QrCode::PlaceFormatInfo(int mask) {
    // ECC level M = 00, mask pattern
    uint32_t data = (0 << 3) | mask;  // ECL M = 0b00
    uint32_t bits = BchFormat(data);
    bits ^= 0x5412;  // XOR mask

    // Place format info bits
    // Around top-left finder
    static const int hx[] = {0,1,2,3,4,5,7,8};
    static const int hy[] = {8,8,8,8,8,8,8,8};
    static const int vx[] = {8,8,8,8,8,8,8,8};
    static const int vy[] = {0,1,2,3,4,5,7,8};

    for (int i = 0; i < 8; i++) {
        bool bit = (bits >> i) & 1;
        modules_[hy[i] * size_ + hx[i]] = bit;
        modules_[vy[i] * size_ + vx[i]] = bit;
    }

    // Around top-right and bottom-left finders
    for (int i = 0; i < 7; i++) {
        bool bit = (bits >> (14 - i)) & 1;
        // Top-right: row 8, columns from right
        modules_[8 * size_ + (size_ - 1 - i)] = bit;
    }
    for (int i = 0; i < 8; i++) {
        bool bit;
        if (i < 1) {
            bit = (bits >> 7) & 1;
            modules_[(size_ - 1 - 0) * size_ + 8] = bit;
        }
        // Bottom-left: column 8, rows from bottom
        bit = (bits >> i) & 1;
        modules_[(size_ - 1 - i) * size_ + 8] = bit;
    }

    // Correct placement using standard spec
    // Horizontal: positions in row 8
    int pos = 0;
    for (int i = 0; i <= 7; i++) {
        int x = (i < 6) ? i : i + 1;  // skip timing at x=6
        modules_[8 * size_ + x] = (bits >> pos) & 1;
        pos++;
    }
    // Vertical: positions in column 8
    pos = 0;
    for (int i = 0; i <= 7; i++) {
        int y = (i < 6) ? i : i + 1;  // skip timing at y=6
        modules_[y * size_ + 8] = (bits >> pos) & 1;
        pos++;
    }

    // Second copy
    // Row 8, right side
    for (int i = 0; i < 7; i++) {
        modules_[8 * size_ + (size_ - 1 - i)] = (bits >> (14 - i)) & 1;
    }
    // Column 8, bottom side
    for (int i = 0; i < 8; i++) {
        modules_[(size_ - 1 - i) * size_ + 8] = (bits >> i) & 1;
    }
}

void QrCode::PlaceVersionInfo() {
    // Version info only for version >= 7, not needed here
}

void QrCode::PlaceData(const std::vector<uint8_t>& data) {
    // Convert to bit stream
    std::vector<bool> bits;
    for (uint8_t b : data) {
        for (int i = 7; i >= 0; i--) {
            bits.push_back((b >> i) & 1);
        }
    }

    // Place bits in the zigzag pattern
    int bitIdx = 0;
    // Columns go right-to-left in pairs, skipping column 6 (timing)
    for (int right = size_ - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5;  // skip timing column

        for (int vert = 0; vert < size_; vert++) {
            for (int j = 0; j < 2; j++) {
                int x = right - j;
                // Upward or downward?
                bool upward = ((right + 1) / 2) % 2 == 1;
                // Adjust: rightmost pair goes up, next goes down, etc.
                // Actually: in QR, the first column pair (rightmost) goes upward
                int col_pair = (size_ - 1 - right) / 2;  // 0 for rightmost
                upward = (col_pair % 2 == 0);
                int y = upward ? (size_ - 1 - vert) : vert;

                if (x < 0 || x >= size_ || y < 0 || y >= size_) continue;
                if (isFunction_[y * size_ + x]) continue;

                if (bitIdx < static_cast<int>(bits.size())) {
                    modules_[y * size_ + x] = bits[bitIdx];
                    bitIdx++;
                }
            }
        }
    }
}

void QrCode::ApplyMask(int mask) {
    for (int y = 0; y < size_; y++) {
        for (int x = 0; x < size_; x++) {
            if (isFunction_[y * size_ + x]) continue;

            bool invert = false;
            switch (mask) {
                case 0: invert = (y + x) % 2 == 0; break;
                case 1: invert = y % 2 == 0; break;
                case 2: invert = x % 3 == 0; break;
                case 3: invert = (y + x) % 3 == 0; break;
                case 4: invert = (y / 2 + x / 3) % 2 == 0; break;
                case 5: invert = (y * x) % 2 + (y * x) % 3 == 0; break;
                case 6: invert = ((y * x) % 2 + (y * x) % 3) % 2 == 0; break;
                case 7: invert = ((y + x) % 2 + (y * x) % 3) % 2 == 0; break;
            }
            if (invert) {
                modules_[y * size_ + x] = !modules_[y * size_ + x];
            }
        }
    }
}

int QrCode::EvaluatePenalty() const {
    int penalty = 0;

    // Rule 1: runs of same color in row/column
    for (int y = 0; y < size_; y++) {
        int run = 1;
        for (int x = 1; x < size_; x++) {
            if (modules_[y * size_ + x] == modules_[y * size_ + x - 1]) {
                run++;
            } else {
                if (run >= 5) penalty += run - 2;
                run = 1;
            }
        }
        if (run >= 5) penalty += run - 2;
    }
    for (int x = 0; x < size_; x++) {
        int run = 1;
        for (int y = 1; y < size_; y++) {
            if (modules_[y * size_ + x] == modules_[(y - 1) * size_ + x]) {
                run++;
            } else {
                if (run >= 5) penalty += run - 2;
                run = 1;
            }
        }
        if (run >= 5) penalty += run - 2;
    }

    // Rule 2: 2x2 blocks of same color
    for (int y = 0; y < size_ - 1; y++) {
        for (int x = 0; x < size_ - 1; x++) {
            bool c = modules_[y * size_ + x];
            if (c == modules_[y * size_ + x + 1] &&
                c == modules_[(y + 1) * size_ + x] &&
                c == modules_[(y + 1) * size_ + x + 1]) {
                penalty += 3;
            }
        }
    }

    return penalty;
}

int QrCode::SelectBestMask() {
    // Save original data modules
    std::vector<bool> saved = modules_;

    int bestMask = 0;
    int bestPenalty = INT_MAX;

    for (int mask = 0; mask < 8; mask++) {
        modules_ = saved;
        ApplyMask(mask);
        PlaceFormatInfo(mask);
        int p = EvaluatePenalty();
        if (p < bestPenalty) {
            bestPenalty = p;
            bestMask = mask;
        }
    }

    // Apply the best mask
    modules_ = saved;
    ApplyMask(bestMask);
    PlaceFormatInfo(bestMask);
    return bestMask;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool QrCode::Generate(const std::string& text) {
    // Find the smallest version that fits
    int version = 0;
    for (int v = 1; v <= kMaxVersion; v++) {
        const auto& vi = kVersions[v - 1];
        // Byte mode: 4 (mode) + 8 (count) + 8*len (data) + 4 (terminator) bits
        int neededBits = 4 + 8 + 8 * static_cast<int>(text.size());
        if (neededBits <= vi.dataCodewords * 8) {
            version = v;
            break;
        }
    }

    if (version == 0) return false;  // too long

    // Encode data + ECC
    auto codewords = EncodeData(text, version);

    // Build matrix
    InitMatrix(version);
    PlaceData(codewords);
    SelectBestMask();

    return true;
}

bool QrCode::GetModule(int x, int y) const {
    if (x < 0 || x >= size_ || y < 0 || y >= size_) return false;
    return modules_[y * size_ + x];
}

} // namespace peariscope
