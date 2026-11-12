#define UNICODE
#define _UNICODE
#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <filesystem>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <sstream>
#include <iomanip>
#include <stdexcept>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "shell32.lib")

namespace fs = std::filesystem;

static HWND gTargetEdit{};
static HWND gStatus{};
static HWND gUpdateButton{};
static HINSTANCE gInstance{};
static std::wstring gBaseDir;
static std::wstring gPayloadDir;

static std::wstring ExeDirectory()
{
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    return fs::path(path).parent_path().wstring();
}

static void SetStatus(const std::wstring& text)
{
    SetWindowTextW(gStatus, text.c_str());
    UpdateWindow(gStatus);
}

static bool ExistsFile(const fs::path& p)
{
    std::error_code ec;
    return fs::is_regular_file(p, ec);
}

static std::wstring DetectTarget()
{
    std::vector<fs::path> dirs;
    fs::path base(gBaseDir);
    dirs.push_back(base);
    if (base.has_parent_path()) {
        dirs.push_back(base.parent_path());
        if (base.parent_path().has_parent_path())
            dirs.push_back(base.parent_path().parent_path());
    }

    wchar_t desktop[MAX_PATH]{};
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, SHGFP_TYPE_CURRENT, desktop)))
        dirs.emplace_back(desktop);

    wchar_t docs[MAX_PATH]{};
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_PERSONAL, nullptr, SHGFP_TYPE_CURRENT, docs)))
        dirs.emplace_back(docs);

    wchar_t profile[MAX_PATH]{};
    if (GetEnvironmentVariableW(L"USERPROFILE", profile, MAX_PATH) > 0)
        dirs.emplace_back(fs::path(profile) / L"Downloads");

    for (const auto& dir : dirs) {
        auto candidate = dir / L"タスク_予定表.exe";
        if (ExistsFile(candidate))
            return candidate.wstring();
    }

    return L"";
}

static std::wstring GetTargetText()
{
    int len = GetWindowTextLengthW(gTargetEdit);
    std::wstring text(static_cast<size_t>(len), L'\0');
    GetWindowTextW(gTargetEdit, text.data(), len + 1);
    return text;
}

static void BrowseTarget(HWND owner)
{
    wchar_t file[MAX_PATH]{};
    auto current = GetTargetText();
    if (!current.empty())
        wcsncpy_s(file, current.c_str(), _TRUNCATE);

    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.hInstance = gInstance;
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrFilter = L"タスク_予定表.exe\0タスク_予定表.exe\0EXE (*.exe)\0*.exe\0\0";
    ofn.nFilterIndex = 1;
    ofn.lpstrTitle = L"現在使用中の タスク_予定表.exe を選択";
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;

    if (GetOpenFileNameW(&ofn))
        SetWindowTextW(gTargetEdit, file);
}

static void StopOldApp()
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;

    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);

    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, L"タスク_予定表.exe") == 0) {
                HANDLE proc = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pe.th32ProcessID);
                if (proc) {
                    TerminateProcess(proc, 0);
                    WaitForSingleObject(proc, 1500);
                    CloseHandle(proc);
                }
            }
        } while (Process32NextW(snap, &pe));
    }

    CloseHandle(snap);
}

static std::wstring Timestamp()
{
    SYSTEMTIME st{};
    GetLocalTime(&st);
    std::wstringstream ss;
    ss << std::setfill(L'0')
       << std::setw(4) << st.wYear
       << std::setw(2) << st.wMonth
       << std::setw(2) << st.wDay
       << L"_"
       << std::setw(2) << st.wHour
       << std::setw(2) << st.wMinute
       << std::setw(2) << st.wSecond;
    return ss.str();
}

static void CopyTree(const fs::path& source, const fs::path& dest)
{
    std::error_code ec;
    if (!fs::exists(source, ec)) return;

    fs::create_directories(dest);

    for (const auto& entry : fs::recursive_directory_iterator(source)) {
        auto rel = fs::relative(entry.path(), source, ec);
        if (ec) continue;
        auto out = dest / rel;

        if (entry.is_directory()) {
            fs::create_directories(out);
        } else if (entry.is_regular_file()) {
            fs::create_directories(out.parent_path());
            fs::copy_file(entry.path(), out, fs::copy_options::overwrite_existing);
        }
    }
}

static bool CopyWithRetry(const fs::path& source, const fs::path& dest, std::wstring& error)
{
    for (int i = 0; i < 12; ++i) {
        try {
            fs::copy_file(source, dest, fs::copy_options::overwrite_existing);
            return true;
        } catch (const std::exception&) {
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
        }
    }

    error = L"本体EXEを置き換えられませんでした。";
    return false;
}

