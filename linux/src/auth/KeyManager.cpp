#include "KeyManager.h"

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <filesystem>
#include <fstream>
#include <unistd.h>
#include <sstream>
#include <iomanip>
#include <cstring>

namespace peariscope {

namespace fs = std::filesystem;

KeyManager::KeyManager() {}

std::string KeyManager::GetAppDataPath() {
    const char* home = getenv("HOME");
    if (!home) home = "/tmp";
    std::string path = std::string(home) + "/.config/peariscope";
    fs::create_directories(path);
    return path;
}

std::vector<uint8_t> KeyManager::DeriveKey() {
    // Read machine-id
    std::string machineId;
    {
        std::ifstream f("/etc/machine-id");
        if (f.is_open()) {
            std::getline(f, machineId);
        }
    }
    if (machineId.empty()) {
        machineId = "fallback-machine-id";
    }

    // Combine with uid
    uid_t uid = getuid();
    std::string salt = machineId + ":" + std::to_string(uid);

    // Derive 256-bit key via PBKDF2
    std::vector<uint8_t> key(32);
    PKCS5_PBKDF2_HMAC(
        salt.c_str(), static_cast<int>(salt.size()),
        reinterpret_cast<const unsigned char*>("peariscope-device-key"), 21,
        100000,
        EVP_sha256(),
        32, key.data()
    );

    return key;
}

bool KeyManager::SaveEncrypted(const std::string& name, const std::vector<uint8_t>& data) {
    std::vector<uint8_t> key = DeriveKey();

    // Generate random 12-byte IV
    std::vector<uint8_t> iv(12);
    if (RAND_bytes(iv.data(), 12) != 1) return false;

    // Encrypt with AES-256-GCM
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return false;

    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return false;
    }

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return false;
    }

    if (EVP_EncryptInit_ex(ctx, nullptr, nullptr, key.data(), iv.data()) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return false;
    }

    std::vector<uint8_t> ciphertext(data.size() + 16);
    int outLen = 0;
    if (EVP_EncryptUpdate(ctx, ciphertext.data(), &outLen,
                          data.data(), static_cast<int>(data.size())) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return false;
    }
    int totalLen = outLen;

    int finalLen = 0;
    if (EVP_EncryptFinal_ex(ctx, ciphertext.data() + totalLen, &finalLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return false;
    }
    totalLen += finalLen;
    ciphertext.resize(totalLen);

    // Get tag
    std::vector<uint8_t> tag(16);
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag.data()) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return false;
    }

    EVP_CIPHER_CTX_free(ctx);

    // Write IV + ciphertext + tag to file
    std::string filePath = GetAppDataPath() + "/" + name;
    std::ofstream file(filePath, std::ios::binary);
    if (!file.is_open()) return false;

    file.write(reinterpret_cast<const char*>(iv.data()), iv.size());
    file.write(reinterpret_cast<const char*>(ciphertext.data()), ciphertext.size());
    file.write(reinterpret_cast<const char*>(tag.data()), tag.size());
    file.close();

    return file.good();
}

std::vector<uint8_t> KeyManager::LoadEncrypted(const std::string& name) {
    std::string filePath = GetAppDataPath() + "/" + name;
    std::ifstream file(filePath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) return {};

    auto fileSize = file.tellg();
    if (fileSize < 12 + 16) return {}; // IV (12) + tag (16) minimum
    file.seekg(0);

    std::vector<uint8_t> fileData(fileSize);
    file.read(reinterpret_cast<char*>(fileData.data()), fileSize);
    file.close();

    // Extract IV (12 bytes), ciphertext, tag (16 bytes)
    std::vector<uint8_t> iv(fileData.begin(), fileData.begin() + 12);
    std::vector<uint8_t> tag(fileData.end() - 16, fileData.end());
    std::vector<uint8_t> ciphertext(fileData.begin() + 12, fileData.end() - 16);

    std::vector<uint8_t> key = DeriveKey();

    // Decrypt with AES-256-GCM
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return {};

    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return {};
    }

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return {};
    }

    if (EVP_DecryptInit_ex(ctx, nullptr, nullptr, key.data(), iv.data()) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return {};
    }

    std::vector<uint8_t> plaintext(ciphertext.size());
    int outLen = 0;
    if (EVP_DecryptUpdate(ctx, plaintext.data(), &outLen,
                          ciphertext.data(), static_cast<int>(ciphertext.size())) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return {};
    }
    int totalLen = outLen;

    // Set tag before finalizing
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16,
                            const_cast<uint8_t*>(tag.data())) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return {};
    }

    int finalLen = 0;
    if (EVP_DecryptFinal_ex(ctx, plaintext.data() + totalLen, &finalLen) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return {};
    }
    totalLen += finalLen;
    plaintext.resize(totalLen);

    EVP_CIPHER_CTX_free(ctx);
    return plaintext;
}

