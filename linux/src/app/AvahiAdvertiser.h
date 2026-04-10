#pragma once
#include <string>
#include <cstdint>

struct AvahiThreadedPoll;
struct AvahiClient;
struct AvahiEntryGroup;

class AvahiAdvertiser {
public:
    AvahiAdvertiser();
    ~AvahiAdvertiser();

    AvahiAdvertiser(const AvahiAdvertiser&) = delete;
    AvahiAdvertiser& operator=(const AvahiAdvertiser&) = delete;

    bool Start(const std::string& code, const std::string& name, uint16_t port = 9999);
    void Stop();
    bool IsRunning() const { return running_; }

    // Called by C callback trampolines — must be public
    void onClientStateChanged(AvahiClient* client, int state);
    void onGroupStateChanged(AvahiEntryGroup* group, int state);

private:
    void createServices();

    AvahiThreadedPoll* poll_    = nullptr;
    AvahiClient*       client_  = nullptr;
    AvahiEntryGroup*   group_   = nullptr;

    std::string code_;
    std::string name_;
    uint16_t    port_ = 9999;
    bool        running_ = false;
};
