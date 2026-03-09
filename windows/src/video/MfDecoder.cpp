#include "MfDecoder.h"
#include <mfidl.h>
#include <mferror.h>
#include <iostream>

namespace peariscope {

MfDecoder::MfDecoder() = default;
MfDecoder::~MfDecoder() { Shutdown(); }

bool MfDecoder::Initialize(ID3D11Device* device, UINT width, UINT height) {
    MFStartup(MF_VERSION);

    // Create DXGI device manager
    if (FAILED(MFCreateDXGIDeviceManager(&resetToken_, &deviceManager_))) {
        return false;
    }
    if (FAILED(deviceManager_->ResetDevice(device, resetToken_))) {
        return false;
    }

    // Find hardware H.264 decoder
    MFT_REGISTER_TYPE_INFO inputType = { MFMediaType_Video, MFVideoFormat_H264 };
    MFT_REGISTER_TYPE_INFO outputType = { MFMediaType_Video, MFVideoFormat_NV12 };

    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        &inputType, &outputType,
        &activates, &count
    );

    if (FAILED(hr) || count == 0) {
        // Fall back to software decoder
        hr = MFTEnumEx(
            MFT_CATEGORY_VIDEO_DECODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            &inputType, &outputType,
            &activates, &count
        );
        if (FAILED(hr) || count == 0) return false;
    }

    hr = activates[0]->ActivateObject(IID_PPV_ARGS(&transform_));
    for (UINT32 i = 0; i < count; ++i) activates[i]->Release();
    CoTaskMemFree(activates);
    if (FAILED(hr)) return false;

    // Set input type (H.264)
    ComPtr<IMFMediaType> inputMediaType;
    MFCreateMediaType(&inputMediaType);
    inputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    inputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    MFSetAttributeSize(inputMediaType.Get(), MF_MT_FRAME_SIZE, width, height);

    hr = transform_->SetInputType(0, inputMediaType.Get(), 0);
    if (FAILED(hr)) return false;

    // Set output type (NV12 for GPU)
    ComPtr<IMFMediaType> outputMediaType;
    MFCreateMediaType(&outputMediaType);
    outputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(outputMediaType.Get(), MF_MT_FRAME_SIZE, width, height);

    hr = transform_->SetOutputType(0, outputMediaType.Get(), 0);
    if (FAILED(hr)) return false;

    // Provide DXGI device manager
    transform_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
        reinterpret_cast<ULONG_PTR>(deviceManager_.Get()));

    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    return true;
}

bool MfDecoder::Decode(const uint8_t* data, size_t size) {
    if (!transform_) return false;

    // Create sample from raw H.264 data
    ComPtr<IMFMediaBuffer> buffer;
    MFCreateMemoryBuffer(static_cast<DWORD>(size), &buffer);

    BYTE* bufData = nullptr;
    buffer->Lock(&bufData, nullptr, nullptr);
    memcpy(bufData, data, size);
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(size));

    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buffer.Get());

    HRESULT hr = transform_->ProcessInput(0, sample.Get(), 0);
    if (FAILED(hr)) return false;

    return ProcessOutput();
}

bool MfDecoder::ProcessOutput() {
    MFT_OUTPUT_DATA_BUFFER outputBuffer = {};
    DWORD status = 0;

    // Let the decoder allocate its own output sample (for GPU textures)
    HRESULT hr = transform_->ProcessOutput(0, 1, &outputBuffer, &status);
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
    if (FAILED(hr)) return false;

    if (outputBuffer.pSample && callback_) {
        // Extract D3D11 texture from the decoded sample
        ComPtr<IMFMediaBuffer> mediaBuffer;
        outputBuffer.pSample->ConvertToContiguousBuffer(&mediaBuffer);

        ComPtr<IMFDXGIBuffer> dxgiBuffer;
        if (SUCCEEDED(mediaBuffer->QueryInterface(IID_PPV_ARGS(&dxgiBuffer)))) {
            ComPtr<ID3D11Texture2D> texture;
            if (SUCCEEDED(dxgiBuffer->GetResource(IID_PPV_ARGS(&texture)))) {
                MFTIME timestamp = 0;
                outputBuffer.pSample->GetSampleTime(&timestamp);
                callback_(texture, timestamp);
            }
        }
    }

    if (outputBuffer.pSample) outputBuffer.pSample->Release();
    if (outputBuffer.pEvents) outputBuffer.pEvents->Release();

    return true;
}

void MfDecoder::Shutdown() {
    if (transform_) {
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        transform_.Reset();
    }
    deviceManager_.Reset();
    MFShutdown();
}

} // namespace peariscope
