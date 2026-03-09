#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <functional>
#include <vector>
#include <string>

namespace peariscope {

using Microsoft::WRL::ComPtr;

struct DisplayInfo {
    std::wstring name;
    UINT width;
    UINT height;
    UINT outputIndex;
};

/// DXGI Desktop Duplication API screen capture.
/// Provides GPU-accelerated screen capture with no CPU readback.
class DxgiCapture {
public:
    using FrameCallback = std::function<void(
        ComPtr<ID3D11Texture2D> texture,
        UINT64 presentationTime
    )>;

    DxgiCapture();
    ~DxgiCapture();

    /// Enumerate available displays
    static std::vector<DisplayInfo> EnumerateDisplays();

    /// Initialize capture for a specific display
    bool Initialize(ID3D11Device* device, UINT outputIndex = 0);

    /// Capture the next frame. Returns false if no new frame is available.
    bool CaptureFrame();

    /// Get the captured frame texture (valid until next CaptureFrame or ReleaseFrame)
    ID3D11Texture2D* GetFrameTexture() const { return frameTexture_.Get(); }

    /// Release the current frame (must call before next CaptureFrame)
    void ReleaseFrame();

    /// Set callback for new frames
    void SetFrameCallback(FrameCallback callback) { frameCallback_ = callback; }

    UINT GetWidth() const { return width_; }
    UINT GetHeight() const { return height_; }

    void Shutdown();

private:
    ComPtr<IDXGIOutputDuplication> duplication_;
    ComPtr<ID3D11Texture2D> frameTexture_;
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;

    FrameCallback frameCallback_;
    UINT width_ = 0;
    UINT height_ = 0;
    bool hasFrame_ = false;
};

} // namespace peariscope
