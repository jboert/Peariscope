#include "PipewireCapture.h"

#ifndef Q_MOC_RUN
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <spa/debug/types.h>
#include <spa/utils/result.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <sys/shm.h>

#include <dbus/dbus.h>
#endif

#include <sys/time.h>
#include <unistd.h>
#include <iostream>
#include <fstream>
#include <cstring>
#include <chrono>
#include <algorithm>

namespace peariscope {

// -----------------------------------------------------------------------
// Restore-token persistence (avoids dialog on subsequent runs)
// -----------------------------------------------------------------------

static std::string tokenPath() {
    const char* home = getenv("HOME");
    if (!home) home = "/tmp";
    return std::string(home) + "/.config/peariscope/screencast-token";
}

static std::string loadToken() {
    std::ifstream f(tokenPath());
    std::string t;
    if (f.good()) std::getline(f, t);
    return t;
}

static void saveToken(const std::string& tok) {
    std::string dir = tokenPath();
    dir = dir.substr(0, dir.rfind('/'));
    // ensure dir exists
    std::string cmd = "mkdir -p '" + dir + "'";
    (void)system(cmd.c_str());
    std::ofstream f(tokenPath());
    if (f.good()) f << tok;
}

// -----------------------------------------------------------------------
// dbus-1 helpers
// -----------------------------------------------------------------------

static void appendStringVariant(DBusMessageIter* dict, const char* key, const char* val) {
    DBusMessageIter entry, variant;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &val);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(dict, &entry);
}

static void appendUint32Variant(DBusMessageIter* dict, const char* key, uint32_t val) {
    DBusMessageIter entry, variant;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &val);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(dict, &entry);
}

static void appendBoolVariant(DBusMessageIter* dict, const char* key, dbus_bool_t val) {
    DBusMessageIter entry, variant;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_BOOLEAN, &val);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(dict, &entry);
}

// Wait for a Response signal on reqPath. Returns response code (0 = success).
// Fills outResults with key/value pairs. Fills outNodeId if streams found.
// Fills outRestoreToken if restore_token found.
static int waitForResponse(DBusConnection* conn, const std::string& reqPath,
                           uint32_t& outNodeId, std::string& outRestoreToken,
                           int timeoutSec = 120) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutSec);

    while (std::chrono::steady_clock::now() < deadline) {
        dbus_connection_read_write(conn, 200);
        DBusMessage* sig = dbus_connection_pop_message(conn);
        if (!sig) continue;

        if (dbus_message_is_signal(sig, "org.freedesktop.portal.Request", "Response") &&
            dbus_message_get_path(sig) &&
            std::string(dbus_message_get_path(sig)) == reqPath) {

            DBusMessageIter args;
            if (!dbus_message_iter_init(sig, &args)) {
                dbus_message_unref(sig);
                return 1;
            }

            // First arg: uint32 response
            uint32_t response = 1;
            if (dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_UINT32) {
                dbus_message_iter_get_basic(&args, &response);
            }
            dbus_message_iter_next(&args);

            // Second arg: a{sv} results
            if (dbus_message_iter_get_arg_type(&args) == DBUS_TYPE_ARRAY) {
                DBusMessageIter dictIter;
                dbus_message_iter_recurse(&args, &dictIter);

                while (dbus_message_iter_get_arg_type(&dictIter) == DBUS_TYPE_DICT_ENTRY) {
                    DBusMessageIter entry;
                    dbus_message_iter_recurse(&dictIter, &entry);

                    const char* key = nullptr;
                    dbus_message_iter_get_basic(&entry, &key);
                    dbus_message_iter_next(&entry);

                    // entry is now at the variant
                    DBusMessageIter variant;
                    dbus_message_iter_recurse(&entry, &variant);
                    int vtype = dbus_message_iter_get_arg_type(&variant);

                    if (key && strcmp(key, "restore_token") == 0 && vtype == DBUS_TYPE_STRING) {
                        const char* tok = nullptr;
                        dbus_message_iter_get_basic(&variant, &tok);
                        if (tok) outRestoreToken = tok;
                    }

                    if (key && strcmp(key, "session_handle") == 0 && vtype == DBUS_TYPE_OBJECT_PATH) {
                        // We don't need to extract this separately, it's in the session
                    }

                    // Parse streams: a(ua{sv})
                    if (key && strcmp(key, "streams") == 0 && vtype == DBUS_TYPE_ARRAY) {
                        DBusMessageIter arrIter;
                        dbus_message_iter_recurse(&variant, &arrIter);
                        if (dbus_message_iter_get_arg_type(&arrIter) == DBUS_TYPE_STRUCT) {
                            DBusMessageIter structIter;
                            dbus_message_iter_recurse(&arrIter, &structIter);
                            if (dbus_message_iter_get_arg_type(&structIter) == DBUS_TYPE_UINT32) {
                                dbus_message_iter_get_basic(&structIter, &outNodeId);
                            }
                        }
                    }

                    dbus_message_iter_next(&dictIter);
                }
            }

            dbus_message_unref(sig);
            return static_cast<int>(response);
        }

        dbus_message_unref(sig);
    }
    return -1; // timeout
}

