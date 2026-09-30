use std::io::{self, Read};

fn main() {
    let mut input = io::stdin().lock();
    // One hello and the initial 5x5x3 chunk view. Drain initialization before
    // exiting, just as closing a newly loaded window would do.
    for _ in 0..76 {
        let mut prefix = [0; 4];
        input.read_exact(&mut prefix).unwrap();
        let mut bytes = vec![0; u32::from_be_bytes(prefix) as usize];
        input.read_exact(&mut bytes).unwrap();
    }
    std::process::exit(
        std::env::var("WYRAM_TEST_CLIENT_STATUS")
            .unwrap()
            .parse()
            .unwrap(),
    );
}
