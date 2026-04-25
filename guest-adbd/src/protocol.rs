/// ADB protocol constants and message types
pub const ADB_VERSION: u32 = 0x01000001;
pub const MAX_PAYLOAD: u32 = 256 * 1024; // 256 KiB

// ADB command identifiers
pub const A_CNXN: u32 = 0x4e584e43; // "CNXN"
pub const A_OPEN: u32 = 0x4e45504f; // "OPEN"
pub const A_OKAY: u32 = 0x59414b4f; // "OKAY"
pub const A_CLSE: u32 = 0x45534c43; // "CLSE"
pub const A_WRTE: u32 = 0x45545257; // "WRTE"
pub const A_AUTH: u32 = 0x48545541; // "AUTH"

/// ADB message header (24 bytes)
#[derive(Debug, Clone)]
pub struct AdbMessage {
    pub command: u32,
    pub arg0: u32,
    pub arg1: u32,
    pub data_length: u32,
    pub data_crc32: u32,
    pub magic: u32,
    pub data: Vec<u8>,
}

impl AdbMessage {
    pub fn new(command: u32, arg0: u32, arg1: u32, data: Vec<u8>) -> Self {
        let data_length = data.len() as u32;
        let data_crc32 = data.iter().fold(0u32, |acc, &b| acc.wrapping_add(b as u32));
        let magic = command ^ 0xFFFFFFFF;
        AdbMessage {
            command,
            arg0,
            arg1,
            data_length,
            data_crc32,
            magic,
            data,
        }
    }

    pub fn cnxn(banner: &str) -> Self {
        let mut data = banner.as_bytes().to_vec();
        data.push(0); // null terminate
        Self::new(A_CNXN, ADB_VERSION, MAX_PAYLOAD, data)
    }

    pub fn okay(local_id: u32, remote_id: u32) -> Self {
        Self::new(A_OKAY, local_id, remote_id, vec![])
    }

    pub fn clse(local_id: u32, remote_id: u32) -> Self {
        Self::new(A_CLSE, local_id, remote_id, vec![])
    }

    pub fn wrte(local_id: u32, remote_id: u32, data: Vec<u8>) -> Self {
        Self::new(A_WRTE, local_id, remote_id, data)
    }

    /// Serialize to bytes (header + data)
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(24 + self.data.len());
        buf.extend_from_slice(&self.command.to_le_bytes());
        buf.extend_from_slice(&self.arg0.to_le_bytes());
        buf.extend_from_slice(&self.arg1.to_le_bytes());
        buf.extend_from_slice(&self.data_length.to_le_bytes());
        buf.extend_from_slice(&self.data_crc32.to_le_bytes());
        buf.extend_from_slice(&self.magic.to_le_bytes());
        buf.extend_from_slice(&self.data);
        buf
    }

    /// Parse header from 24 bytes, returns message without data
    pub fn parse_header(buf: &[u8; 24]) -> Result<Self, &'static str> {
        let command = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        let arg0 = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let arg1 = u32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]);
        let data_length = u32::from_le_bytes([buf[12], buf[13], buf[14], buf[15]]);
        let data_crc32 = u32::from_le_bytes([buf[16], buf[17], buf[18], buf[19]]);
        let magic = u32::from_le_bytes([buf[20], buf[21], buf[22], buf[23]]);

        if command ^ 0xFFFFFFFF != magic {
            return Err("invalid magic");
        }

        if data_length > MAX_PAYLOAD {
            return Err("data_length exceeds MAX_PAYLOAD");
        }

        Ok(AdbMessage {
            command,
            arg0,
            arg1,
            data_length,
            data_crc32,
            magic,
            data: vec![],
        })
    }

    pub fn command_name(&self) -> &'static str {
        match self.command {
            A_CNXN => "CNXN",
            A_OPEN => "OPEN",
            A_OKAY => "OKAY",
            A_CLSE => "CLSE",
            A_WRTE => "WRTE",
            A_AUTH => "AUTH",
            _ => "UNKNOWN",
        }
    }
}