// -----------------------------------------------------------------------
// Portal negotiation using dbus-1 C API
// -----------------------------------------------------------------------

static bool portalNegotiate(int& outFd, uint32_t& outNodeId) {
    DBusError err;
    dbus_error_init(&err);

    DBusConnection* conn = dbus_bus_get(DBUS_BUS_SESSION, &err);
    if (!conn || dbus_error_is_set(&err)) {
        std::cerr << "[PwCapture] D-Bus session bus: "
                  << (dbus_error_is_set(&err) ? err.message : "null") << std::endl;
        dbus_error_free(&err);
        return false;
    }

    // Build sender slug: ":1.42" → "1_42"
    const char* uniqueName = dbus_bus_get_unique_name(conn);
    std::string sender(uniqueName + 1);
    std::replace(sender.begin(), sender.end(), '.', '_');

    std::string pid = std::to_string(getpid());
    std::string sessionHandle;

    // Load saved restore token
    std::string restoreToken = loadToken();
    if (!restoreToken.empty())
        std::cerr << "[PwCapture] Have restore token — will skip dialog" << std::endl;

    // --- CreateSession ---
    {
        std::string token = "peariscope_cs_" + pid;
        std::string sessionToken = "peariscope_s_" + pid;
        std::string reqPath = "/org/freedesktop/portal/desktop/request/" + sender + "/" + token;

        std::string match = "type='signal',interface='org.freedesktop.portal.Request',"
                            "member='Response',path='" + reqPath + "'";
        dbus_bus_add_match(conn, match.c_str(), nullptr);
        dbus_connection_flush(conn);

        DBusMessage* msg = dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast",
            "CreateSession");

        DBusMessageIter args, dict;
        dbus_message_iter_init_append(msg, &args);
        dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
        appendStringVariant(&dict, "handle_token", token.c_str());
        appendStringVariant(&dict, "session_handle_token", sessionToken.c_str());
        dbus_message_iter_close_container(&args, &dict);

        DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
        dbus_message_unref(msg);
        if (!reply || dbus_error_is_set(&err)) {
            std::cerr << "[PwCapture] CreateSession: "
                      << (dbus_error_is_set(&err) ? err.message : "no reply") << std::endl;
            dbus_error_free(&err);
            return false;
        }
        dbus_message_unref(reply);

        uint32_t dummy = 0;
        std::string dummyTok;
        int resp = waitForResponse(conn, reqPath, dummy, dummyTok, 10);
        if (resp != 0) {
            std::cerr << "[PwCapture] CreateSession denied (" << resp << ")" << std::endl;
            return false;
        }

        sessionHandle = "/org/freedesktop/portal/desktop/session/" + sender +
                        "/peariscope_s_" + pid;
        std::cerr << "[PwCapture] Session: " << sessionHandle << std::endl;
    }

    // --- SelectSources ---
    {
        std::string token = "peariscope_ss_" + pid;
        std::string reqPath = "/org/freedesktop/portal/desktop/request/" + sender + "/" + token;

        std::string match = "type='signal',interface='org.freedesktop.portal.Request',"
                            "member='Response',path='" + reqPath + "'";
        dbus_bus_add_match(conn, match.c_str(), nullptr);
        dbus_connection_flush(conn);

        DBusMessage* msg = dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast",
            "SelectSources");

        DBusMessageIter args, dict;
        dbus_message_iter_init_append(msg, &args);

        // session_handle (object path)
        const char* sh = sessionHandle.c_str();
        dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &sh);

        // options dict
        dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
        appendStringVariant(&dict, "handle_token", token.c_str());
        appendUint32Variant(&dict, "types", 1);        // MONITOR
        appendUint32Variant(&dict, "cursor_mode", 2);  // EMBEDDED
        appendUint32Variant(&dict, "persist_mode", 2); // persist until revoked

        if (!restoreToken.empty())
            appendStringVariant(&dict, "restore_token", restoreToken.c_str());

        dbus_message_iter_close_container(&args, &dict);

        DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
        dbus_message_unref(msg);
        if (!reply || dbus_error_is_set(&err)) {
            std::cerr << "[PwCapture] SelectSources: "
                      << (dbus_error_is_set(&err) ? err.message : "no reply") << std::endl;
            dbus_error_free(&err);
            return false;
        }
        dbus_message_unref(reply);

        uint32_t dummy = 0;
        std::string dummyTok;
        int resp = waitForResponse(conn, reqPath, dummy, dummyTok, 120);
        if (resp != 0) {
            std::cerr << "[PwCapture] SelectSources denied (" << resp << ")" << std::endl;
            return false;
        }
    }

    // --- Start ---
    {
        std::string token = "peariscope_st_" + pid;
        std::string reqPath = "/org/freedesktop/portal/desktop/request/" + sender + "/" + token;

        std::string match = "type='signal',interface='org.freedesktop.portal.Request',"
                            "member='Response',path='" + reqPath + "'";
        dbus_bus_add_match(conn, match.c_str(), nullptr);
        dbus_connection_flush(conn);

        DBusMessage* msg = dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast",
            "Start");

        DBusMessageIter args, dict;
        dbus_message_iter_init_append(msg, &args);

        const char* sh = sessionHandle.c_str();
        dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &sh);

        const char* emptyStr = "";
        dbus_message_iter_append_basic(&args, DBUS_TYPE_STRING, &emptyStr); // parent_window

        dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
        appendStringVariant(&dict, "handle_token", token.c_str());
        dbus_message_iter_close_container(&args, &dict);

        DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
        dbus_message_unref(msg);
        if (!reply || dbus_error_is_set(&err)) {
            std::cerr << "[PwCapture] Start: "
                      << (dbus_error_is_set(&err) ? err.message : "no reply") << std::endl;
            dbus_error_free(&err);
            return false;
        }
        dbus_message_unref(reply);

        std::string newToken;
        int resp = waitForResponse(conn, reqPath, outNodeId, newToken, 120);
        if (resp != 0) {
            std::cerr << "[PwCapture] Start denied (" << resp << ")" << std::endl;
            return false;
        }

        // Save restore token for next time (skip dialog)
        if (!newToken.empty()) {
            saveToken(newToken);
            std::cerr << "[PwCapture] Saved restore token for future sessions" << std::endl;
        }

        if (outNodeId == 0) {
            std::cerr << "[PwCapture] No streams returned" << std::endl;
            return false;
        }
    }

    // --- OpenPipeWireRemote ---
    {
        DBusMessage* msg = dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast",
            "OpenPipeWireRemote");

        DBusMessageIter args, dict;
        dbus_message_iter_init_append(msg, &args);

        const char* sh = sessionHandle.c_str();
        dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &sh);

        dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &dict);
        dbus_message_iter_close_container(&args, &dict);

        DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err);
        dbus_message_unref(msg);
        if (!reply || dbus_error_is_set(&err)) {
            std::cerr << "[PwCapture] OpenPipeWireRemote: "
                      << (dbus_error_is_set(&err) ? err.message : "no reply") << std::endl;
            dbus_error_free(&err);
            return false;
        }

        DBusMessageIter replyArgs;
        if (dbus_message_iter_init(reply, &replyArgs) &&
            dbus_message_iter_get_arg_type(&replyArgs) == DBUS_TYPE_UNIX_FD) {
            int fd = -1;
            dbus_message_iter_get_basic(&replyArgs, &fd);
            outFd = dup(fd);
        }
        dbus_message_unref(reply);

        if (outFd < 0) {
            std::cerr << "[PwCapture] Failed to get PipeWire fd" << std::endl;
            return false;
        }
    }

    std::cerr << "[PwCapture] Portal OK — node_id=" << outNodeId
              << " fd=" << outFd << std::endl;
    return true;
}

