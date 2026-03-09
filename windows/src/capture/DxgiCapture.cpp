#include "DxgiCapture.h"
#include <dxgi.h>
#include <iostream>

namespace peariscope {

DxgiCapture::DxgiCapture() = default;
DxgiCapture::~DxgiCapture() { Shutdown(); }

std::vector<DisplayInfo> DxgiCapture::EnumerateDisplays() {
    std::vector<DisplayInfo> displays;

    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
        return displays;
    }

    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i) {
        ComPtr<IDXGIOutput> output;
        for (UINT j = 0; adapter->EnumOutputs(j, &output) != DXGI_ERROR_NOT_FOUND; ++j) {
            DXGI_OUTPUT_DESC desc;
            output->GetDesc(&desc);

            DisplayInfo info;
            info.name = desc.DeviceName;
            info.width = desc.DesktopCoordinates.right - desc.DesktopCoordinates.left;
            info.height = desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top;
            info.outputIndex = j;
            displays.push_back(info);
        }
    }

    return displays;
}

bool DxgiCapture::Initialize(ID3D11Device* device, UINT outputIndex) {
    device_ = device;
    device_->GetImmediateContext(&context_);

    // Get DXGI device -> adapter -> output
    ComPtr<IDXGIDevice> dxgiDevice;
    if (FAILED(device_->QueryInterface(IID_PPV_ARGS(&dxgiDevice)))) return false;

    ComPtr<IDXGIAdapter> adapter;
    if (FAILED(dxgiDevice->GetAdapter(&adapter))) return false;

    ComPtr<IDXGIOutput> output;
    if (FAILED(adapter->EnumOutputs(outputIndex, &output))) return false;

    ComPtr<IDXGIOutput1> output1;
    if (FAILED(output->QueryInterface(IID_PPV_ARGS(&output1)))) return false;

    DXGI_OUTPUT_DESC outputDesc;
    output->GetDesc(&outputDesc);
    width_ = outputDesc.DesktopCoordinates.right - outputDesc.DesktopCoordinates.left;
    height_ = outputDesc.DesktopCoordinates.bottom - outputDesc.DesktopCoordinates.top;

    // Create desktop duplication
    HRESULT hr = output1->DuplicateOutput(device_, &duplication_);
    if (FAILED(hr)) {
        std::cerr << "[capture] DuplicateOutput failed: 0x" << std::hex << hr << std::endl;
        return false;
    }

    return true;
}

bool DxgiCapture::CaptureFrame() {
    if (!duplication_) return false;
    if (hasFrame_) ReleaseFrame();

    DXGI_OUTDUPL_FRAME_INFO frameInfo;
    ComPtr<IDXGIResource> resource;

    HRESULT hr = duplication_->AcquireNextFrame(0, &frameInfo, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return false;  // No new frame
    if (FAILED(hr)) return false;

    hr = resource->QueryInterface(IID_PPV_ARGS(&frameTexture_));
    if (FAILED(hr)) {
        duplication_->ReleaseFrame();
        return false;
    }

    hasFrame_ = true;

    if (frameCallback_) {
        frameCallback_(frameTexture_, frameInfo.LastPresentTime.QuadPart);
    }

    return true;
}

void DxgiCapture::ReleaseFrame() {
    if (hasFrame_ && duplication_) {
        frameTexture_.Reset();
        duplication_->ReleaseFrame();
        hasFrame_ = false;
    }
}

void DxgiCapture::Shutdown() {
    ReleaseFrame();
    duplication_.Reset();
    context_.Reset();
    device_.Reset();
}

} // namespace peariscope
