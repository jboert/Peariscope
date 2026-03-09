#include "D3DRenderer.h"
#include <iostream>

namespace peariscope {

D3DRenderer::D3DRenderer() = default;
D3DRenderer::~D3DRenderer() { Shutdown(); }

bool D3DRenderer::Initialize(HWND hwnd, UINT width, UINT height) {
    width_ = width;
    height_ = height;

    // Create D3D11 device
    D3D_FEATURE_LEVEL featureLevels[] = { D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL featureLevel;

    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        featureLevels, 1, D3D11_SDK_VERSION,
        &device_, &featureLevel, &context_
    );
    if (FAILED(hr)) return false;

    // Create swap chain
    ComPtr<IDXGIFactory2> factory;
    {
        ComPtr<IDXGIDevice> dxgiDevice;
        device_->QueryInterface(IID_PPV_ARGS(&dxgiDevice));
        ComPtr<IDXGIAdapter> adapter;
        dxgiDevice->GetAdapter(&adapter);
        adapter->GetParent(IID_PPV_ARGS(&factory));
    }

    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = width;
    desc.Height = height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    hr = factory->CreateSwapChainForHwnd(device_.Get(), hwnd, &desc, nullptr, nullptr, &swapChain_);
    if (FAILED(hr)) return false;

    // Create render target view
    ComPtr<ID3D11Texture2D> backBuffer;
    swapChain_->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    device_->CreateRenderTargetView(backBuffer.Get(), nullptr, &renderTarget_);

    return true;
}

void D3DRenderer::Present(ID3D11Texture2D* texture) {
    if (!swapChain_ || !context_) return;

    // Copy decoded texture to back buffer
    ComPtr<ID3D11Texture2D> backBuffer;
    swapChain_->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    context_->CopyResource(backBuffer.Get(), texture);

    swapChain_->Present(0, 0);
}

void D3DRenderer::Resize(UINT width, UINT height) {
    if (!swapChain_) return;

    width_ = width;
    height_ = height;
    renderTarget_.Reset();
    swapChain_->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0);

    ComPtr<ID3D11Texture2D> backBuffer;
    swapChain_->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    device_->CreateRenderTargetView(backBuffer.Get(), nullptr, &renderTarget_);
}

void D3DRenderer::Shutdown() {
    renderTarget_.Reset();
    swapChain_.Reset();
    context_.Reset();
    device_.Reset();
}

} // namespace peariscope