// -----------------------------------------------------------------------
// PipeWire stream state (passed as userdata to PW callbacks)
// -----------------------------------------------------------------------

struct PwStreamState {
    PipewireCapture::FrameCallback callback;
    std::atomic<bool>* running = nullptr;
    pw_stream* stream = nullptr;
    struct spa_hook streamListener{};

    uint32_t width = 0;
    uint32_t height = 0;
    enum spa_video_format format = SPA_VIDEO_FORMAT_UNKNOWN;
    bool needsRgbSwap = false;
    std::vector<uint8_t> convertBuf;
};

// -----------------------------------------------------------------------
// X11/XShm capture (fallback for X11 sessions)
// -----------------------------------------------------------------------

struct XShmCapture {
    Display* display = nullptr;
    Window root = 0;
    XShmSegmentInfo shmInfo{};
    XImage* image = nullptr;
    int screenWidth = 0;
    int screenHeight = 0;
    bool attached = false;

    bool Init() {
        display = XOpenDisplay(nullptr);
        if (!display) return false;

        int screen = DefaultScreen(display);
        root = RootWindow(display, screen);
        screenWidth = DisplayWidth(display, screen);
        screenHeight = DisplayHeight(display, screen);

        if (!XShmQueryExtension(display)) {
            XCloseDisplay(display);
            display = nullptr;
            return false;
        }

        image = XShmCreateImage(
            display,
            DefaultVisual(display, screen),
            static_cast<unsigned int>(DefaultDepth(display, screen)),
            ZPixmap, nullptr, &shmInfo,
            static_cast<unsigned int>(screenWidth),
            static_cast<unsigned int>(screenHeight));
        if (!image) {
            XCloseDisplay(display);
            display = nullptr;
            return false;
        }

        shmInfo.shmid = shmget(
            IPC_PRIVATE,
            static_cast<size_t>(image->bytes_per_line * image->height),
            IPC_CREAT | 0600);
        if (shmInfo.shmid < 0) {
            XDestroyImage(image); image = nullptr;
            XCloseDisplay(display); display = nullptr;
            return false;
        }

        shmInfo.shmaddr = image->data = static_cast<char*>(shmat(shmInfo.shmid, nullptr, 0));
        shmInfo.readOnly = False;

        if (!XShmAttach(display, &shmInfo)) {
            shmdt(shmInfo.shmaddr);
            shmctl(shmInfo.shmid, IPC_RMID, nullptr);
            XDestroyImage(image); image = nullptr;
            XCloseDisplay(display); display = nullptr;
            return false;
        }
        attached = true;
        shmctl(shmInfo.shmid, IPC_RMID, nullptr);
        return true;
    }

