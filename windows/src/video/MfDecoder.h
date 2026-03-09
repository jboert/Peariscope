#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mftransform.h>
#include <wrl/client.h>
#include <functional>
#include <cstdint>

namespace peariscope {

using Microsoft::WRL::ComPtr;

/// Hardware-accelerated H.264 decoder using Media Foundation Transform.
class MfDecoder {
public:
    using DecodedCallback = std::function<void(
        ComPtr<ID3D11Texture2D> texture, UINT64 timestamp
    )>;

    MfDecoder();
    ~MfDecoder();

    /// Initialize decoder
    bool Initialize(ID3D11Device* device, UINT width, UINT height);

    /// Decode Annex B H.264 data
    bool Decode(const uint8_t* data, size_t size);

    /// Set decoded frame callback
    void SetCallback(DecodedCallback callback) { callback_ = callback; }

    void Shutdown();

private:
    bool ProcessOutput();

    ComPtr<IMFTransform> transform_;
    ComPtr<IMFDXGIDeviceManager> deviceManager_;
    UINT resetToken_ = 0;
    DecodedCallback callback_;
};

} // namespace peariscope
