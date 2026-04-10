#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace peariscope {

/// Minimal QR code generator supporting Version 1-4, byte mode,
/// medium error correction.  Produces a bool matrix where true = black.
class QrCode {
public:
    /// Generate a QR code for the given text.
    /// Returns false if the text is too long for the supported versions.
    bool Generate(const std::string& text);

    /// Get the size (modules per side).  0 if not generated.
    int GetSize() const { return size_; }

    /// Get whether module (x,y) is black.  Out-of-range returns false.
    bool GetModule(int x, int y) const;

    /// Get the raw matrix.
    const std::vector<bool>& GetMatrix() const { return modules_; }

private:
    // Encoding
    std::vector<uint8_t> EncodeData(const std::string& text, int version);
    std::vector<uint8_t> ComputeEcc(const std::vector<uint8_t>& data, int numEcc);

    // Matrix operations
    void InitMatrix(int version);
    void PlaceFinderPattern(int cx, int cy);
    void PlaceAlignmentPattern(int cx, int cy);
    void PlaceTimingPatterns();
    void PlaceFormatInfo(int mask);
    void PlaceVersionInfo();
    void PlaceData(const std::vector<uint8_t>& data);
    void ApplyMask(int mask);
    int  EvaluatePenalty() const;
    int  SelectBestMask();

    int size_ = 0;
    int version_ = 0;
    std::vector<bool> modules_;
    std::vector<bool> isFunction_;  // true if module is part of a pattern
};

} // namespace peariscope
