#include "MfEncoder.h"
#include <mfidl.h>
#include <mferror.h>
#include <iostream>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")

namespace peariscope {

MfEncoder::MfEncoder() = default;
MfEncoder::~MfEncoder() { Shutdown(); }

bool MfEncoder::Initialize(ID3D11Device* device, UINT width, UINT height,
                            UINT fps, UINT bitrate) {
    width_ = width;
    height_ = height;

    // Initialize Media Foundation
    MFStartup(MF_VERSION);

    // Create DXGI device manager for GPU-based encoding
    if (FAILED(MFCreateDXGIDeviceManager(&resetToken_, &deviceManager_))) {
        return false;
    }
    if (FAILED(deviceManager_->ResetDevice(device, resetToken_))) {
        return false;
    }

    return CreateEncoder(device, width, height, fps, bitrate);
}

bool MfEncoder::CreateEncoder(ID3D11Device* device, UINT width, UINT height,
                               UINT fps, UINT bitrate) {
    // Find hardware H.264 encoder
    MFT_REGISTER_TYPE_INFO inputType = { MFMediaType_Video, MFVideoFormat_NV12 };
    MFT_REGISTER_TYPE_INFO outputType = { MFMediaType_Video, MFVideoFormat_H264 };

    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        &inputType, &outputType,
        &activates, &count
    );

    if (FAILED(hr) || count == 0) {
        std::cerr << "[encoder] No hardware H.264 encoder found" << std::endl;
        // Fall back to software
        hr = MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
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

    // Set output type (H.264)
    ComPtr<IMFMediaType> outputMediaType;
    MFCreateMediaType(&outputMediaType);
    outputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    outputMediaType->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    MFSetAttributeSize(outputMediaType.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(outputMediaType.Get(), MF_MT_FRAME_RATE, fps, 1);
    outputMediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    outputMediaType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);

    hr = transform_->SetOutputType(0, outputMediaType.Get(), 0);
    if (FAILED(hr)) return false;

    // Set input type (NV12)
    ComPtr<IMFMediaType> inputMediaType;
    MFCreateMediaType(&inputMediaType);
    inputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    inputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(inputMediaType.Get(), MF_MT_FRAME_SIZE, width, height);
    MFSetAttributeRatio(inputMediaType.Get(), MF_MT_FRAME_RATE, fps, 1);
    inputMediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

    hr = transform_->SetInputType(0, inputMediaType.Get(), 0);
    if (FAILED(hr)) return false;

    // Enable low latency mode
    ComPtr<ICodecAPI> codecApi;
    if (SUCCEEDED(transform_->QueryInterface(IID_PPV_ARGS(&codecApi)))) {
        VARIANT var;
        var.vt = VT_BOOL;
        var.boolVal = VARIANT_TRUE;
        codecApi->SetValue(&CODECAPI_AVLowLatencyMode, &var);

        // Disable B-frames
        var.vt = VT_UI4;
        var.ulVal = 0;
        codecApi->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &var);
    }

    // Provide DXGI device manager for GPU processing
    transform_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
        reinterpret_cast<ULONG_PTR>(deviceManager_.Get()));

    // Start streaming
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    return true;
}

bool MfEncoder::Encode(ID3D11Texture2D* texture, UINT64 timestamp) {
    if (!transform_) return false;

    if (forceKeyframe_) {
        ComPtr<ICodecAPI> codecApi;
        if (SUCCEEDED(transform_->QueryInterface(IID_PPV_ARGS(&codecApi)))) {
            VARIANT var;
            var.vt = VT_UI4;
            var.ulVal = 1;
            codecApi->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &var);
        }
        forceKeyframe_ = false;
    }

    // Create MF sample from D3D11 texture
    ComPtr<IMFMediaBuffer> buffer;
    MFCreateDXGISurfaceBuffer(IID_ID3D11Texture2D, texture, 0, FALSE, &buffer);

    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(timestamp);
    sample->SetSampleDuration(166667); // ~60fps

    HRESULT hr = transform_->ProcessInput(0, sample.Get(), 0);
    if (FAILED(hr)) return false;

    return ProcessOutput();
}

bool MfEncoder::ProcessOutput() {
    MFT_OUTPUT_DATA_BUFFER outputBuffer = {};
    DWORD status = 0;

    // Allocate output sample
    ComPtr<IMFSample> outputSample;
    MFCreateSample(&outputSample);
    ComPtr<IMFMediaBuffer> outputBuf;
    MFCreateMemoryBuffer(1024 * 1024, &outputBuf); // 1MB buffer
    outputSample->AddBuffer(outputBuf.Get());
    outputBuffer.pSample = outputSample.Get();

    HRESULT hr = transform_->ProcessOutput(0, 1, &outputBuffer, &status);
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true; // Need more frames
    if (FAILED(hr)) return false;

    // Extract encoded data
    ComPtr<IMFMediaBuffer> encodedBuffer;
    outputBuffer.pSample->ConvertToContiguousBuffer(&encodedBuffer);

    BYTE* data = nullptr;
    DWORD length = 0;
    encodedBuffer->Lock(&data, nullptr, &length);

    if (callback_ && data && length > 0) {
        // Check if keyframe by looking for IDR NAL type
        bool isKeyframe = false;
        for (DWORD i = 0; i + 4 < length; ++i) {
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1) {
                uint8_t nalType = data[i+4] & 0x1F;
                if (nalType == 5) { isKeyframe = true; break; }
            }
        }
        callback_(data, length, isKeyframe);
    }

    encodedBuffer->Unlock();

    if (outputBuffer.pEvents) outputBuffer.pEvents->Release();

    return true;
}

void MfEncoder::ForceKeyframe() {
    forceKeyframe_ = true;
}

void MfEncoder::SetBitrate(UINT bitrate) {
    if (!transform_) return;
    ComPtr<ICodecAPI> codecApi;
    if (SUCCEEDED(transform_->QueryInterface(IID_PPV_ARGS(&codecApi)))) {
        VARIANT var;
        var.vt = VT_UI4;
        var.ulVal = bitrate;
        codecApi->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &var);
    }
}

void MfEncoder::Shutdown() {
    if (transform_) {
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        transform_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
        transform_.Reset();
    }
    deviceManager_.Reset();
    MFShutdown();
}

} // namespace peariscope
