/// Shell v2 protocol framing
///
/// Shell v2 multiplexes stdin/stdout/stderr/exit over a single ADB stream.
/// Each frame: [1 byte id] [4 bytes LE length] [payload]

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ShellV2Id {
    Stdin = 0,
    Stdout = 1,
    Stderr = 2,
    Exit = 3,
    CloseStdin = 4,
    WindowSizeChange = 5,
}

impl ShellV2Id {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(Self::Stdin),
            1 => Some(Self::Stdout),
            2 => Some(Self::Stderr),
            3 => Some(Self::Exit),
            4 => Some(Self::CloseStdin),
            5 => Some(Self::WindowSizeChange),
            _ => None,
        }
    }
}

/// A decoded shell v2 frame
#[derive(Debug)]
pub struct ShellV2Frame {
    pub id: ShellV2Id,
    pub data: Vec<u8>,
}

impl ShellV2Frame {
    pub fn new(id: ShellV2Id, data: Vec<u8>) -> Self {
        Self { id, data }
    }

    pub fn stdout(data: Vec<u8>) -> Self {
        Self::new(ShellV2Id::Stdout, data)
    }

    pub fn stderr(data: Vec<u8>) -> Self {
        Self::new(ShellV2Id::Stderr, data)
    }

    pub fn exit(code: u8) -> Self {
        Self::new(ShellV2Id::Exit, vec![code])
    }

    /// Serialize to bytes: [id:1][length:4 LE][payload]
    pub fn to_bytes(&self) -> Vec<u8> {
        let len = self.data.len() as u32;
        let mut buf = Vec::with_capacity(5 + self.data.len());
        buf.push(self.id as u8);
        buf.extend_from_slice(&len.to_le_bytes());
        buf.extend_from_slice(&self.data);
        buf
    }

    /// Parse a shell v2 frame from the beginning of a buffer.
    /// Returns (frame, bytes_consumed) or None if not enough data.
    pub fn parse(buf: &[u8]) -> Option<(Self, usize)> {
        if buf.len() < 5 {
            return None;
        }
        let id = ShellV2Id::from_u8(buf[0])?;
        let length = u32::from_le_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
        if buf.len() < 5 + length {
            return None;
        }
        let data = buf[5..5 + length].to_vec();
        Some((Self { id, data }, 5 + length))
    }
}
