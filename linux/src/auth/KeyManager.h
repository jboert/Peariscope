#pragma once

#include <vector>
#include <string>
#include <cstdint>

namespace peariscope {

class KeyManager {
public:
    KeyManager();

    bool GetOrCreateDeviceKey(std::vector<uint8_t>& publicKey,
                              std::vector<uint8_t>& privateKey);
    std::string GetPublicKeyHex();

    struct TrustedDevice {
        std::string publicKeyHex;
        std::string name;
    };

    std::vector<TrustedDevice> LoadTrustedDevices();
    bool TrustDevice(const TrustedDevice& device);
    bool UntrustDevice(const std::string& publicKeyHex);

    // Secure PIN storage (encrypted on disk, equivalent to iOS Keychain)
    bool SavePin(const std::string& pin);
    std::string LoadPin();

    // Secure DHT keypair storage
    bool SaveDhtKeypair(const std::vector<uint8_t>& publicKey,
                        const std::vector<uint8_t>& secretKey);
    bool LoadDhtKeypair(std::vector<uint8_t>& publicKey,
                        std::vector<uint8_t>& secretKey);

private:
    bool SaveEncrypted(const std::string& name, const std::vector<uint8_t>& data);
    std::vector<uint8_t> LoadEncrypted(const std::string& name);
    std::vector<uint8_t> DeriveKey();
    std::string GetAppDataPath();
};

} // namespace peariscope
