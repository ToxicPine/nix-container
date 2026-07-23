mod database;

use std::{
    collections::HashSet,
    env,
    ffi::OsString,
    fs::File,
    io::{BufRead, BufReader, BufWriter, Write},
    path::{Path, PathBuf},
    process,
};

use anyhow::{bail, Context, Result};
use nix_daemon::{nix::DaemonStore, Progress, Store};

enum LowerStoreMode {
    Filesystem,
    Socket,
}

impl LowerStoreMode {
    fn parse(value: &OsString) -> Result<Self> {
        match value.to_str() {
            Some("filesystem") => Ok(Self::Filesystem),
            Some("socket") => Ok(Self::Socket),
            _ => bail!("lower store must be \"filesystem\" or \"socket\""),
        }
    }
}

struct Arguments {
    lower_store_mode: LowerStoreMode,
    image_closure_manifest_path: PathBuf,
    upper_database_path: PathBuf,
    lower_metadata_path: PathBuf,
}

impl Arguments {
    fn parse() -> Result<Self> {
        let arguments: Vec<_> = env::args_os().collect();
        let [_, lower_store_mode, image_closure_manifest_path, upper_database_path, lower_metadata_path] =
            arguments.as_slice()
        else {
            bail!(
                "usage: nix-store-bootstrap-diff \
                 <filesystem|socket> <image-closure-manifest> \
                 <upper-db> <lower-db-or-socket>"
            );
        };

        Ok(Self {
            lower_store_mode: LowerStoreMode::parse(lower_store_mode)?,
            image_closure_manifest_path: image_closure_manifest_path.into(),
            upper_database_path: upper_database_path.into(),
            lower_metadata_path: lower_metadata_path.into(),
        })
    }
}

fn read_image_closure_manifest(path: &Path) -> Result<Vec<String>> {
    let file = File::open(path)
        .with_context(|| format!("failed to open image closure manifest {}", path.display()))?;
    let mut image_closure_paths = Vec::new();
    for line in BufReader::new(file).lines() {
        let store_path = line
            .with_context(|| format!("failed to read image closure manifest {}", path.display()))?;
        if !store_path.is_empty() {
            image_closure_paths.push(store_path);
        }
    }
    Ok(image_closure_paths)
}

fn query_valid_paths_from_upper_database(
    database_path: &Path,
    store_paths: &[String],
) -> Result<HashSet<String>> {
    if database_path.exists() {
        database::query_valid_paths(database_path, store_paths)
    } else {
        Ok(HashSet::new())
    }
}

async fn query_valid_paths_from_daemon(
    socket_path: &Path,
    store_paths: &[String],
) -> Result<HashSet<String>> {
    if store_paths.is_empty() {
        return Ok(HashSet::new());
    }

    let mut store = DaemonStore::builder()
        .connect_unix(socket_path)
        .await
        .with_context(|| {
            format!(
                "failed to connect to lower store at {}",
                socket_path.display()
            )
        })?;
    let valid_paths = store
        .query_valid_paths(store_paths, false)
        .result()
        .await
        .with_context(|| {
            format!(
                "failed to query valid paths from lower store at {}",
                socket_path.display()
            )
        })?;
    Ok(valid_paths.into_iter().collect())
}

fn select_paths_to_copy<'a>(
    paths_requiring_lower_lookup: &'a [String],
    lower_valid_paths: &'a HashSet<String>,
) -> impl Iterator<Item = &'a String> {
    paths_requiring_lower_lookup
        .iter()
        .filter(|path| !lower_valid_paths.contains(*path))
}

async fn run() -> Result<()> {
    let arguments = Arguments::parse()?;
    let image_store_paths = read_image_closure_manifest(&arguments.image_closure_manifest_path)?;
    let upper_valid_paths =
        query_valid_paths_from_upper_database(&arguments.upper_database_path, &image_store_paths)?;
    let paths_requiring_lower_lookup: Vec<_> = image_store_paths
        .iter()
        .filter(|path| !upper_valid_paths.contains(*path))
        .cloned()
        .collect();

    let lower_valid_paths = match arguments.lower_store_mode {
        LowerStoreMode::Filesystem => database::query_valid_paths(
            &arguments.lower_metadata_path,
            &paths_requiring_lower_lookup,
        )?,
        LowerStoreMode::Socket => {
            query_valid_paths_from_daemon(
                &arguments.lower_metadata_path,
                &paths_requiring_lower_lookup,
            )
            .await?
        }
    };

    let mut output = BufWriter::new(std::io::stdout().lock());
    for store_path_to_copy in
        select_paths_to_copy(&paths_requiring_lower_lookup, &lower_valid_paths)
    {
        writeln!(output, "{store_path_to_copy}")?;
    }
    output.flush()?;
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("nix-store-bootstrap-diff: {error:#}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_upper_database_is_empty() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let image_store_paths =
            vec!["/nix/store/00000000000000000000000000000000-first".to_owned()];

        let valid_paths = query_valid_paths_from_upper_database(
            &directory.path().join("db.sqlite"),
            &image_store_paths,
        )?;

        assert!(valid_paths.is_empty());
        Ok(())
    }

    #[test]
    fn paths_to_copy_preserve_image_order() {
        let paths_requiring_lower_lookup = vec![
            "/nix/store/00000000000000000000000000000000-first".to_owned(),
            "/nix/store/11111111111111111111111111111111-second".to_owned(),
            "/nix/store/22222222222222222222222222222222-third".to_owned(),
            "/nix/store/33333333333333333333333333333333-fourth".to_owned(),
        ];
        let lower_valid_paths = HashSet::from([
            paths_requiring_lower_lookup[0].clone(),
            paths_requiring_lower_lookup[2].clone(),
        ]);

        let paths_to_copy: Vec<_> =
            select_paths_to_copy(&paths_requiring_lower_lookup, &lower_valid_paths)
                .cloned()
                .collect();

        assert_eq!(
            paths_to_copy,
            vec![
                paths_requiring_lower_lookup[1].clone(),
                paths_requiring_lower_lookup[3].clone()
            ]
        );
    }
}
