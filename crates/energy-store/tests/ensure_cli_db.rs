// SPDX-License-Identifier: MIT

//! Idempotent utility and meter registration used by unattended startup.
//! Requires ENGY_T_DB_URL and an isolated test MariaDB database.

use sqlx::{MySql, Pool};
use std::process::Command;

fn admin(url: &str, args: &[&str]) -> (bool, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_energy-store-admin"))
        .args(args)
        .env("ENGY_DB_URL", url)
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    (output.status.success(), text)
}

fn id_of(text: &str) -> u64 {
    text.trim().rsplit("id=").next().unwrap().parse().unwrap()
}

#[tokio::test]
async fn ensure_commands_are_idempotent() {
    let url =
        std::env::var("ENGY_T_DB_URL").expect("ENGY_T_DB_URL is required");
    let pool = Pool::<MySql>::connect(&url).await.unwrap();
    energy_store::migrate(&pool).await.unwrap();

    let unique = format!(
        "ensure-test-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );

    let (ok, first) = admin(&url, &["custodian", "ensure", &unique]);
    assert!(ok);
    assert!(first.starts_with("Custodian created: id="));
    let (ok, second) = admin(&url, &["custodian", "ensure", &unique]);
    assert!(ok);
    assert!(second.starts_with("Custodian already exists: id="));
    let custodian = id_of(&first);
    assert_eq!(custodian, id_of(&second));

    let custodian_arg = custodian.to_string();
    let meter_args = ["meter", "ensure", &custodian_arg, "1", "Electric"];
    let (ok, created) = admin(&url, &meter_args);
    assert!(ok);
    assert!(created.starts_with("Meter profile created: id="));
    let (ok, repeated) = admin(&url, &meter_args);
    assert!(ok);
    assert!(repeated.starts_with("Meter profile already exists: id="));
    let meter = id_of(&created);
    assert_eq!(meter, id_of(&repeated));

    // Reusing a name for another commodity must not return that meter.
    let (ok, _) =
        admin(&url, &["meter", "ensure", &custodian_arg, "7", "Electric"]);
    assert!(!ok);

    let count: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM physical_meter WHERE data_custodian_id = ?",
    )
    .bind(custodian)
    .fetch_one(&pool)
    .await
    .unwrap();

    sqlx::query("DELETE FROM physical_meter WHERE id = ?")
        .bind(meter)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM data_custodian WHERE id = ?")
        .bind(custodian)
        .execute(&pool)
        .await
        .unwrap();

    assert_eq!(count.0, 1);
}
