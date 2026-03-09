#pragma once

#include <Windows.h>
#include <wincrypt.h>
#include <vector>
#include <string>
#include <cstdint>

namespace peariscope {

/// Manages device keys and trusted devices using DPAPI.
class KeyManager {
public:
    KeyManager();

    /// Get or create the device's key pair (stored via DPAPI)
    bool GetOrCreateDeviceKey(std::vector<uint8_t>& publicKey,
                              std::vector<uint8_t>& privateKey);

    /// Get public key as hex string
    std::string GetPublicKeyHex();

    struct TrustedDevice {
        std::string publicKeyHex;
        std::string name;
    };

    std::vector<TrustedDevice> LoadTrustedDevices();
    bool TrustDevice(const TrustedDevice& device);
    bool UntrustDevice(const std::string& publicKeyHex);

private:
    bool SaveEncrypted(const std::string& name, const std::vector<uint8_t>& data);
    std::vector<uint8_t> LoadEncrypted(const std::string& name);

    std::string GetAppDataPath();
};

} // namespace peariscope