    void Destroy() {
        if (display && attached) { XShmDetach(display, &shmInfo); attached = false; }
        if (shmInfo.shmaddr) { shmdt(shmInfo.shmaddr); shmInfo.shmaddr = nullptr; }
        if (image) { image->data = nullptr; XDestroyImage(image); image = nullptr; }
        if (display) { XCloseDisplay(display); display = nullptr; }
    }

    bool Grab() {
        if (!display || !image) return false;
        return XShmGetImage(display, root, image, 0, 0, AllPlanes) == True;
    }
};

// -----------------------------------------------------------------------
// PipeWire stream callbacks
// -----------------------------------------------------------------------

static void pwStateChanged(void* /*data*/, enum pw_stream_state old,
                           enum pw_stream_state state, const char* error) {
    std::cerr << "[PwCapture] Stream: "
              << pw_stream_state_as_string(old) << " → "
              << pw_stream_state_as_string(state);
    if (error) std::cerr << " (" << error << ")";
    std::cerr << std::endl;
}

static void pwParamChanged(void* userdata, uint32_t id,
                           const struct ::spa_pod* param) {
    auto* st = static_cast<PwStreamState*>(userdata);
    if (!param || id != SPA_PARAM_Format) return;

    struct spa_video_info_raw info;
    if (spa_format_video_raw_parse(param, &info) < 0) return;

    st->format = info.format;
    st->width = info.size.width;
    st->height = info.size.height;
    st->needsRgbSwap = (info.format == SPA_VIDEO_FORMAT_RGBx ||
                        info.format == SPA_VIDEO_FORMAT_RGBA);

    std::cerr << "[PwCapture] Negotiated: " << st->width << "x" << st->height
              << " fmt=" << spa_debug_type_find_name(spa_type_video_format, info.format)
              << std::endl;

    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));

    const struct ::spa_pod* params[1];
    params[0] = static_cast<const struct ::spa_pod*>(
        spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
            SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 8),
            SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(
                (1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd) | (1 << SPA_DATA_DmaBuf))));

    pw_stream_update_params(st->stream, params, 1);
}

