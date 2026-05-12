pub mod row_decoder;

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;
use std::ffi::c_void;

// --- FFI Bindings to APEX C Allocator ---
extern "C" {
    pub fn apex_init();
    pub fn apex_alloc(size: usize) -> *mut c_void;
    pub fn apex_free(ptr: *mut c_void, size: usize);
}

/// Standard InnoDB Page Size is 16KB
pub const INNODB_PAGE_SIZE: usize = 16384;

/// InnoDB Page Types
pub const FIL_PAGE_INDEX: u16 = 17855; // B-tree node containing actual row data
pub const FIL_PAGE_TYPE_ALLOCATED: u16 = 0; // Freshly allocated page

/// Represents the 38-byte FIL Header found at the absolute beginning of every InnoDB page.
#[derive(Debug, PartialEq)]
pub struct FilHeader {
    pub checksum: u32,
    pub page_offset: u32,
    pub previous_page: u32,
    pub next_page: u32,
    pub lsn: u64,
    pub page_type: u16,
    pub flush_lsn: u64,
    pub space_id: u32,
}

impl FilHeader {
    /// Parses the 38-byte FIL header from a raw 16KB binary page block.
    pub fn parse(page_data: &[u8]) -> Self {
        assert!(page_data.len() >= 38, "Page data too small to contain FIL header");
        
        FilHeader {
            checksum: u32::from_be_bytes(page_data[0..4].try_into().unwrap()),
            page_offset: u32::from_be_bytes(page_data[4..8].try_into().unwrap()),
            previous_page: u32::from_be_bytes(page_data[8..12].try_into().unwrap()),
            next_page: u32::from_be_bytes(page_data[12..16].try_into().unwrap()),
            lsn: u64::from_be_bytes(page_data[16..24].try_into().unwrap()),
            page_type: u16::from_be_bytes(page_data[24..26].try_into().unwrap()),
            flush_lsn: u64::from_be_bytes(page_data[26..34].try_into().unwrap()),
            space_id: u32::from_be_bytes(page_data[34..38].try_into().unwrap()),
        }
    }
}

/// Represents the 56-byte PAGE Header found immediately after the FIL Header (Offset 38)
#[derive(Debug, PartialEq)]
pub struct PageHeader {
    pub n_dir_slots: u16, // Number of slots in the Page Directory
    pub heap_top: u16,    // Byte offset where free space starts
    pub n_recs: u16,      // Number of records in the page
}

impl PageHeader {
    pub fn parse(page_data: &[u8]) -> Self {
        assert!(page_data.len() >= 94, "Page data too small for PAGE header");
        PageHeader {
            // PAGE_N_DIR_SLOTS is at offset 38
            n_dir_slots: u16::from_be_bytes(page_data[38..40].try_into().unwrap()),
            // PAGE_HEAP_TOP is at offset 40
            heap_top: u16::from_be_bytes(page_data[40..42].try_into().unwrap()),
            // PAGE_N_RECS is at offset 54
            n_recs: u16::from_be_bytes(page_data[54..56].try_into().unwrap()),
        }
    }
}

/// The APEX Storage Engine responsible for reading raw MySQL .ibd files off the hard drive
pub struct StorageEngine {
    file: File,
}

