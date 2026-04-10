#include "app/AvahiAdvertiser.h"

#include <avahi-client/client.h>
#include <avahi-client/publish.h>
#include <avahi-common/alternative.h>
#include <avahi-common/thread-watch.h>
#include <avahi-common/error.h>
#include <avahi-common/malloc.h>
#include <iostream>

// C-style callback trampolines that match Avahi's expected signatures
static void avahi_client_cb(AvahiClient* c, AvahiClientState state, void* ud) {
    static_cast<AvahiAdvertiser*>(ud)->onClientStateChanged(c, static_cast<int>(state));
}

static void avahi_group_cb(AvahiEntryGroup* g, AvahiEntryGroupState state, void* ud) {
    static_cast<AvahiAdvertiser*>(ud)->onGroupStateChanged(g, static_cast<int>(state));
}

AvahiAdvertiser::AvahiAdvertiser() = default;

AvahiAdvertiser::~AvahiAdvertiser() {
    Stop();
}

bool AvahiAdvertiser::Start(const std::string& code, const std::string& name, uint16_t port) {
    Stop();

    code_ = code;
    name_ = name;
    port_ = port;

    poll_ = avahi_threaded_poll_new();
    if (!poll_) {
        std::cerr << "[AvahiAdvertiser] Failed to create threaded poll\n";
        return false;
    }

    int error = 0;
    client_ = avahi_client_new(
        avahi_threaded_poll_get(poll_),
        AVAHI_CLIENT_NO_FAIL,
        avahi_client_cb, this, &error);

    if (!client_) {
        std::cerr << "[AvahiAdvertiser] Failed to create client: "
                  << avahi_strerror(error) << "\n";
        avahi_threaded_poll_free(poll_);
        poll_ = nullptr;
        return false;
    }

    if (avahi_threaded_poll_start(poll_) < 0) {
        std::cerr << "[AvahiAdvertiser] Failed to start threaded poll\n";
        avahi_client_free(client_);
        client_ = nullptr;
        avahi_threaded_poll_free(poll_);
        poll_ = nullptr;
        return false;
    }

    running_ = true;
    std::cerr << "[AvahiAdvertiser] Started advertising _peariscope._tcp\n";
    return true;
}

void AvahiAdvertiser::Stop() {
    if (!running_ && !poll_) return;

    if (poll_) avahi_threaded_poll_stop(poll_);
    if (group_) { avahi_entry_group_free(group_); group_ = nullptr; }
    if (client_) { avahi_client_free(client_); client_ = nullptr; }
    if (poll_) { avahi_threaded_poll_free(poll_); poll_ = nullptr; }

    running_ = false;
    std::cerr << "[AvahiAdvertiser] Stopped\n";
}

void AvahiAdvertiser::onClientStateChanged(AvahiClient* client, int state) {
    // Save client from callback — avahi_client_new() may not have returned yet
    client_ = client;
    switch (state) {
    case AVAHI_CLIENT_S_RUNNING:
        createServices();
        break;
    case AVAHI_CLIENT_FAILURE:
        std::cerr << "[AvahiAdvertiser] Client failure: "
                  << avahi_strerror(avahi_client_errno(client)) << "\n";
        avahi_threaded_poll_quit(poll_);
        break;
    case AVAHI_CLIENT_S_COLLISION:
    case AVAHI_CLIENT_S_REGISTERING:
        if (group_)
            avahi_entry_group_reset(group_);
        break;
    default:
        break;
    }
}

void AvahiAdvertiser::onGroupStateChanged(AvahiEntryGroup* group, int state) {
    switch (state) {
    case AVAHI_ENTRY_GROUP_ESTABLISHED:
        std::cerr << "[AvahiAdvertiser] Service established: " << name_ << "\n";
        break;
    case AVAHI_ENTRY_GROUP_COLLISION: {
        char* alt = avahi_alternative_service_name(name_.c_str());
        std::cerr << "[AvahiAdvertiser] Name collision, renaming to: " << alt << "\n";
        name_ = alt;
        avahi_free(alt);
        avahi_entry_group_reset(group);
        createServices();
        break;
    }
    case AVAHI_ENTRY_GROUP_FAILURE:
        std::cerr << "[AvahiAdvertiser] Entry group failure: "
                  << avahi_strerror(avahi_client_errno(avahi_entry_group_get_client(group))) << "\n";
        avahi_threaded_poll_quit(poll_);
        break;
    default:
        break;
    }
}

void AvahiAdvertiser::createServices() {
    if (!client_) return;
    if (!group_) {
        group_ = avahi_entry_group_new(client_, avahi_group_cb, this);
        if (!group_) {
            std::cerr << "[AvahiAdvertiser] Failed to create entry group: "
                      << avahi_strerror(avahi_client_errno(client_)) << "\n";
            avahi_threaded_poll_quit(poll_);
            return;
        }
    }

    std::string txtCode = "code=" + code_;
    std::string txtName = "name=" + name_;

    int ret = avahi_entry_group_add_service(
        group_,
        AVAHI_IF_UNSPEC,
        AVAHI_PROTO_UNSPEC,
        static_cast<AvahiPublishFlags>(0),
        name_.c_str(),
        "_peariscope._tcp",
        nullptr,
        nullptr,
        port_,
        txtCode.c_str(),
        txtName.c_str(),
        nullptr);

    if (ret < 0) {
        if (ret == AVAHI_ERR_COLLISION) {
            char* alt = avahi_alternative_service_name(name_.c_str());
            name_ = alt;
            avahi_free(alt);
            avahi_entry_group_reset(group_);
            createServices();
            return;
        }
        std::cerr << "[AvahiAdvertiser] Failed to add service: "
                  << avahi_strerror(ret) << "\n";
        avahi_threaded_poll_quit(poll_);
        return;
    }

    ret = avahi_entry_group_commit(group_);
    if (ret < 0) {
        std::cerr << "[AvahiAdvertiser] Failed to commit entry group: "
                  << avahi_strerror(ret) << "\n";
        avahi_threaded_poll_quit(poll_);
    }
}
