#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

namespace peariscope {

using Microsoft::WRL::ComPtr;

/// Direct3D 11 renderer for displaying decoded video frames.
class D3DRenderer {
public:
    D3DRenderer();
    ~D3DRenderer();

    /// Initialize with a window handle
    bool Initialize(HWND hwnd, UINT width, UINT height);

    /// Display a decoded texture
    void Present(ID3D11Texture2D* texture);

    /// Resize the swap chain
    void Resize(UINT width, UINT height);

    ID3D11Device* GetDevice() const { return device_.Get(); }
    ID3D11DeviceContext* GetContext() const { return context_.Get(); }

    void Shutdown();

private:
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<IDXGISwapChain1> swapChain_;
    ComPtr<ID3D11RenderTargetView> renderTarget_;

    UINT width_ = 0;
    UINT height_ = 0;
};

} // namespace peariscope
