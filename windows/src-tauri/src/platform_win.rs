//! What Windows tells us: the app in front, idle time, real key/click/scroll activity, and the
//! site in a browser's front tab (read through UI Automation, like a screen reader would).

use crate::engine::Senses;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Once;

use windows::core::{w, Interface, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, BOOL, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::System::Threading::{
    GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationValuePattern, TreeScope_Descendants,
    UIA_ControlTypePropertyId, UIA_EditControlTypeId, UIA_ValuePatternId,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetLastInputInfo, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    LASTINPUTINFO, VIRTUAL_KEY, VK_CONTROL,
};
use windows::Win32::UI::Input::{GetRawInputData, RegisterRawInputDevices, HRAWINPUT, RAWINPUT, RAWINPUTDEVICE, RAWINPUTHEADER, RIDEV_INPUTSINK, RID_INPUT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, EnumChildWindows, GetForegroundWindow, GetMessageW,
    GetWindowThreadProcessId, RegisterClassW, TranslateMessage, MSG, WINDOW_EX_STYLE, WINDOW_STYLE, WM_INPUT, WNDCLASSW,
};

const BROWSERS: [&str; 7] = ["chrome.exe", "msedge.exe", "brave.exe", "firefox.exe", "opera.exe", "vivaldi.exe", "arc.exe"];

/// GetTickCount64 of the last key press, click or scroll, from raw input.
static LAST_HANDS: AtomicU64 = AtomicU64::new(0);
static START_INPUT: Once = Once::new();

pub struct Win {
    own_pid: u32,
    front_hwnd: HWND,
    front_path: String,
    uia: Option<IUIAutomation>,
    address_bars: HashMap<isize, IUIAutomationElement>,
    names: HashMap<String, String>,
}

unsafe impl Send for Win {}

impl Win {
    pub fn new() -> Win {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            START_INPUT.call_once(|| { std::thread::spawn(raw_input_thread); });
            LAST_HANDS.store(GetTickCount64(), Ordering::Relaxed);
            let uia: Option<IUIAutomation> = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok();
            Win { own_pid: GetCurrentProcessId(), front_hwnd: HWND::default(), front_path: String::new(), uia, address_bars: HashMap::new(), names: HashMap::new() }
        }
    }

    /// Closes the front tab: Ctrl+W, sent while the browser is in front.
    pub fn close_front_tab(&self) {
        fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
            INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT {
                wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, time: 0, dwExtraInfo: 0 } } }
        }
        let w = VIRTUAL_KEY(b'W' as u16);
        let inputs = [key(VK_CONTROL, false), key(w, false), key(w, true), key(VK_CONTROL, true)];
        unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32); }
    }

    fn process_path(pid: u32) -> Option<String> {
        unsafe {
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
            let _ = CloseHandle(h);
            r.ok()?;
            Some(String::from_utf16_lossy(&buf[..len as usize]))
        }
    }
}

fn exe_name(path: &str) -> String {
    path.rsplit(['\\', '/']).next().unwrap_or(path).to_lowercase()
}

/// Store apps (Calculator, Mail…) all run inside ApplicationFrameHost; find the real one.
unsafe extern "system" fn find_child_app(child: HWND, lp: LPARAM) -> BOOL {
    let state = &mut *(lp.0 as *mut (u32, u32));
    let mut pid = 0u32;
    GetWindowThreadProcessId(child, Some(&mut pid));
    if pid != 0 && pid != state.0 { state.1 = pid; return BOOL(0); }
    BOOL(1)
}

impl Senses for Win {
    fn front(&mut self) -> Option<String> {
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.0.is_null() { return None; }
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == 0 { return None; }
            if pid == self.own_pid { self.front_hwnd = hwnd; return Some("workclock.exe".into()); }
            let mut path = Self::process_path(pid)?;
            if exe_name(&path) == "applicationframehost.exe" {
                let mut state: (u32, u32) = (pid, 0);
                let _ = EnumChildWindows(hwnd, Some(find_child_app), LPARAM(&mut state as *mut _ as isize));
                if state.1 != 0 { if let Some(p) = Self::process_path(state.1) { path = p; } }
            }
            self.front_hwnd = hwnd;
            self.front_path = path.clone();
            Some(exe_name(&path))
        }
    }

    fn is_self(&self, app: &str) -> bool { app == "workclock.exe" }

    fn is_browser(&self, app: &str) -> bool { BROWSERS.contains(&app) }

    fn domain(&mut self) -> Option<String> {
        let uia = self.uia.as_ref()?;
        let hwnd = self.front_hwnd;
        let key = hwnd.0 as isize;
        unsafe {
            let bar = match self.address_bars.get(&key) {
                Some(b) => b.clone(),
                None => {
                    let root = uia.ElementFromHandle(hwnd).ok()?;
                    let cond = uia.CreatePropertyCondition(UIA_ControlTypePropertyId, &windows::core::VARIANT::from(UIA_EditControlTypeId.0)).ok()?;
                    let bar = root.FindFirst(TreeScope_Descendants, &cond).ok()?;
                    if self.address_bars.len() > 50 { self.address_bars.clear(); }
                    self.address_bars.insert(key, bar.clone());
                    bar
                }
            };
            let value = bar.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                .and_then(|p| p.CurrentValue());
            match value {
                Ok(v) => Some(host_of(&v.to_string())),
                Err(_) => { self.address_bars.remove(&key); None }
            }
        }
    }

    fn idle(&self) -> f64 {
        unsafe {
            let mut lii = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
            if !GetLastInputInfo(&mut lii).as_bool() { return 0.0; }
            // dwTime is the low 32 bits of the tick count.
            let now = GetTickCount64() as u32;
            now.wrapping_sub(lii.dwTime) as f64 / 1000.0
        }
    }

    fn hands_idle(&self) -> f64 {
        let now = unsafe { GetTickCount64() };
        now.saturating_sub(LAST_HANDS.load(Ordering::Relaxed)) as f64 / 1000.0
    }

    fn display_name(&mut self, app: &str) -> String {
        if let Some(n) = self.names.get(app) { return n.clone(); }
        let n = if exe_name(&self.front_path) == app { file_description(&self.front_path) } else { None }
            .unwrap_or_else(|| pretty_stem(app));
        self.names.insert(app.to_string(), n.clone());
        n
    }
}

