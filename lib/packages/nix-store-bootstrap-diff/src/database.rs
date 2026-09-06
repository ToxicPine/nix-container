use std::{collections::HashSet, path::Path};

use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags};

pub fn query_valid_paths(database_path: &Path, store_paths: &[String]) -> Result<HashSet<String>> {
    if store_paths.is_empty() {
        return Ok(HashSet::new());
    }

    let mut database = Connection::open_with_flags(database_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("failed to open Nix database {}", database_path.display()))?;
    database
        .execute_batch(
            "
            PRAGMA temp_store = MEMORY;
            CREATE TEMP TABLE RequestedPaths (
                path TEXT PRIMARY KEY
            ) WITHOUT ROWID;
            ",
        )
        .with_context(|| {
            format!(
                "failed to prepare store-path query for {}",
                database_path.display()
            )
        })?;

    let transaction = database.transaction().with_context(|| {
        format!(
            "failed to start store-path transaction for {}",
            database_path.display()
        )
    })?;
    {
        let mut insert = transaction
            .prepare("INSERT INTO RequestedPaths (path) VALUES (?)")
            .with_context(|| {
                format!(
                    "failed to prepare store-path insertion for {}",
                    database_path.display()
                )
            })?;
        for store_path in store_paths {
            insert.execute([store_path]).with_context(|| {
                format!(
                    "failed to add store path to query for {}",
                    database_path.display()
                )
            })?;
        }
    }
    transaction.commit().with_context(|| {
        format!(
            "failed to commit store-path query for {}",
            database_path.display()
        )
    })?;

    let mut statement = database
        .prepare(
            "
            -- Drive the query from the bounded request set. ValidPaths.path is
            -- unique in Nix's schema, so each requested path is one indexed lookup.
            SELECT requested.path
            FROM RequestedPaths AS requested
            WHERE EXISTS (
                SELECT 1
                FROM ValidPaths AS valid
                WHERE valid.path = requested.path
            )
            ",
        )
        .with_context(|| {
            format!(
                "failed to query valid paths from {}",
                database_path.display()
            )
        })?;
    let rows = statement.query_map([], |row| row.get(0)).with_context(|| {
        format!(
            "failed to execute valid-path query on {}",
            database_path.display()
        )
    })?;

    let mut valid_paths = HashSet::with_capacity(store_paths.len());
    for row in rows {
        valid_paths.insert(row.with_context(|| {
            format!("failed to read valid path from {}", database_path.display())
        })?);
    }
    Ok(valid_paths)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn database_with_paths(paths: &[String]) -> Result<NamedTempFile> {
        let file = NamedTempFile::new()?;
        let mut database = Connection::open(file.path())?;
        database.execute_batch(
            "
            CREATE TABLE ValidPaths (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                path TEXT UNIQUE NOT NULL
            );
            ",
        )?;
        let transaction = database.transaction()?;
        {
            let mut insert = transaction.prepare("INSERT INTO ValidPaths (path) VALUES (?)")?;
            for path in paths {
                insert.execute([path])?;
            }
        }
        transaction.commit()?;
        Ok(file)
    }

    #[test]
    fn query_is_limited_to_requested_paths() -> Result<()> {
        let requested_paths = vec![
            "/nix/store/00000000000000000000000000000000-first".to_owned(),
            "/nix/store/11111111111111111111111111111111-second".to_owned(),
            "/nix/store/22222222222222222222222222222222-third".to_owned(),
        ];
        let mut database_paths: Vec<_> = (0..1000)
            .map(|index| format!("/nix/store/{index:032x}-unrelated"))
            .collect();
        database_paths.push(requested_paths[1].clone());
        let database = database_with_paths(&database_paths)?;

        let valid_paths = query_valid_paths(database.path(), &requested_paths)?;

        assert_eq!(valid_paths, HashSet::from([requested_paths[1].clone()]));
        Ok(())
    }

    #[test]
    fn empty_query_does_not_open_database() -> Result<()> {
        let directory = tempfile::tempdir()?;

        let valid_paths = query_valid_paths(&directory.path().join("db.sqlite"), &[])?;

        assert!(valid_paths.is_empty());
        Ok(())
    }
}
