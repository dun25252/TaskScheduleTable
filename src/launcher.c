typedef unsigned long DWORD;
typedef int BOOL;
typedef unsigned short WORD;
typedef unsigned char BYTE;
typedef void* HANDLE;
typedef void* HWND;
typedef void* LPVOID;
typedef unsigned short WCHAR;
typedef const WCHAR* LPCWSTR;
typedef WCHAR* LPWSTR;

typedef struct _STARTUPINFOW {
    DWORD cb; LPWSTR lpReserved; LPWSTR lpDesktop; LPWSTR lpTitle;
    DWORD dwX; DWORD dwY; DWORD dwXSize; DWORD dwYSize;
    DWORD dwXCountChars; DWORD dwYCountChars; DWORD dwFillAttribute;
    DWORD dwFlags; WORD wShowWindow; WORD cbReserved2; BYTE* lpReserved2;
    HANDLE hStdInput; HANDLE hStdOutput; HANDLE hStdError;
} STARTUPINFOW;
typedef struct _PROCESS_INFORMATION { HANDLE hProcess; HANDLE hThread; DWORD dwProcessId; DWORD dwThreadId; } PROCESS_INFORMATION;

__declspec(dllimport) DWORD __stdcall GetModuleFileNameW(HANDLE, LPWSTR, DWORD);
__declspec(dllimport) DWORD __stdcall GetEnvironmentVariableW(LPCWSTR, LPWSTR, DWORD);
__declspec(dllimport) DWORD __stdcall GetFileAttributesW(LPCWSTR);
__declspec(dllimport) BOOL __stdcall CreateProcessW(LPCWSTR, LPWSTR, LPVOID, LPVOID, BOOL, DWORD, LPVOID, LPCWSTR, STARTUPINFOW*, PROCESS_INFORMATION*);
__declspec(dllimport) BOOL __stdcall CloseHandle(HANDLE);
__declspec(dllimport) void __stdcall ExitProcess(DWORD);
__declspec(dllimport) DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
__declspec(dllimport) BOOL __stdcall GetExitCodeProcess(HANDLE, DWORD*);
__declspec(dllimport) int __stdcall MessageBoxW(HWND, LPCWSTR, LPCWSTR, unsigned int);

#define CAP 32768
#define INVALID_FILE_ATTRIBUTES 0xFFFFFFFFUL
#define CREATE_NO_WINDOW 0x08000000UL
#define CREATE_UNICODE_ENVIRONMENT 0x00000400UL
#define STARTF_USESHOWWINDOW 0x00000001UL
#define SW_HIDE 0
#define WAIT_OBJECT_0 0x00000000UL
#define MB_OK 0x00000000UL
#define MB_ICONERROR 0x00000010UL

static WCHAR g_module[CAP], g_script[CAP], g_dir[CAP], g_root[CAP], g_ps[CAP], g_cmd[CAP];
static STARTUPINFOW g_si; static PROCESS_INFORMATION g_pi;
static unsigned int wlen(const WCHAR* s){unsigned int n=0;if(!s)return 0;while(s[n])n++;return n;}
static int wcopy(WCHAR* d,unsigned int c,const WCHAR* s){unsigned int i=0;if(!d||!c)return 0;while(s&&s[i]){if(i+1>=c){d[0]=0;return 0;}d[i]=s[i];i++;}d[i]=0;return 1;}
static int wappend(WCHAR* d,unsigned int c,const WCHAR* s){unsigned int n=wlen(d),i=0;while(s&&s[i]){if(n+i+1>=c)return 0;d[n+i]=s[i];i++;}d[n+i]=0;return 1;}
static void fail(const WCHAR* m,DWORD c){MessageBoxW((HWND)0,m,L"タスク・予定表",MB_OK|MB_ICONERROR);ExitProcess(c);}

void wWinMainCRTStartup(void){
    DWORD n=GetModuleFileNameW((HANDLE)0,g_module,CAP);
    if(n==0||n>=CAP-1) fail(L"実行ファイルの場所を取得できませんでした。",10);
    if(!wcopy(g_dir,CAP,g_module)) fail(L"パスが長すぎます。",11);
    {int i=(int)wlen(g_dir)-1;while(i>=0&&g_dir[i]!=L'\\'&&g_dir[i]!=L'/')i--;if(i<0)fail(L"実行フォルダーを取得できませんでした。",12);g_dir[i]=0;}
    if(!wcopy(g_script,CAP,g_dir)||!wappend(g_script,CAP,L"\\TaskScheduleTableBootstrap.ps1")) fail(L"起動スクリプトのパスが長すぎます。",13);
    if(GetFileAttributesW(g_script)==INVALID_FILE_ATTRIBUTES) fail(L"TaskScheduleTableBootstrap.ps1 が見つかりません。ZIPを展開したフォルダー構成のまま使用してください。",14);
    n=GetEnvironmentVariableW(L"SystemRoot",g_root,CAP);if(n==0||n>=CAP-1)fail(L"Windowsフォルダーを取得できませんでした。",15);
    if(!wcopy(g_ps,CAP,g_root)||!wappend(g_ps,CAP,L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")) fail(L"PowerShellパスが長すぎます。",16);
    if(GetFileAttributesW(g_ps)==INVALID_FILE_ATTRIBUTES) fail(L"Windows PowerShell 5.1 が見つかりません。",17);
    g_cmd[0]=0;
    if(!wappend(g_cmd,CAP,L"\"")||!wappend(g_cmd,CAP,g_ps)||!wappend(g_cmd,CAP,L"\" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"")||!wappend(g_cmd,CAP,g_script)||!wappend(g_cmd,CAP,L"\"")) fail(L"起動コマンドが長すぎます。",18);
    g_si.cb=(DWORD)sizeof(g_si);g_si.dwFlags=STARTF_USESHOWWINDOW;g_si.wShowWindow=SW_HIDE;
    if(!CreateProcessW(g_ps,g_cmd,(LPVOID)0,(LPVOID)0,0,CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT,(LPVOID)0,g_dir,&g_si,&g_pi)) fail(L"タスク・予定表を起動できませんでした。",19);
    {DWORD wr=WaitForSingleObject(g_pi.hProcess,1800);if(wr==WAIT_OBJECT_0){DWORD ec=0;if(GetExitCodeProcess(g_pi.hProcess,&ec)&&ec!=0){CloseHandle(g_pi.hThread);CloseHandle(g_pi.hProcess);if(ec==71)ExitProcess(ec);fail(L"タスク・予定表の初期化に失敗しました。Log\\Error を確認してください。",20);}}}
    CloseHandle(g_pi.hThread);CloseHandle(g_pi.hProcess);ExitProcess(0);
}
