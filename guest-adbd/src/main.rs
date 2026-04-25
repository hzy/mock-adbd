mod protocol;
mod session;
mod shell_v2;

use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

use log::{debug, error, info, warn};

use protocol::*;
use session::{SessionManager, ShellSession};
use shell_v2::{ShellV2Frame, ShellV2Id};

/// Device banner — what we report to adb client
const DEVICE_BANNER: &str = "device::ro.product.name=mock;ro.product.model=AdbMock;ro.product.device=mock;features=shell_v2,cmd";

/// Read exactly `n` bytes from a stream
fn read_exact(stream: &mut TcpStream, buf: &mut [u8]) -> io::Result<()> {
    let mut offset = 0;
    while offset < buf.len() {
        match stream.read(&mut buf[offset..]) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed")),
            Ok(n) => offset += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Read a complete ADB message (header + data) from stream
fn read_message(stream: &mut TcpStream) -> io::Result<AdbMessage> {
    let mut header_buf = [0u8; 24];
    read_exact(stream, &mut header_buf)?;

    let mut msg = AdbMessage::parse_header(&header_buf)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    if msg.data_length > 0 {
        let mut data = vec![0u8; msg.data_length as usize];
        read_exact(stream, &mut data)?;
        msg.data = data;
    }

    debug!(
        "← {} arg0={} arg1={} data_len={}",
        msg.command_name(),
        msg.arg0,
        msg.arg1,
        msg.data_length
    );

    Ok(msg)
}

/// Send a complete ADB message
fn send_message(stream: &mut TcpStream, msg: &AdbMessage) -> io::Result<()> {
    debug!(
        "→ {} arg0={} arg1={} data_len={}",
        msg.command_name(),
        msg.arg0,
        msg.arg1,
        msg.data_length
    );
    stream.write_all(&msg.to_bytes())
}

/// Parse the OPEN destination string to determine service type
#[derive(Debug)]
enum Service {
    ShellV1(Option<String>),        // shell: or shell:command
    ShellV2(Option<String>),        // shell,v2: or shell,v2:command
    Other(String),                  // Unsupported
}

fn parse_service(dest: &str) -> Service {
    // Remove trailing null
    let dest = dest.trim_end_matches('\0');

    if dest == "shell:" || dest == "shell" {
        Service::ShellV1(None)
    } else if dest.starts_with("shell:") {
        let cmd = &dest[6..];
        Service::ShellV1(Some(cmd.to_string()))
    } else if dest.starts_with("shell,v2:") {
        let cmd = &dest[9..];
        if cmd.is_empty() {
            Service::ShellV2(None)
        } else {
            Service::ShellV2(Some(cmd.to_string()))
        }
    } else if dest.starts_with("shell,v2,") {
        // shell,v2,TERM=xterm:command or shell,v2,raw:command
        if let Some(colon_pos) = dest.find(':') {
            let cmd = &dest[colon_pos + 1..];
            if cmd.is_empty() {
                Service::ShellV2(None)
            } else {
                Service::ShellV2(Some(cmd.to_string()))
            }
        } else {
            Service::ShellV2(None)
        }
    } else {
        Service::Other(dest.to_string())
    }
}

/// Handle one ADB connection (one adb server session)
fn handle_connection(mut stream: TcpStream) -> io::Result<()> {
    let peer = stream.peer_addr()?;
    info!("New connection from {}", peer);

    // Set TCP nodelay for responsiveness
    stream.set_nodelay(true)?;

    let mut sessions = SessionManager::new();
    let mut connected = false;

    // Set read timeout for polling shell output
    stream.set_read_timeout(Some(Duration::from_millis(10)))?;

    loop {
        // 1. Try to read an ADB message from the client
        match read_adb_message_nonblocking(&mut stream) {
            Ok(Some(msg)) => {
                match msg.command {
                    A_CNXN => {
                        info!("CNXN from client: version={:#x} maxdata={}", msg.arg0, msg.arg1);
                        // Respond with our CNXN
                        let resp = AdbMessage::cnxn(DEVICE_BANNER);
                        send_message(&mut stream, &resp)?;
                        connected = true;
                        // Reset all sessions on new CNXN
                        sessions.clear();
                        info!("Connected, banner sent");
                    }
                    A_OPEN if connected => {
                        let dest = String::from_utf8_lossy(&msg.data).to_string();
                        let remote_id = msg.arg0;
                        info!("OPEN remote_id={} dest={:?}", remote_id, dest);

                        match parse_service(&dest) {
                            Service::ShellV1(cmd) => {
                                let local_id = sessions.alloc_local_id();
                                match ShellSession::new(
                                    local_id,
                                    remote_id,
                                    false,
                                    cmd.as_deref(),
                                ) {
                                    Ok(session) => {
                                        sessions.insert(session);
                                        let okay = AdbMessage::okay(local_id, remote_id);
                                        send_message(&mut stream, &okay)?;
                                    }
                                    Err(e) => {
                                        error!("Failed to spawn shell: {}", e);
                                        let clse = AdbMessage::clse(0, remote_id);
                                        send_message(&mut stream, &clse)?;
                                    }
                                }
                            }
                            Service::ShellV2(cmd) => {
                                let local_id = sessions.alloc_local_id();
                                match ShellSession::new(
                                    local_id,
                                    remote_id,
                                    true,
                                    cmd.as_deref(),
                                ) {
                                    Ok(session) => {
                                        sessions.insert(session);
                                        let okay = AdbMessage::okay(local_id, remote_id);
                                        send_message(&mut stream, &okay)?;
                                    }
                                    Err(e) => {
                                        error!("Failed to spawn shell v2: {}", e);
                                        let clse = AdbMessage::clse(0, remote_id);
                                        send_message(&mut stream, &clse)?;
                                    }
                                }
                            }
                            Service::Other(svc) => {
                                warn!("Unsupported service: {:?}", svc);
                                let clse = AdbMessage::clse(0, remote_id);
                                send_message(&mut stream, &clse)?;
                            }
                        }
                    }
                    A_WRTE if connected => {
                        let local_id = msg.arg1; // local_id on our side
                        let remote_id = msg.arg0;

                        // Send OKAY to acknowledge the WRTE
                        let okay = AdbMessage::okay(local_id, remote_id);
                        send_message(&mut stream, &okay)?;

                        if let Some(session) = sessions.get_mut(local_id) {
                            if session.v2 {
                                // Parse shell v2 frames from the data
                                let mut offset = 0;
                                while offset < msg.data.len() {
                                    if let Some((frame, consumed)) =
                                        ShellV2Frame::parse(&msg.data[offset..])
                                    {
                                        offset += consumed;
                                        match frame.id {
                                            ShellV2Id::Stdin => {
                                                if let Err(e) =
                                                    session.write_stdin(&frame.data)
                                                {
                                                    debug!("Write to shell stdin failed: {}", e);
                                                }
                                            }
                                            ShellV2Id::CloseStdin => {
                                                debug!("CloseStdin received for session {}", local_id);
                                                // Close stdin by closing master — actually just ignore,
                                                // the process will get EOF when we close
                                            }
                                            ShellV2Id::WindowSizeChange => {
                                                if frame.data.len() >= 4 {
                                                    let rows = u16::from_le_bytes(
                                                        [frame.data[0], frame.data[1]],
                                                    );
                                                    let cols = u16::from_le_bytes(
                                                        [frame.data[2], frame.data[3]],
                                                    );
                                                    debug!("Window size change: {}x{}", cols, rows);
                                                    // Set PTY window size
                                                    let ws = libc::winsize {
                                                        ws_row: rows,
                                                        ws_col: cols,
                                                        ws_xpixel: 0,
                                                        ws_ypixel: 0,
                                                    };
                                                    unsafe {
                                                        libc::ioctl(
                                                            session.master_fd,
                                                            libc::TIOCSWINSZ,
                                                            &ws,
                                                        );
                                                    }
                                                }
                                            }
                                            _ => {
                                                debug!("Ignoring shell v2 frame id={:?}", frame.id);
                                            }
                                        }
                                    } else {
                                        break;
                                    }
                                }
                            } else {
                                // Shell v1: raw data goes to stdin
                                if let Err(e) = session.write_stdin(&msg.data) {
                                    debug!("Write to shell stdin failed: {}", e);
                                }
                            }
                        }
                    }
                    A_CLSE if connected => {
                        let local_id = msg.arg1;
                        let remote_id = msg.arg0;
                        info!("CLSE local_id={} remote_id={}", local_id, remote_id);

                        if let Some(session) = sessions.remove(local_id) {
                            let clse = AdbMessage::clse(session.local_id, session.remote_id);
                            send_message(&mut stream, &clse)?;
                        }
                    }
                    A_OKAY if connected => {
                        // Client acknowledged our WRTE, we can send more
                        debug!("OKAY from client: arg0={} arg1={}", msg.arg0, msg.arg1);
                    }
                    _ => {
                        if !connected {
                            warn!("Message before CNXN: {}", msg.command_name());
                        } else {
                            warn!("Unexpected command: {}", msg.command_name());
                        }
                    }
                }
            }
            Ok(None) => {
                // No data available right now, that's fine
            }
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                info!("Client disconnected: {}", peer);
                break;
            }
            Err(e) => {
                error!("Read error: {}", e);
                break;
            }
        }

        // 2. Poll all shell sessions for output and send to client
        if connected {
            let ids = sessions.active_ids();
            for id in ids {
                let mut should_close = false;
                let mut wrte_msgs: Vec<AdbMessage> = Vec::new();

                if let Some(session) = sessions.get_mut(id) {
                    // Read stdout
                    match session.read_stdout() {
                        Ok(Some(data)) if !data.is_empty() => {
                            if session.v2 {
                                let frame = ShellV2Frame::stdout(data);
                                wrte_msgs.push(AdbMessage::wrte(
                                    session.local_id,
                                    session.remote_id,
                                    frame.to_bytes(),
                                ));
                            } else {
                                wrte_msgs.push(AdbMessage::wrte(
                                    session.local_id,
                                    session.remote_id,
                                    data,
                                ));
                            }
                        }
                        Ok(_) => {}
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                        Err(e) => {
                            debug!("Read stdout error: {} (session {})", e, id);
                            // EIO typically means child exited
                            if e.raw_os_error() == Some(5) {
                                // Will handle in try_wait below
                            }
                        }
                    }

                    // Read stderr (v2 only)
                    if session.v2 {
                        match session.read_stderr() {
                            Ok(Some(data)) if !data.is_empty() => {
                                let frame = ShellV2Frame::stderr(data);
                                wrte_msgs.push(AdbMessage::wrte(
                                    session.local_id,
                                    session.remote_id,
                                    frame.to_bytes(),
                                ));
                            }
                            Ok(_) => {}
                            Err(_) => {}
                        }
                    }

                    // Check if child exited
                    if let Some(exit_code) = session.try_wait() {
                        info!("Shell session {} exited with code {}", id, exit_code);
                        if session.v2 {
                            let frame = ShellV2Frame::exit(exit_code);
                            wrte_msgs.push(AdbMessage::wrte(
                                session.local_id,
                                session.remote_id,
                                frame.to_bytes(),
                            ));
                        }
                        should_close = true;
                    }
                }

                // Send queued WRTE messages
                for msg in &wrte_msgs {
                    if let Err(e) = send_message(&mut stream, msg) {
                        error!("Failed to send WRTE: {}", e);
                        return Err(e);
                    }
                }

                if should_close {
                    if let Some(session) = sessions.get(id) {
                        let clse =
                            AdbMessage::clse(session.local_id, session.remote_id);
                        let _ = send_message(&mut stream, &clse);
                    }
                    sessions.remove(id);
                }
            }
        }

        // Small sleep to avoid busy-looping when nothing happens
        std::thread::sleep(Duration::from_millis(1));
    }

    sessions.clear();
    info!("Connection handler finished for {}", peer);
    Ok(())
}

/// Try to read an ADB message without blocking.
/// Returns Ok(None) if no data available yet.
fn read_adb_message_nonblocking(stream: &mut TcpStream) -> io::Result<Option<AdbMessage>> {
    // Peek first to see if we have data
    let mut peek_buf = [0u8; 1];
    match stream.peek(&mut peek_buf) {
        Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "connection closed")),
        Ok(_) => {
            // Data available, switch to blocking temporarily to read the full message
            stream.set_read_timeout(Some(Duration::from_secs(5)))?;
            let result = read_message(stream);
            stream.set_read_timeout(Some(Duration::from_millis(10)))?;
            result.map(Some)
        }
        Err(e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
            Ok(None)
        }
        Err(e) => Err(e),
    }
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    let bind_addr = std::env::var("ADBD_LISTEN").unwrap_or_else(|_| "0.0.0.0:5555".to_string());

    info!("mock-adbd starting on {}", bind_addr);
    info!("Banner: {}", DEVICE_BANNER);

    let listener = TcpListener::bind(&bind_addr).expect("Failed to bind");
    info!("Listening on {}", bind_addr);

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                // Handle each connection in a new thread
                std::thread::spawn(move || {
                    if let Err(e) = handle_connection(stream) {
                        error!("Connection error: {}", e);
                    }
                });
            }
            Err(e) => {
                error!("Accept error: {}", e);
            }
        }
    }
}