/// "github.com/team" → "github.com"; search text, new tabs and browser pages → "".
pub fn host_of(text: &str) -> String {
    let t = text.trim();
    if t.is_empty() || t.contains(' ') { return String::new(); }
    let rest = match t.split_once("://") {
        Some((scheme, rest)) => { if scheme != "http" && scheme != "https" { return String::new(); } rest }
        None => t,
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit('@').next().unwrap_or(host).split(':').next().unwrap_or("").to_lowercase();
    if !host.contains('.') { return String::new(); }
    host.strip_prefix("www.").unwrap_or(&host).to_string()
}

fn pretty_stem(app: &str) -> String {
    let stem = app.trim_end_matches(".exe");
    let mut c = stem.chars();
    match c.next() { Some(f) => f.to_uppercase().collect::<String>() + c.as_str(), None => app.to_string() }
}

/// The app's own name from its version info ("Visual Studio Code").
fn file_description(path: &str) -> Option<String> {
    unsafe {
        let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
        let p = PCWSTR(wide.as_ptr());
        let size = GetFileVersionInfoSizeW(p, None);
        if size == 0 { return None; }
        let mut buf = vec![0u8; size as usize];
        GetFileVersionInfoW(p, 0, size, buf.as_mut_ptr() as _).ok()?;
        let mut ptr = std::ptr::null_mut();
        let mut len = 0u32;
        if !VerQueryValueW(buf.as_ptr() as _, w!("\\VarFileInfo\\Translation"), &mut ptr, &mut len).as_bool() || len < 4 { return None; }
        let lang = *(ptr as *const u16);
        let cp = *(ptr as *const u16).add(1);
        let q: Vec<u16> = format!("\\StringFileInfo\\{lang:04x}{cp:04x}\\FileDescription").encode_utf16().chain(Some(0)).collect();
        if !VerQueryValueW(buf.as_ptr() as _, PCWSTR(q.as_ptr()), &mut ptr, &mut len).as_bool() || len == 0 { return None; }
        let s = std::slice::from_raw_parts(ptr as *const u16, len as usize);
        let text = String::from_utf16_lossy(s).trim_end_matches('\0').trim().to_string();
        if text.is_empty() { None } else { Some(text) }
    }
}

// MARK: Raw input: key presses, left clicks and scrolls anywhere (mouse moves alone don't count).

unsafe extern "system" fn input_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_INPUT {
        let mut raw = RAWINPUT::default();
        let mut size = std::mem::size_of::<RAWINPUT>() as u32;
        let got = GetRawInputData(HRAWINPUT(lp.0 as _), RID_INPUT, Some(&mut raw as *mut _ as _), &mut size,
                                  std::mem::size_of::<RAWINPUTHEADER>() as u32);
        if got != u32::MAX && got > 0 {
            let hands = match raw.header.dwType {
                1 => { let m = raw.data.keyboard.Message; m == 0x0100 || m == 0x0104 } // WM_KEYDOWN, WM_SYSKEYDOWN
                0 => { let f = raw.data.mouse.Anonymous.Anonymous.usButtonFlags; f & (0x0001 | 0x0400 | 0x0800) != 0 } // left down, wheel, h-wheel
                _ => false,
            };
            if hands { LAST_HANDS.store(GetTickCount64(), Ordering::Relaxed); }
        }
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

fn raw_input_thread() {
    unsafe {
        let Ok(module) = GetModuleHandleW(None) else { return };
        let class = WNDCLASSW { lpfnWndProc: Some(input_proc), hInstance: module.into(), lpszClassName: w!("WorkClockInput"), ..Default::default() };
        RegisterClassW(&class);
        let Ok(hwnd) = CreateWindowExW(WINDOW_EX_STYLE(0), w!("WorkClockInput"), w!(""), WINDOW_STYLE(0), 0, 0, 0, 0, None, None, module, None) else { return };
        let devices = [
            RAWINPUTDEVICE { usUsagePage: 1, usUsage: 6, dwFlags: RIDEV_INPUTSINK, hwndTarget: hwnd }, // keyboard
            RAWINPUTDEVICE { usUsagePage: 1, usUsage: 2, dwFlags: RIDEV_INPUTSINK, hwndTarget: hwnd }, // mouse
        ];
        if RegisterRawInputDevices(&devices, std::mem::size_of::<RAWINPUTDEVICE>() as u32).is_err() { return; }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

#[allow(dead_code)]
fn _assert_interface(e: &IUIAutomationElement) -> windows::core::Result<()> { e.cast::<IUIAutomationElement>().map(|_| ()) }
