//! `nsec-keygen` — offline Nostr private-key generator with a small GUI.
//!
//! - Windows GUI (Win32): a name field + "Generate & save" button; writes
//!   `<name>.key.txt` next to the exe containing nsec/hex/npub.
//! - `--self-test`: headless smoke run for CI — generates a key, verifies the
//!   nsec round-trip, prints the derived npub, exits 0/1.

use nsec_keygen::{generate, parse_nsec, write_backup};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--self-test") {
        std::process::exit(self_test());
    }
    #[cfg(windows)]
    {
        gui::run();
        return;
    }
    #[cfg(not(windows))]
    {
        // Non-Windows builds (CI smoke) just run the self-test.
        std::process::exit(self_test());
    }
}

fn self_test() -> i32 {
    let key = generate();
    eprintln!("generated nsec: {}", key.nsec);
    eprintln!("npub: {}", key.npub);
    match parse_nsec(&key.nsec) {
        Ok(back) if back == key => {
            let dir = std::env::temp_dir().join("nsec-keygen-selftest");
            std::fs::create_dir_all(&dir).unwrap();
            match write_backup(&dir, "selftest", &key) {
                Ok(path) => {
                    eprintln!("backup written: {}", path.display());
                    eprintln!("SELF-TEST OK");
                    0
                }
                Err(e) => {
                    eprintln!("SELF-TEST FAIL (write): {e}");
                    1
                }
            }
        }
        _ => {
            eprintln!("SELF-TEST FAIL (round-trip mismatch)");
            1
        }
    }
}

