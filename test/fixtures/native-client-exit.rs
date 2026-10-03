use std::io::{self, Read};

fn main() {
    let mut input = io::stdin().lock();
    // Drain the initial 5x5x32 full-height view, ignoring coalesced character snapshots.
    // Chunk batches and individual updates share the same data field.
    let mut chunks = 0;
    while chunks < 800 {
        let mut prefix = [0; 4];
        input.read_exact(&mut prefix).unwrap();
        let length=u32::from_be_bytes(prefix) as usize;
        assert!(length<=4*1024*1024);
        let mut bytes = vec![0; length];
        input.read_exact(&mut bytes).unwrap();
        chunks += String::from_utf8(bytes).unwrap().matches("\"data\":").count();
    }
    std::process::exit(
        std::env::var("WYRAM_TEST_CLIENT_STATUS")
            .unwrap()
            .parse()
            .unwrap(),
    );
}
