use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use log::{debug, error};

pub const ID_STAT: u32 = 0x54415453; // "STAT"
pub const ID_LIST: u32 = 0x5453494c; // "LIST"
pub const ID_DENT: u32 = 0x544e4544; // "DENT"
pub const ID_SEND: u32 = 0x444e4553; // "SEND"
pub const ID_RECV: u32 = 0x56434552; // "RECV"
pub const ID_DONE: u32 = 0x454e4f44; // "DONE"
pub const ID_DATA: u32 = 0x41544144; // "DATA"
pub const ID_OKAY: u32 = 0x59414b4f; // "OKAY"
pub const ID_FAIL: u32 = 0x4c494146; // "FAIL"
pub const ID_QUIT: u32 = 0x54495551; // "QUIT"

pub struct SyncSession {
    pub local_id: u32,
    pub remote_id: u32,
    buffer: Vec<u8>,
    current_file: Option<fs::File>,
    state: SyncState,
}

#[derive(Debug, PartialEq)]
enum SyncState {
    Idle,
    ReceivingFile,
}

impl SyncSession {
    pub fn new(local_id: u32, remote_id: u32) -> Self {
        Self {
            local_id,
            remote_id,
            buffer: Vec::new(),
            current_file: None,
            state: SyncState::Idle,
        }
    }

    pub fn handle_data(&mut self, data: &[u8]) -> Vec<u8> {
        self.buffer.extend_from_slice(data);
        let mut response = Vec::new();

        loop {
            match self.state {
                SyncState::Idle => {
                    if self.buffer.len() < 8 {
                        break;
                    }
                    let id = u32::from_le_bytes(self.buffer[0..4].try_into().unwrap());
                    let length = u32::from_le_bytes(self.buffer[4..8].try_into().unwrap()) as usize;
                    
                    if id == ID_QUIT {
                        self.buffer.drain(0..8);
                        break;
                    }

                    if self.buffer.len() < 8 + length {
                        break;
                    }

                    let payload = self.buffer[8..8 + length].to_vec();
                    self.buffer.drain(0..8 + length);

                    match id {
                        ID_STAT => {
                            let path = String::from_utf8_lossy(&payload).to_string();
                            debug!("sync STAT: {}", path);
                            if let Ok(metadata) = fs::metadata(&path) {
                                let mode = metadata.permissions().mode();
                                let size = metadata.len() as u32;
                                let mtime = metadata.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH).duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as u32;
                                response.extend_from_slice(&ID_STAT.to_le_bytes());
                                response.extend_from_slice(&mode.to_le_bytes());
                                response.extend_from_slice(&size.to_le_bytes());
                                response.extend_from_slice(&mtime.to_le_bytes());
                            } else {
                                response.extend_from_slice(&ID_STAT.to_le_bytes());
                                response.extend_from_slice(&0u32.to_le_bytes());
                                response.extend_from_slice(&0u32.to_le_bytes());
                                response.extend_from_slice(&0u32.to_le_bytes());
                            }
                        }
                        ID_LIST => {
                            let path = String::from_utf8_lossy(&payload).to_string();
                            debug!("sync LIST: {}", path);
                            if let Ok(entries) = fs::read_dir(&path) {
                                for entry in entries.flatten() {
                                    if let Ok(metadata) = entry.metadata() {
                                        let name = entry.file_name().into_string().unwrap_or_default();
                                        let mode = metadata.permissions().mode();
                                        let size = metadata.len() as u32;
                                        let mtime = metadata.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH).duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as u32;
                                        
                                        response.extend_from_slice(&ID_DENT.to_le_bytes());
                                        response.extend_from_slice(&mode.to_le_bytes());
                                        response.extend_from_slice(&size.to_le_bytes());
                                        response.extend_from_slice(&mtime.to_le_bytes());
                                        response.extend_from_slice(&(name.len() as u32).to_le_bytes());
                                        response.extend_from_slice(name.as_bytes());
                                    }
                                }
                            }
                            response.extend_from_slice(&ID_DONE.to_le_bytes());
                            response.extend_from_slice(&0u32.to_le_bytes());
                            response.extend_from_slice(&0u32.to_le_bytes());
                            response.extend_from_slice(&0u32.to_le_bytes());
                            response.extend_from_slice(&0u32.to_le_bytes());
                        }
                        ID_SEND => {
                            let path_mode = String::from_utf8_lossy(&payload).to_string();
                            let parts: Vec<&str> = path_mode.split(',').collect();
                            let path = parts[0];
                            debug!("sync SEND: {}", path);
                            
                            if let Some(parent) = std::path::Path::new(path).parent() {
                                let _ = fs::create_dir_all(parent);
                            }
                            
                            match fs::File::create(path) {
                                Ok(f) => {
                                    self.current_file = Some(f);
                                    self.state = SyncState::ReceivingFile;
                                }
                                Err(e) => {
                                    error!("sync SEND create err: {}", e);
                                    let msg = "fail".as_bytes();
                                    response.extend_from_slice(&ID_FAIL.to_le_bytes());
                                    response.extend_from_slice(&(msg.len() as u32).to_le_bytes());
                                    response.extend_from_slice(msg);
                                }
                            }
                        }
                        ID_RECV => {
                            let path = String::from_utf8_lossy(&payload).to_string();
                            debug!("sync RECV: {}", path);
                            if let Ok(mut f) = fs::File::open(&path) {
                                let mut buf = [0u8; 64 * 1024];
                                loop {
                                    match f.read(&mut buf) {
                                        Ok(0) => break,
                                        Ok(n) => {
                                            response.extend_from_slice(&ID_DATA.to_le_bytes());
                                            response.extend_from_slice(&(n as u32).to_le_bytes());
                                            response.extend_from_slice(&buf[..n]);
                                        }
                                        Err(_) => break,
                                    }
                                }
                            } else {
                                let msg = "fail".as_bytes();
                                response.extend_from_slice(&ID_FAIL.to_le_bytes());
                                response.extend_from_slice(&(msg.len() as u32).to_le_bytes());
                                response.extend_from_slice(msg);
                            }
                            response.extend_from_slice(&ID_DONE.to_le_bytes());
                            response.extend_from_slice(&0u32.to_le_bytes());
                        }
                        _ => {
                            debug!("sync unknown id: {:x}", id);
                        }
                    }
                }
                SyncState::ReceivingFile => {
                    if self.buffer.len() < 8 {
                        break;
                    }
                    let id = u32::from_le_bytes(self.buffer[0..4].try_into().unwrap());
                    let length = u32::from_le_bytes(self.buffer[4..8].try_into().unwrap()) as usize;
                    
                    if id == ID_DONE {
                        self.buffer.drain(0..8);
                        self.current_file = None;
                        self.state = SyncState::Idle;
                        response.extend_from_slice(&ID_OKAY.to_le_bytes());
                        response.extend_from_slice(&0u32.to_le_bytes());
                        continue;
                    }
                    
                    if id == ID_DATA {
                        if self.buffer.len() < 8 + length {
                            break;
                        }
                        if let Some(f) = &mut self.current_file {
                            let _ = f.write_all(&self.buffer[8..8 + length]);
                        }
                        self.buffer.drain(0..8 + length);
                    } else {
                        self.state = SyncState::Idle;
                        self.current_file = None;
                        break;
                    }
                }
            }
        }
        response
    }
}
