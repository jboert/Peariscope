#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QIcon>
#include <QDebug>
#include <QPalette>
#include <QScreen>
#include <QQuickWindow>
#include <csignal>
#include <signal.h>
#include <unistd.h>

#include "app/AppController.h"

static peariscope::AppController* s_controller = nullptr;
volatile pid_t g_workletPid = -1;
static volatile pid_t& s_workletPid = g_workletPid;

static void crashSignalHandler(int sig) {
    // Async-signal-safe: just kill the worklet process group directly.
    // Calling delete/destructors from a signal handler is unsafe (can deadlock).
    pid_t pid = s_workletPid;
    if (pid > 0) {
        kill(-pid, SIGKILL);  // negative = kill process group
    }
    // Re-raise with default handler to get proper exit code/core dump
    signal(sig, SIG_DFL);
    raise(sig);
}

static peariscope::AppController* controllerSingletonProvider(QQmlEngine*, QJSEngine*) {
    return s_controller;
}

int main(int argc, char* argv[]) {
    // Ignore SIGPIPE — writing to a broken pipe (dead worklet) must not kill the app
    signal(SIGPIPE, SIG_IGN);

    // Kill worklet subprocess on crash/termination signals to prevent orphans
    signal(SIGABRT, crashSignalHandler);
    signal(SIGSEGV, crashSignalHandler);
    signal(SIGBUS, crashSignalHandler);
    signal(SIGTERM, crashSignalHandler);
    signal(SIGINT, crashSignalHandler);
    signal(SIGHUP, crashSignalHandler);

    // Force X11/XWayland so we can position the window (Wayland blocks setX/setY)
    qputenv("QT_QPA_PLATFORM", "xcb");

    QApplication app(argc, argv);
    app.setApplicationName("Peariscope");
    app.setOrganizationName("Peariscope");
    app.setQuitOnLastWindowClosed(false);
    QQuickStyle::setStyle("Basic");

    // Force dark palette — the QML UI is designed for dark backgrounds
    QPalette dark;
    dark.setColor(QPalette::Window, QColor(0x1e, 0x1e, 0x1e));
    dark.setColor(QPalette::WindowText, Qt::white);
    dark.setColor(QPalette::Base, QColor(0x2a, 0x2a, 0x2a));
    dark.setColor(QPalette::AlternateBase, QColor(0x1e, 0x1e, 0x1e));
    dark.setColor(QPalette::Text, Qt::white);
    dark.setColor(QPalette::Button, QColor(0x2a, 0x2a, 0x2a));
    dark.setColor(QPalette::ButtonText, Qt::white);
    dark.setColor(QPalette::Highlight, QColor(0x9B, 0xE2, 0x38));
    dark.setColor(QPalette::HighlightedText, Qt::black);
    app.setPalette(dark);

    s_controller = new peariscope::AppController();
    qmlRegisterSingletonType<peariscope::AppController>(
        "Peariscope", 1, 0, "AppController", controllerSingletonProvider);
    qmlRegisterType<peariscope::RecentConnectionsModel>(
        "Peariscope", 1, 0, "RecentConnectionsModel");

    if (!s_controller->initialize()) {
        qCritical() << "AppController::initialize() failed";
    }
    s_workletPid = s_controller->workletPid();

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
        &app, []() { qCritical() << "QML object creation failed!"; },
        Qt::QueuedConnection);
    // Qt 6.4 uses QUrl loading; loadFromModule is 6.5+
    engine.load(QUrl(QStringLiteral("qrc:/Peariscope/src/qml/Main.qml")));

    if (engine.rootObjects().isEmpty()) {
        qCritical() << "No QML root objects";
        return -1;
    }

    // Position window in top-right corner
    auto* win = qobject_cast<QQuickWindow*>(engine.rootObjects().first());
    if (win) {
        QScreen* screen = app.primaryScreen();
        if (screen) {
            QRect geo = screen->availableGeometry();
            win->setX(geo.right() - win->width() - 12);
            win->setY(geo.top() + 36);
        }
    }

    return app.exec();
}
