#include "app/App.h"
#include <Windows.h>

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int nCmdShow) {
    peariscope::App app(hInstance);

    if (!app.Initialize(nCmdShow)) {
        return 1;
    }

    return app.Run();
}