static void pwProcess(void* userdata) {
    auto* st = static_cast<PwStreamState*>(userdata);

    struct pw_buffer* b = pw_stream_dequeue_buffer(st->stream);
    if (!b) return;

    struct spa_buffer* buf = b->buffer;

    if (buf->n_datas >= 1 && buf->datas[0].data && st->callback &&
        st->running->load(std::memory_order_acquire)) {

        // chunk->offset is the byte offset *within the mapped buffer* where
        // the current frame lives. PipeWire pools reuse one mapped region
        // across multiple buffer slots, so every frame after the first sits
        // at a different offset. Reading `data + 0` returns stale (often
        // zero-initialised) memory from a slot the compositor isn't writing
        // to — which produces a fully-black video feed.
        uint32_t offset = buf->datas[0].chunk->offset;
        auto* data = static_cast<uint8_t*>(buf->datas[0].data) + offset;
        uint32_t stride = buf->datas[0].chunk->stride;
        uint32_t size = buf->datas[0].chunk->size;

        if (stride > 0 && size > 0 && st->width > 0 && st->height > 0) {
            auto now = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch())
                    .count());

            if (st->needsRgbSwap) {
                uint32_t frameBytes = stride * st->height;
                if (st->convertBuf.size() < frameBytes)
                    st->convertBuf.resize(frameBytes);
                memcpy(st->convertBuf.data(), data, frameBytes);
                for (uint32_t i = 0; i < frameBytes; i += 4)
                    std::swap(st->convertBuf[i], st->convertBuf[i + 2]);
                st->callback(st->convertBuf.data(), st->width, st->height, stride, now);
            } else {
                st->callback(data, st->width, st->height, stride, now);
            }
        }
    }

    pw_stream_queue_buffer(st->stream, b);
}

static const struct pw_stream_events kStreamEvents = {
    .version = PW_VERSION_STREAM_EVENTS,
    .state_changed = pwStateChanged,
    .param_changed = pwParamChanged,
    .process = pwProcess,
};

