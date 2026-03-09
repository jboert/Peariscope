#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mftransform.h>
#include <codecapi.h>
#include <wrl/client.h>
#include <functional>
#include <vector>
#include <cstdint>

namespace peariscope {

using Microsoft::WRL::ComPtr;

/// Hardware-accelerated H.264 encoder using Media Foundation Transform.
class MfEncoder {
public:
    /// Called with encoded NAL units (Annex B format) ready for network transmission
    using EncodedCallback = std::function<void(
        const uint8_t* data, size_t size, bool isKeyframe
    )>;

    MfEncoder();
    ~MfEncoder();

    /// Initialize the encoder
    bool Initialize(ID3D11Device* device, UINT width, UINT height,
                    UINT fps = 60, UINT bitrate = 8000000);

    /// Encode a frame from a D3D11 texture
    bool Encode(ID3D11Texture2D* texture, UINT64 timestamp);

    /// Force next frame to be a keyframe
    void ForceKeyframe();

    /// Update bitrate
    void SetBitrate(UINT bitrate);

    /// Set encoded data callback
    void SetCallback(EncodedCallback callback) { callback_ = callback; }

    void Shutdown();

private:
    bool CreateEncoder(ID3D11Device* device, UINT width, UINT height,
                       UINT fps, UINT bitrate);
    bool ProcessOutput();

    ComPtr<IMFTransform> transform_;
    ComPtr<IMFDXGIDeviceManager> deviceManager_;
    UINT resetToken_ = 0;
    EncodedCallback callback_;
    UINT width_ = 0;
    UINT height_ = 0;
    bool forceKeyframe_ = false;
};

} // namespace peariscope
