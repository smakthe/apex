use crate::INNODB_PAGE_SIZE;

/// Represents a decoded row from the MySQL InnoDB COMPACT format
#[derive(Debug)]
pub struct DecodedRow {
    pub transaction_id: [u8; 6],
    pub roll_pointer: [u8; 7],
    pub column_data: Vec<u8>, // The raw extracted bytes for our target columns
}

/// Decodes an InnoDB COMPACT Row given the page data and the exact byte offset of the row
pub fn decode_compact_row(
    page_data: &[u8],
    row_offset: usize,
    num_nullable_cols: usize,
    num_var_len_cols: usize,
) -> DecodedRow {
    // In InnoDB COMPACT format, the row pointer points to the START of the actual data.
    // The Metadata (Header, Null Flags, Var Lengths) is stored BACKWARDS from the pointer!
    
    // 1. The 5-byte Record Header is right before the data pointer
    let _header_start = row_offset - 5;
    let _info_flags = page_data[_header_start]; // 4 bits info, 4 bits number of records owned
    let _next_record_offset = u16::from_be_bytes(page_data[_header_start + 3.._header_start + 5].try_into().unwrap());

    // 2. The Null Flags Bitmap is stored before the header
    // Calculates how many bytes the null flags take (1 bit per nullable column)
    let null_flags_len = (num_nullable_cols + 7) / 8;
    let _null_flags_start = row_offset - 5 - null_flags_len;
    // (Here we would read the bitmask to check if our target columns are NULL)

    // 3. The Variable-Length Array is stored before the Null Flags
    // Calculates how many bytes the var-len array takes (1 or 2 bytes per variable column like VARCHAR)
    let var_len_start = row_offset - 5 - null_flags_len - num_var_len_cols;
    let var_lengths = &page_data[var_len_start.._null_flags_start];

    // 4. Decode the Actual Row Data (Forward from the pointer)
    let mut current_offset = row_offset;

    // Every InnoDB row automatically starts with hidden MVCC transaction metadata
    let mut transaction_id = [0u8; 6];
    transaction_id.copy_from_slice(&page_data[current_offset..current_offset + 6]);
    current_offset += 6;

    let mut roll_pointer = [0u8; 7];
    roll_pointer.copy_from_slice(&page_data[current_offset..current_offset + 7]);
    current_offset += 7;

    // 5. Extract the Target Columns (e.g., 'score' INT, 'board' VARCHAR)
    // For this prototype, we simulate extracting an INT (4 bytes) and a VARCHAR (length defined in var_lengths)
    let mut column_data = Vec::new();
    
    // Read INT 'score' (4 bytes)
    column_data.extend_from_slice(&page_data[current_offset..current_offset + 4]);
    current_offset += 4;

    // Read VARCHAR 'board' (assuming the first byte of var_lengths tells us the string length)
    if !var_lengths.is_empty() {
        let board_len = var_lengths[0] as usize; 
        column_data.extend_from_slice(&page_data[current_offset..current_offset + board_len]);
    }

    DecodedRow {
        transaction_id,
        roll_pointer,
        column_data,
    }
}