// -----------------------------------------------------------------------
// PipewireCapture public API
// -----------------------------------------------------------------------

PipewireCapture::PipewireCapture() = default;
PipewireCapture::~PipewireCapture() { Shutdown(); }

bool PipewireCapture::Initialize() {
    if (running_) return true;

    int fd = -1;
    uint32_t nodeId = 0;

    if (!portalNegotiate(fd, nodeId)) {
        std::cerr << "[PwCapture] Portal failed — falling back to X11/XShm" << std::endl;
        return InitializeX11();
    }

    pwFd_ = fd;
    nodeId_ = nodeId;

    // --- Set up PipeWire ---
    pw_init(nullptr, nullptr);

    loop_ = pw_thread_loop_new("peariscope-capture", nullptr);
    if (!loop_) {
        std::cerr << "[PwCapture] pw_thread_loop_new failed" << std::endl;
        close(fd);
        return false;
    }

    context_ = pw_context_new(pw_thread_loop_get_loop(loop_), nullptr, 0);
    if (!context_) {
        std::cerr << "[PwCapture] pw_context_new failed" << std::endl;
        pw_thread_loop_destroy(loop_); loop_ = nullptr;
        close(fd);
        return false;
    }

    if (pw_thread_loop_start(loop_) < 0) {
        std::cerr << "[PwCapture] pw_thread_loop_start failed" << std::endl;
        pw_context_destroy(context_); context_ = nullptr;
        pw_thread_loop_destroy(loop_); loop_ = nullptr;
        close(fd);
        return false;
    }

    pw_thread_loop_lock(loop_);

    core_ = pw_context_connect_fd(context_, fd, nullptr, 0);
    if (!core_) {
        std::cerr << "[PwCapture] pw_context_connect_fd failed" << std::endl;
        pw_thread_loop_unlock(loop_);
        pw_thread_loop_stop(loop_);
        pw_context_destroy(context_); context_ = nullptr;
        pw_thread_loop_destroy(loop_); loop_ = nullptr;
        return false;
    }

    auto* st = new PwStreamState();
    st->callback = frameCallback_;
    st->running = &running_;
    pwStreamState_ = st;

    auto* props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Video",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Screen",
        nullptr);

    stream_ = pw_stream_new(core_, "peariscope-screen", props);
    if (!stream_) {
        std::cerr << "[PwCapture] pw_stream_new failed" << std::endl;
        pw_thread_loop_unlock(loop_);
        pw_thread_loop_stop(loop_);
        pw_core_disconnect(core_); core_ = nullptr;
        pw_context_destroy(context_); context_ = nullptr;
        pw_thread_loop_destroy(loop_); loop_ = nullptr;
        delete st; pwStreamState_ = nullptr;
        return false;
    }
    st->stream = stream_;

    pw_stream_add_listener(stream_, &st->streamListener, &kStreamEvents, st);

    struct spa_rectangle defSize = SPA_RECTANGLE(1920, 1080);
    struct spa_rectangle minSize = SPA_RECTANGLE(1, 1);
    struct spa_rectangle maxSize = SPA_RECTANGLE(8192, 8192);
    struct spa_fraction defRate = SPA_FRACTION(30, 1);
    struct spa_fraction minRate = SPA_FRACTION(0, 1);
    struct spa_fraction maxRate = SPA_FRACTION(120, 1);

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));

    const struct ::spa_pod* params[1];
    params[0] = static_cast<const struct ::spa_pod*>(
        spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
            SPA_FORMAT_mediaType,      SPA_POD_Id(SPA_MEDIA_TYPE_video),
            SPA_FORMAT_mediaSubtype,   SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
            SPA_FORMAT_VIDEO_format,   SPA_POD_CHOICE_ENUM_Id(4,
                SPA_VIDEO_FORMAT_BGRx,
                SPA_VIDEO_FORMAT_BGRA,
                SPA_VIDEO_FORMAT_RGBx,
                SPA_VIDEO_FORMAT_RGBA),
            SPA_FORMAT_VIDEO_size,     SPA_POD_CHOICE_RANGE_Rectangle(
                &defSize, &minSize, &maxSize),
            SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(
                &defRate, &minRate, &maxRate)));

    int ret = pw_stream_connect(stream_,
        PW_DIRECTION_INPUT, nodeId,
        static_cast<enum pw_stream_flags>(
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS),
        params, 1);

    pw_thread_loop_unlock(loop_);

    if (ret < 0) {
        std::cerr << "[PwCapture] pw_stream_connect: " << spa_strerror(ret) << std::endl;
        Shutdown();
        return false;
    }

    running_ = true;

    for (int i = 0; i < 50 && st->width == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

    if (st->width == 0 || st->height == 0) {
        std::cerr << "[PwCapture] Timed out waiting for stream format" << std::endl;
        Shutdown();
        return false;
    }

    width_ = st->width;
    height_ = st->height;

    std::cerr << "[PwCapture] Capture active: " << width_ << "x" << height_ << std::endl;
    return true;
}