static void RunUpdate(HWND owner)
{
    EnableWindow(gUpdateButton, FALSE);

    try {
        fs::path target(GetTargetText());
        if (!ExistsFile(target))
            throw std::runtime_error("target not found");

        if (_wcsicmp(target.filename().c_str(), L"タスク_予定表.exe") != 0)
            throw std::runtime_error("wrong target");

        fs::path payloadRoot(gPayloadDir);
        fs::path payloadExe = payloadRoot / L"タスク_予定表.exe";
        if (!ExistsFile(payloadExe))
            throw std::runtime_error("payload missing");

        fs::path targetDir = target.parent_path();

        SetStatus(L"旧バージョンを終了しています...");
        StopOldApp();
        std::this_thread::sleep_for(std::chrono::milliseconds(500));

        fs::path backupDir = targetDir / L"Backup_PreUpdate" / Timestamp();
        fs::create_directories(backupDir);
        fs::copy_file(target, backupDir / L"タスク_予定表.exe", fs::copy_options::overwrite_existing);

        SetStatus(L"v1.1本体を更新しています...");

        std::wstring copyError;
        if (!CopyWithRetry(payloadExe, target, copyError))
            throw std::runtime_error("copy failed");

        CopyTree(payloadRoot / L"Voice", targetDir / L"Voice");

        fs::path icon = payloadRoot / L"TaskScheduleTable.ico";
        if (ExistsFile(icon))
            fs::copy_file(icon, targetDir / L"TaskScheduleTable.ico", fs::copy_options::overwrite_existing);

        std::wstring done =
            L"アップデート完了。\r\n\r\n"
            L"旧EXEのバックアップ:\r\n" + backupDir.wstring() +
            L"\r\n\r\nタスク・背景・色・VOICE音量などの設定は保持されています。\r\n"
            L"v1.1を起動します。";

        SetStatus(done);

        ShellExecuteW(owner, L"open", target.c_str(), nullptr, targetDir.c_str(), SW_SHOWNORMAL);
        EnableWindow(gUpdateButton, TRUE);
    }
    catch (...) {
        SetStatus(
            L"アップデートに失敗しました。\r\n\r\n"
            L"「参照...」から現在使用中の タスク_予定表.exe を選択して、もう一度実行してください。");
        MessageBoxW(owner,
            L"アップデートできませんでした。\n更新対象のEXEを選び直してください。",
            L"タスク・予定表 Updater", MB_OK | MB_ICONERROR);
        EnableWindow(gUpdateButton, TRUE);
    }
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg) {
    case WM_CREATE:
    {
        HFONT font = CreateFontW(
            18, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Yu Gothic UI");

        CreateWindowW(L"STATIC", L"タスク・予定表 アップデーター",
            WS_CHILD | WS_VISIBLE,
            18, 16, 500, 32, hwnd, nullptr, gInstance, nullptr);

        CreateWindowW(L"STATIC",
            L"旧バージョンの「タスク_予定表.exe」を選択してください。設定データは削除しません。",
            WS_CHILD | WS_VISIBLE,
            18, 58, 590, 28, hwnd, nullptr, gInstance, nullptr);

        gTargetEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
            18, 92, 485, 32, hwnd, reinterpret_cast<HMENU>(101), gInstance, nullptr);

        HWND browse = CreateWindowW(L"BUTTON", L"参照...",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            512, 92, 92, 32, hwnd, reinterpret_cast<HMENU>(102), gInstance, nullptr);

        gStatus = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_READONLY | WS_VSCROLL,
            18, 140, 586, 120, hwnd, reinterpret_cast<HMENU>(103), gInstance, nullptr);

        CreateWindowW(L"STATIC", L"更新先: v1.1",
            WS_CHILD | WS_VISIBLE,
            18, 282, 220, 28, hwnd, nullptr, gInstance, nullptr);

        gUpdateButton = CreateWindowW(L"BUTTON", L"アップデート",
            WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
            452, 276, 152, 42, hwnd, reinterpret_cast<HMENU>(104), gInstance, nullptr);

        for (HWND child : { gTargetEdit, browse, gStatus, gUpdateButton })
            SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);

        auto target = DetectTarget();
        if (!target.empty()) {
            SetWindowTextW(gTargetEdit, target.c_str());
            SetStatus(L"旧バージョンを検出しました。\r\n「アップデート」を押してください。");
        } else {
            SetStatus(L"旧バージョンを自動検出できませんでした。\r\n「参照...」から現在使用中の タスク_予定表.exe を選択してください。");
        }

        fs::path payload = fs::path(gPayloadDir) / L"タスク_予定表.exe";
        if (!ExistsFile(payload)) {
            SetStatus(L"更新データが見つかりません。ZIPを完全に展開してから起動してください。");
            EnableWindow(gUpdateButton, FALSE);
        }
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case 102: BrowseTarget(hwnd); return 0;
        case 104: RunUpdate(hwnd); return 0;
        }
        break;
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLOREDIT:
    {
        HDC dc = reinterpret_cast<HDC>(wParam);
        SetTextColor(dc, RGB(0, 255, 102));
        SetBkColor(dc, RGB(0, 0, 0));
        static HBRUSH brush = CreateSolidBrush(RGB(0, 0, 0));
        return reinterpret_cast<LRESULT>(brush);
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, PWSTR, int nCmdShow)
{
    gInstance = hInstance;
    gBaseDir = ExeDirectory();
    gPayloadDir = (fs::path(gBaseDir) / L"UpdateFiles").wstring();

    const wchar_t* className = L"TaskScheduleTableUpdaterWindow";

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(RGB(0, 0, 0));
    wc.lpszClassName = className;
    wc.hIcon = LoadIconW(hInstance, MAKEINTRESOURCEW(1));
    wc.hIconSm = LoadIconW(hInstance, MAKEINTRESOURCEW(1));
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(
        0, className, L"タスク・予定表 Updater",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 640, 370,
        nullptr, nullptr, hInstance, nullptr);

    if (!hwnd) return 1;

    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    return static_cast<int>(msg.wParam);
}
