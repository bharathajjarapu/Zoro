use std::{env, io::Write, process};

const MAX_OUTPUT: usize = 4 * 1024 * 1024;

fn main() {
    let mut args = env::args_os().skip(1);
    let Some(path) = args.next() else {
        process::exit(2);
    };
    if args.next().is_some() {
        process::exit(2);
    }

    match anydoc::to_markdown(path) {
        Ok(markdown) if markdown.len() <= MAX_OUTPUT => {
            if std::io::stdout().write_all(markdown.as_bytes()).is_err() {
                process::exit(1);
            }
        }
        Ok(_) => {
            eprintln!("anydoc: output exceeds 4 MiB");
            process::exit(1);
        }
        Err(error) => {
            eprintln!("anydoc: {error}");
            process::exit(if matches!(error, anydoc::ConvertError::NeedsOcr { .. }) {
                3
            } else {
                1
            });
        }
    }
}