#[cfg(windows)]
mod gui {
    use nsec_keygen::{generate, write_backup};
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::path::PathBuf;
    use windows_sys::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
    use windows_sys::Win32::Graphics::Gdi::{CreateFontW, DEFAULT_CHARSET, FW_NORMAL, OUT_DEFAULT_PRECIS};
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::Controls::EM_SETLIMITTEXT;
    use windows_sys::Win32::UI::Shell::SHGetFolderPathW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, GetDlgItem, GetMessageW,
        GetWindowTextLengthW, GetWindowTextW, MessageBoxW, PostQuitMessage, RegisterClassW,
        SendMessageW, ShowWindow, TranslateMessage, CW_USEDEFAULT, MB_OK, MSG, WM_COMMAND,
        WM_DESTROY, WM_SETFONT, WM_SETTEXT, WNDCLASSW,
    };

    const ID_EDIT: i32 = 101;
    const ID_BTN: i32 = 102;
    const ID_STATUS: i32 = 103;

    const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
    const WS_CHILD_VISIBLE: u32 = 0x50000000;
    const WS_EX_CLIENTEDGE: u32 = 0x00000200;
    const BS_PUSHBUTTON: u32 = 0x00000000;
    const SW_SHOW: i32 = 1;

    fn wide(s: &str) -> Vec<u16> {
        OsStr::new(s).encode_wide().chain(Some(0)).collect()
    }

    unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        match msg {
            WM_DESTROY => {
                PostQuitMessage(0);
                0
            }
            WM_COMMAND => {
                let id = (wparam & 0xFFFF) as i32;
                if id == ID_BTN {
                    handle_generate(hwnd);
                }
                0
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    unsafe fn handle_generate(hwnd: HWND) {
        let edit = GetDlgItem(hwnd, ID_EDIT);
        let len = GetWindowTextLengthW(edit) as usize;
        let mut buf = vec![0u16; len + 1];
        GetWindowTextW(edit, buf.as_mut_ptr(), buf.len() as i32);
        let name = String::from_utf16_lossy(&buf[..len]);
        let status = GetDlgItem(hwnd, ID_STATUS);
        if name.trim().is_empty() {
            SendMessageW(status, WM_SETTEXT, 0, wide("이름을 입력하세요.").as_ptr() as LPARAM);
            return;
        }
        let key = generate();
        // Default dir: exe's own directory (so the .key.txt lands next to the tool).
        let mut dir: PathBuf = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from("."));
        if write_backup(&dir, &name, &key).is_err() {
            let mut docs = [0u16; 260];
            // CSIDL_PERSONAL = 5 (Documents)
            if SHGetFolderPathW(std::ptr::null_mut(), 5, std::ptr::null_mut(), 0, docs.as_mut_ptr()) == 0 {
                dir = PathBuf::from(String::from_utf16_lossy(&docs));
            }
        }
        match write_backup(&dir, &name, &key) {
            Ok(path) => {
                let msg = format!(
                    "생성 완료!\n\n파일: {}\n\nnpub: {}\n\nnsec는 파일 안에 있습니다. Buzz 앱의 \"Use an existing key\"에 붙여넣으세요.",
                    path.display(),
                    key.npub
                );
                SendMessageW(
                    status,
                    WM_SETTEXT,
                    0,
                    wide(&format!("저장됨: {}", path.display())).as_ptr() as LPARAM,
                );
                MessageBoxW(hwnd, wide(&msg).as_ptr(), wide("nsec-keygen").as_ptr(), MB_OK);
            }
            Err(e) => {
                let msg = format!("저장 실패: {e}");
                MessageBoxW(hwnd, wide(&msg).as_ptr(), wide("오류").as_ptr(), MB_OK);
            }
        }
    }

    pub fn run() {
        unsafe {
            let hinstance: HINSTANCE = GetModuleHandleW(std::ptr::null());
            let class_name = wide("NsecKeygenWnd");
            let wc = WNDCLASSW {
                style: 0,
                lpfnWndProc: Some(wnd_proc),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: hinstance,
                hIcon: std::ptr::null_mut(),
                hCursor: std::ptr::null_mut(),
                hbrBackground: std::ptr::null_mut(),
                lpszMenuName: std::ptr::null(),
                lpszClassName: class_name.as_ptr(),
            };
            RegisterClassW(&wc);

            let title = wide("nsec-keygen — 오프라인 Nostr 키 생성");
            let hwnd = CreateWindowExW(
                0,
                class_name.as_ptr(),
                title.as_ptr(),
                WS_OVERLAPPEDWINDOW,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                520,
                240,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                hinstance,
                std::ptr::null(),
            );
            if hwnd.is_null() {
                return;
            }

            let font = CreateFontW(
                -14, 0, 0, 0, FW_NORMAL as i32, 0, 0, 0, DEFAULT_CHARSET as u32,
                OUT_DEFAULT_PRECIS as u32, 0, 0, 0, wide("Segoe UI").as_ptr(),
            );

            let label = CreateWindowExW(
                0, wide("STATIC").as_ptr(), wide("이름 (파일명으로 사용):").as_ptr(),
                WS_CHILD_VISIBLE, 20, 18, 460, 22, hwnd, std::ptr::null_mut(), hinstance, std::ptr::null(),
            );
            let edit = CreateWindowExW(
                WS_EX_CLIENTEDGE,
                wide("EDIT").as_ptr(), wide("").as_ptr(),
                WS_CHILD_VISIBLE | 0x00000080, // WS_BORDER
                20, 44, 460, 26, hwnd, ID_EDIT as isize as *mut _, hinstance, std::ptr::null(),
            );
            SendMessageW(edit, EM_SETLIMITTEXT, 64, 0);
            let btn = CreateWindowExW(
                0, wide("BUTTON").as_ptr(), wide("키 생성 & 파일 저장").as_ptr(),
                WS_CHILD_VISIBLE | BS_PUSHBUTTON, 20, 82, 200, 30, hwnd, ID_BTN as isize as *mut _, hinstance, std::ptr::null(),
            );
            let status = CreateWindowExW(
                0, wide("STATIC").as_ptr(), wide("").as_ptr(),
                WS_CHILD_VISIBLE, 20, 124, 460, 70, hwnd, ID_STATUS as isize as *mut _, hinstance, std::ptr::null(),
            );
            for c in [label, edit, btn, status] {
                if !font.is_null() {
                    SendMessageW(c, WM_SETFONT, font as WPARAM, 1);
                }
            }

            ShowWindow(hwnd, SW_SHOW);
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
}
