#include "NativeUpdater.h"

#include <filesystem>
#include <iostream>
#include <unistd.h>

namespace peariscope {

NativeUpdater::NativeUpdater(QObject* parent) : QObject(parent) {}
NativeUpdater::~NativeUpdater() = default;

void NativeUpdater::OnUpdateAvailable(const std::string& version,
                                       const std::string& downloadPath,
                                       const std::string& component) {
    pendingVersion_ = version;
    pendingDownloadPath_ = downloadPath;
    pendingComponent_ = component;
    hasPendingUpdate_.store(true);

    std::cerr << "[NativeUpdater] Update available: " << component
              << " v" << version << " at " << downloadPath << std::endl;

    emit updateReady(QString::fromStdString(version),
                     QString::fromStdString(component));
}

void NativeUpdater::ApplyUpdate() {
    if (!hasPendingUpdate_.load()) return;

    if (pendingComponent_ == "js") {
        // JS updates are handled by Pear runtime automatically on next launch.
        // Just restart the networking subprocess.
        std::cerr << "[NativeUpdater] JS update will apply on next restart" << std::endl;
        return;
    }

    // Native binary update: exec() the new binary to replace self
    if (pendingDownloadPath_.empty()) {
        std::cerr << "[NativeUpdater] No download path for native update" << std::endl;
        return;
    }

    std::filesystem::path newBinary(pendingDownloadPath_);
    if (!std::filesystem::exists(newBinary)) {
        std::cerr << "[NativeUpdater] Update binary not found: " << pendingDownloadPath_ << std::endl;
        return;
    }

    // Make executable
    std::filesystem::permissions(newBinary,
        std::filesystem::perms::owner_exec | std::filesystem::perms::owner_read,
        std::filesystem::perm_options::add);

    std::cerr << "[NativeUpdater] Relaunching with updated binary: " << pendingDownloadPath_ << std::endl;

    // Replace self with the new binary
    execl(pendingDownloadPath_.c_str(), pendingDownloadPath_.c_str(), nullptr);

    // If exec fails, we're still running the old binary
    std::cerr << "[NativeUpdater] exec() failed: " << strerror(errno) << std::endl;
}

} // namespace peariscope