bool KeyManager::GetOrCreateDeviceKey(std::vector<uint8_t>& publicKey,
                                       std::vector<uint8_t>& privateKey) {
    std::string keyFile = GetAppDataPath() + "/device_key";

    if (fs::exists(keyFile)) {
        // Load existing key
        std::vector<uint8_t> loaded = LoadEncrypted("device_key");
        if (loaded.size() == 32) {
            privateKey = loaded;

            // Derive public key as SHA-256 of private key
            publicKey.resize(32);
            SHA256(privateKey.data(), privateKey.size(), publicKey.data());
            return true;
        }
    }

    // Generate new 32-byte private key
    privateKey.resize(32);
    if (RAND_bytes(privateKey.data(), 32) != 1) return false;

    // Derive public key as SHA-256 of private key
    publicKey.resize(32);
    SHA256(privateKey.data(), privateKey.size(), publicKey.data());

    // Save encrypted
    if (!SaveEncrypted("device_key", privateKey)) return false;

    return true;
}

std::string KeyManager::GetPublicKeyHex() {
    std::vector<uint8_t> pubKey, privKey;
    if (!GetOrCreateDeviceKey(pubKey, privKey)) return "";

    std::ostringstream oss;
    for (uint8_t b : pubKey) {
        oss << std::hex << std::setfill('0') << std::setw(2) << static_cast<int>(b);
    }
    return oss.str();
}

std::vector<KeyManager::TrustedDevice> KeyManager::LoadTrustedDevices() {
    std::vector<TrustedDevice> devices;
    std::string filePath = GetAppDataPath() + "/trusted_devices.txt";

    std::ifstream file(filePath);
    if (!file.is_open()) return devices;

    std::string line;
    while (std::getline(file, line)) {
        if (line.empty()) continue;
        auto tabPos = line.find('\t');
        if (tabPos == std::string::npos) continue;

        TrustedDevice dev;
        dev.publicKeyHex = line.substr(0, tabPos);
        dev.name = line.substr(tabPos + 1);
        devices.push_back(dev);
    }

    return devices;
}

bool KeyManager::TrustDevice(const TrustedDevice& device) {
    auto devices = LoadTrustedDevices();

    // Check if already trusted
    for (const auto& d : devices) {
        if (d.publicKeyHex == device.publicKeyHex) return true;
    }

    devices.push_back(device);

    // Save all devices
    std::string filePath = GetAppDataPath() + "/trusted_devices.txt";
    std::ofstream file(filePath);
    if (!file.is_open()) return false;

    for (const auto& d : devices) {
        file << d.publicKeyHex << "\t" << d.name << "\n";
    }

    return file.good();
}

bool KeyManager::UntrustDevice(const std::string& publicKeyHex) {
    auto devices = LoadTrustedDevices();

    std::string filePath = GetAppDataPath() + "/trusted_devices.txt";
    std::ofstream file(filePath);
    if (!file.is_open()) return false;

    for (const auto& d : devices) {
        if (d.publicKeyHex != publicKeyHex) {
            file << d.publicKeyHex << "\t" << d.name << "\n";
        }
    }

    return file.good();
}

bool KeyManager::SavePin(const std::string& pin) {
    std::vector<uint8_t> data(pin.begin(), pin.end());
    return SaveEncrypted("pin_code", data);
}

std::string KeyManager::LoadPin() {
    auto data = LoadEncrypted("pin_code");
    if (data.empty()) return "";
    return std::string(data.begin(), data.end());
}

bool KeyManager::SaveDhtKeypair(const std::vector<uint8_t>& publicKey,
                                 const std::vector<uint8_t>& secretKey) {
    if (publicKey.size() != 32 || secretKey.size() != 32) return false;
    std::vector<uint8_t> combined;
    combined.reserve(64);
    combined.insert(combined.end(), publicKey.begin(), publicKey.end());
    combined.insert(combined.end(), secretKey.begin(), secretKey.end());
    return SaveEncrypted("dht_keypair", combined);
}

bool KeyManager::LoadDhtKeypair(std::vector<uint8_t>& publicKey,
                                 std::vector<uint8_t>& secretKey) {
    auto data = LoadEncrypted("dht_keypair");
    if (data.size() != 64) return false;
    publicKey.assign(data.begin(), data.begin() + 32);
    secretKey.assign(data.begin() + 32, data.end());
    return true;
}

} // namespace peariscope