impl StorageEngine {
    /// Opens a MySQL InnoDB Tablespace (.ibd) file directly
    pub fn open<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        let file = File::open(path)?;
        Ok(StorageEngine { file })
    }

    /// Reads a specific 16KB page from the .ibd file
    pub fn read_page(&mut self, page_number: u32) -> io::Result<Vec<u8>> {
        let offset = (page_number as u64) * (INNODB_PAGE_SIZE as u64);
        self.file.seek(SeekFrom::Start(offset))?;
        
        let mut buffer = vec![0u8; INNODB_PAGE_SIZE];
        self.file.read_exact(&mut buffer)?;
        
        Ok(buffer)
    }

    /// Extracts row offsets from the Page Directory (which lives at the very end of the 16KB page)
    pub fn parse_directory_slots(page_data: &[u8], n_slots: u16) -> Vec<u16> {
        let mut offsets = Vec::with_capacity(n_slots as usize);
        // The directory grows backwards from the end of the page (16384). Each slot is 2 bytes.
        // Format: [..., Slot 3, Slot 2, Slot 1, Slot 0] -> End of Page
        let mut ptr = INNODB_PAGE_SIZE - 1; 
        
        for _ in 0..n_slots {
            let offset = u16::from_be_bytes(page_data[ptr - 1..=ptr].try_into().unwrap());
            offsets.push(offset);
            ptr -= 2; // Move backwards
        }
        offsets
    }

    /// Loads the B-Tree row data directly into the APEX C Slab Allocator
    pub fn load_into_c_allocator(&self, row_data: &[u8]) {
        unsafe {
            // 1. Ask our custom C Allocator for memory instantly (Lock-Free)
            let c_ptr = apex_alloc(row_data.len());
            
            // 2. Copy the MySQL row data directly into the high-performance memory slab
            std::ptr::copy_nonoverlapping(row_data.as_ptr(), c_ptr as *mut u8, row_data.len());
            
            // Note: The Rust JIT Engine now has access to this data completely outside the OS!
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_parse_innodb_header_and_directory() {
        // Mock C Allocator init
        unsafe { apex_init() };

        let mut mock_page = vec![0u8; INNODB_PAGE_SIZE];
        
        // --- 1. FIL Header & PAGE Header Setup ---
        mock_page[24] = 0x45; mock_page[25] = 0xBF; // Page Type = Index
        mock_page[38] = 0x00; mock_page[39] = 0x01; // 1 Directory Slot
        
        // --- 2. Mock InnoDB COMPACT Row at Offset 120 ---
        let row_offset = 120;
        
        // Metadata (Grows backwards from pointer)
        // Record Header (5 bytes): Offset 115-119
        mock_page[115] = 0x00; mock_page[116] = 0x00; mock_page[117] = 0x00; mock_page[118] = 0x00; mock_page[119] = 0x00;
        
        // Null Flags (1 byte, 0 nullable cols for this test): Offset 114
        mock_page[114] = 0x00; 
        
        // Var Lengths (1 byte, for the VARCHAR board): Offset 113
        mock_page[113] = 0x04; // The string "CBSE" is 4 bytes long!
        
        // Row Data (Grows forwards from pointer)
        // Transaction ID (6 bytes): Offset 120-125
        mock_page[120..126].copy_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x0A, 0x1B]); // Trx: 2587
        // Roll Pointer (7 bytes): Offset 126-132
        mock_page[126..133].copy_from_slice(&[0x80, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04]);
        
        // Column 1: 'score' (INT, 4 bytes): Offset 133-136
        // Let's say the student scored a 95
        mock_page[133..137].copy_from_slice(&95u32.to_be_bytes());
        
        // Column 2: 'board' (VARCHAR, 4 bytes based on var_length): Offset 137-140
        mock_page[137..141].copy_from_slice(b"CBSE");

        // --- 3. Page Directory Setup ---
        // End of page is 16383. Slot 0 (bytes 16382-16383) -> offset 120
        mock_page[16382] = 0x00; mock_page[16383] = 120;

        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(&mock_page).unwrap();

        let mut engine = StorageEngine::open(temp_file.path()).unwrap();
        let page_data = engine.read_page(0).unwrap();
        
        // --- Execution Pipeline ---
        let page_hdr = PageHeader::parse(&page_data);
        let slots = StorageEngine::parse_directory_slots(&page_data, page_hdr.n_dir_slots);
        
        assert_eq!(slots[0], 120, "Should find the row offset in the B-Tree Directory");

        // Use our new Row Decoder to extract the COMPACT format!
        // We pass 1 nullable column (so it expects 1 byte of null flags), and 1 variable length column
        let decoded_row = row_decoder::decode_compact_row(&page_data, slots[0] as usize, 1, 1);
        
        // Verify the extracted bytes!
        let extracted_score = u32::from_be_bytes(decoded_row.column_data[0..4].try_into().unwrap());
        let extracted_board = std::str::from_utf8(&decoded_row.column_data[4..8]).unwrap();
        
        assert_eq!(extracted_score, 95, "Should correctly decode the integer score from the binary bytes!");
        assert_eq!(extracted_board, "CBSE", "Should correctly decode the VARCHAR based on the backwards length offset!");

        // Finally, load those exact decoded bytes into the C Memory Allocator!
        engine.load_into_c_allocator(&decoded_row.column_data);
    }
}
