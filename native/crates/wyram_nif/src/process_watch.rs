use rustler::ResourceArc;
#[cfg(windows)]
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
    WaitForSingleObject,
};

pub struct ProcessWatch {
    #[cfg(windows)]
    handle: OwnedHandle,
}
#[rustler::resource_impl]
impl rustler::Resource for ProcessWatch {}

#[rustler::nif]
fn watch_process(pid: u32) -> Result<ResourceArc<ProcessWatch>, String> {
    #[cfg(windows)]
    {
        // SAFETY: OpenProcess uses a scalar PID, requests only query/wait access,
        // and returns a newly owned handle. Null is rejected before taking ownership.
        let handle = unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                0,
                pid,
            )
        };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error().to_string());
        }
        // SAFETY: this unique handle is now closed exactly once by OwnedHandle.
        let handle = unsafe { OwnedHandle::from_raw_handle(handle) };
        Ok(ResourceArc::new(ProcessWatch { handle }))
    }
    #[cfg(not(windows))]
    {
        let _ = pid;
        Err("Windows process monitoring unavailable".to_owned())
    }
}

#[rustler::nif]
fn process_status(watch: ResourceArc<ProcessWatch>) -> Result<Option<u32>, String> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
        let handle = watch.handle.as_raw_handle();
        // SAFETY: the resource keeps this process handle alive throughout the call.
        // Timeout zero polls; this never waits on an OS process in a scheduler.
        match unsafe { WaitForSingleObject(handle, 0) } {
            WAIT_TIMEOUT => Ok(None),
            WAIT_OBJECT_0 => {
                let mut status = 0;
                // SAFETY: status is writable and the borrowed process handle remains valid.
                if unsafe { GetExitCodeProcess(handle, &mut status) } == 0 {
                    Err(std::io::Error::last_os_error().to_string())
                } else {
                    Ok(Some(status))
                }
            }
            _ => Err(std::io::Error::last_os_error().to_string()),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = watch;
        Err("Windows process monitoring unavailable".to_owned())
    }
}
