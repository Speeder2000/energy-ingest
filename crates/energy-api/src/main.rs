// SPDX-License-Identifier: MIT

//! Local API process: loopback/container network binding is configured
//! by deployment. Do not expose this service directly to the Internet.

use std::{env, net::SocketAddr};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = env::var("ENGY_DB_URL")?;
    let pool = sqlx::mysql::MySqlPoolOptions::new()
        .max_connections(5)
        .connect(&url)
        .await?;
    let address: SocketAddr = env::var("ENGY_API_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:8080".into())
        .parse()?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    let docs = env::var("ENGY_API_DEV_DOCS").as_deref() == Ok("1");
    if docs && !address.ip().is_loopback() {
        return Err("developer docs require a loopback listener".into());
    }
    // Interval resolution of stream and window responses when a client
    // does not request one: "native" (default) or "hour".
    let resolution = match env::var("ENGY_API_DEFAULT_RESOLUTION") {
        Ok(value) => energy_store::Resolution::parse(&value).ok_or(
            "ENGY_API_DEFAULT_RESOLUTION must be \"native\" or \"hour\"",
        )?,
        Err(_) => energy_store::Resolution::Native,
    };
    let app = if docs {
        energy_api::developer_router_with_resolution(pool, resolution)
    } else {
        energy_api::router_with_resolution(pool, resolution)
    };
    axum::serve(listener, app).await?;
    Ok(())
}
