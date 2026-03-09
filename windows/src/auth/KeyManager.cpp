#include "KeyManager.h"
#include <ShlObj.h>
#include <fstream>
#include <filesystem>
#include <random>

namespace peariscope {

KeyManager::KeyManager() = default;

bool KeyManager::GetOrCreateDeviceKey(std::vector<uint8_t>& publicKey,
                                       std::vector<uint8_t>& privateKey) {
    auto existing = LoadEncrypted("device_key");
    if (existing.size() == 64) {
        privateKey.assign(existing.begin(), existing.begin() + 32);
        publicKey.assign(existing.begin() + 32, existing.end());
        return true;
    }

    // Generate random key pair (placeholder - should use proper crypto)
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> dist(0, 255);

    privateKey.resize(32);
    publicKey.resize(32);
    for (auto& b : privateKey) b = static_cast<uint8_t>(dist(gen));
    for (auto& b : publicKey) b = static_cast<uint8_t>(dist(gen));

    std::vector<uint8_t> combined(privateKey);
    combined.insert(combined.end(), publicKey.begin(), publicKey.end());
    SaveEncrypted("device_key", combined);

    return true;
}

std::string KeyManager::GetPublicKeyHex() {
    std::vector<uint8_t> pub, priv;
    GetOrCreateDeviceKey(pub, priv);

    std::string hex;
    for (auto b : pub) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", b);
        hex += buf;
    }
    return hex;
}

bool KeyManager::SaveEncrypted(const std::string& name, const std::vector<uint8_t>& data) {
    DATA_BLOB input;
    input.pbData = const_cast<BYTE*>(data.data());
    input.cbData = static_cast<DWORD>(data.size());

    DATA_BLOB output;
    if (!CryptProtectData(&input, nullptr, nullptr, nullptr, nullptr, 0, &output)) {
        return false;
    }

    auto path = GetAppDataPath() + "\\" + name + ".bin";
    std::ofstream file(path, std::ios::binary);
    if (!file) {
        LocalFree(output.pbData);
        return false;
    }
    file.write(reinterpret_cast<char*>(output.pbData), output.cbData);
    LocalFree(output.pbData);

    return true;
}

std::vector<uint8_t> KeyManager::LoadEncrypted(const std::string& name) {
    auto path = GetAppDataPath() + "\\" + name + ".bin";
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return {};

    auto size = file.tellg();
    file.seekg(0);
    std::vector<uint8_t> encrypted(size);
    file.read(reinterpret_cast<char*>(encrypted.data()), size);

    DATA_BLOB input;
    input.pbData = encrypted.data();
    input.cbData = static_cast<DWORD>(encrypted.size());

    DATA_BLOB output;
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, 0, &output)) {
        return {};
    }

    std::vector<uint8_t> result(output.pbData, output.pbData + output.cbData);
    LocalFree(output.pbData);

    return result;
}

std::string KeyManager::GetAppDataPath() {
    char path[MAX_PATH];
    SHGetFolderPathA(nullptr, CSIDL_APPDATA, nullptr, 0, path);
    std::string appPath = std::string(path) + "\\Peariscope";
    std::filesystem::create_directories(appPath);
    return appPath;
}

std::vector<KeyManager::TrustedDevice> KeyManager::LoadTrustedDevices() {
    // Simple JSON-like storage - for production, use proper serialization
    return {};
}

bool KeyManager::TrustDevice(const TrustedDevice& device) {
    // TODO: Implement trusted device storage
    return true;
}

bool KeyManager::UntrustDevice(const std::string& publicKeyHex) {
    // TODO: Implement trusted device removal
    return true;
}

} // namespace peariscope