bool PipewireCapture::InitializeX11() {
    auto* xshm = new XShmCapture();
    if (!xshm->Init()) {
        delete xshm;
        return false;
    }

    width_ = static_cast<uint32_t>(xshm->screenWidth);
    height_ = static_cast<uint32_t>(xshm->screenHeight);
    running_ = true;

    captureThread_ = std::thread([this, xshm]() {
        constexpr auto kInterval = std::chrono::milliseconds(33);
        while (running_) {
            auto t0 = std::chrono::steady_clock::now();
            if (xshm->Grab() && frameCallback_) {
                auto now = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count();
                frameCallback_(
                    reinterpret_cast<const uint8_t*>(xshm->image->data),
                    static_cast<uint32_t>(xshm->image->width),
                    static_cast<uint32_t>(xshm->image->height),
                    static_cast<uint32_t>(xshm->image->bytes_per_line),
                    static_cast<uint64_t>(now));
            }
            auto elapsed = std::chrono::steady_clock::now() - t0;
            if (elapsed < kInterval)
                std::this_thread::sleep_for(kInterval - elapsed);
        }
        xshm->Destroy();
        delete xshm;
    });

    return true;
}

void PipewireCapture::Shutdown() {
    running_ = false;

    if (loop_) {
        pw_thread_loop_stop(loop_);
        if (stream_) { pw_stream_destroy(stream_); stream_ = nullptr; }
        if (core_) { pw_core_disconnect(core_); core_ = nullptr; }
        if (context_) { pw_context_destroy(context_); context_ = nullptr; }
        pw_thread_loop_destroy(loop_); loop_ = nullptr;

        if (auto* st = static_cast<PwStreamState*>(pwStreamState_)) {
            delete st;
            pwStreamState_ = nullptr;
        }
        pw_deinit();
    }

    if (captureThread_.joinable())
        captureThread_.join();
}

std::vector<NativeDisplayInfo> PipewireCapture::EnumerateDisplays() {
    std::vector<NativeDisplayInfo> displays;
    Display* dpy = XOpenDisplay(nullptr);
    if (!dpy) return displays;

    int count = ScreenCount(dpy);
    for (int i = 0; i < count; ++i) {
        NativeDisplayInfo info;
        info.name = std::string(":") + std::to_string(i);
        info.width = static_cast<uint32_t>(DisplayWidth(dpy, i));
        info.height = static_cast<uint32_t>(DisplayHeight(dpy, i));
        info.nodeId = static_cast<uint32_t>(i);
        displays.push_back(std::move(info));
    }
    XCloseDisplay(dpy);
    return displays;
}

// Stubs — callbacks are now file-scope free functions
void PipewireCapture::onStreamProcess(void*) {}
void PipewireCapture::onStreamParamChanged(void*, uint32_t, const struct spa_pod*) {}

} // namespace peariscope
