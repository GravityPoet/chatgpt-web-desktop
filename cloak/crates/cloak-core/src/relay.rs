use base64::Engine;
use rustls::{ClientConfig, RootCertStore};
use rustls_pki_types::ServerName;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Builder;
use tokio::time;
use tokio_rustls::{client::TlsStream, TlsConnector};
use url::Url;

pub fn serve_forever<F>(upstream_url: &str, on_ready: F) -> Result<(), String>
where
    F: FnOnce(u16) -> Result<(), String>,
{
    let upstream = Upstream::parse(upstream_url)?;
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).map_err(|err| err.to_string())?;
    listener.set_nonblocking(true).map_err(|err| err.to_string())?;
    let port = listener.local_addr().map_err(|err| err.to_string())?.port();
    on_ready(port)?;
    run_listener(listener, upstream)
}

fn run_listener(listener: std::net::TcpListener, upstream: Upstream) -> Result<(), String> {
    let runtime = Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .thread_name("cloak-relay-io")
        .build()
        .map_err(|err| err.to_string())?;

    runtime.block_on(async move {
        let listener = TcpListener::from_std(listener).map_err(|err| err.to_string())?;
        loop {
            let (client, _) = listener.accept().await.map_err(|err| err.to_string())?;
            let upstream = upstream.clone();
            tokio::spawn(async move {
                let _ = handle_client(client, &upstream).await;
            });
        }
    })
}

#[derive(Clone, Debug)]
struct Upstream {
    kind: UpstreamKind,
    host: String,
    port: u16,
    user: Option<String>,
    password: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum UpstreamKind {
    Socks5,
    Http,
    Https,
}

impl Upstream {
    fn parse(raw: &str) -> Result<Self, String> {
        let url = Url::parse(raw).map_err(|err| err.to_string())?;
        let kind = match url.scheme() {
            "socks5" => UpstreamKind::Socks5,
            "http" => UpstreamKind::Http,
            "https" => UpstreamKind::Https,
            other => return Err(format!("unsupported upstream scheme: {other}")),
        };
        let host = url
            .host_str()
            .ok_or_else(|| "upstream needs host".to_string())?
            .to_string();
        let port = url.port().ok_or_else(|| "upstream needs port".to_string())?;
        let user = if url.username().is_empty() {
            None
        } else {
            Some(percent_decode(url.username()))
        };
        let password = url.password().map(percent_decode);
        Ok(Self {
            kind,
            host,
            port,
            user,
            password,
        })
    }
}

enum RemoteStream {
    Tcp(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
}

impl AsyncRead for RemoteStream {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            RemoteStream::Tcp(stream) => Pin::new(stream).poll_read(cx, buf),
            RemoteStream::Tls(stream) => Pin::new(stream.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for RemoteStream {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        match self.get_mut() {
            RemoteStream::Tcp(stream) => Pin::new(stream).poll_write(cx, buf),
            RemoteStream::Tls(stream) => Pin::new(stream.as_mut()).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            RemoteStream::Tcp(stream) => Pin::new(stream).poll_flush(cx),
            RemoteStream::Tls(stream) => Pin::new(stream.as_mut()).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            RemoteStream::Tcp(stream) => Pin::new(stream).poll_shutdown(cx),
            RemoteStream::Tls(stream) => Pin::new(stream.as_mut()).poll_shutdown(cx),
        }
    }
}

async fn handle_client(mut client: TcpStream, upstream: &Upstream) -> Result<(), String> {
    let mut greeting = [0u8; 2];
    client.read_exact(&mut greeting).await.map_err(|err| err.to_string())?;
    if greeting[0] != 0x05 {
        return Err("client is not SOCKS5".to_string());
    }
    let mut methods = vec![0u8; greeting[1] as usize];
    client.read_exact(&mut methods).await.map_err(|err| err.to_string())?;
    client.write_all(&[0x05, 0x00]).await.map_err(|err| err.to_string())?;

    let mut head = [0u8; 4];
    client.read_exact(&mut head).await.map_err(|err| err.to_string())?;
    if head[1] != 0x01 {
        let _ = client.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await;
        return Err("only CONNECT is supported".to_string());
    }

    let host = match head[3] {
        0x01 => {
            let mut ip = [0u8; 4];
            client.read_exact(&mut ip).await.map_err(|err| err.to_string())?;
            std::net::Ipv4Addr::from(ip).to_string()
        }
        0x03 => {
            let mut len = [0u8; 1];
            client.read_exact(&mut len).await.map_err(|err| err.to_string())?;
            let mut host = vec![0u8; len[0] as usize];
            client.read_exact(&mut host).await.map_err(|err| err.to_string())?;
            String::from_utf8(host).map_err(|err| err.to_string())?
        }
        0x04 => {
            let mut ip = [0u8; 16];
            client.read_exact(&mut ip).await.map_err(|err| err.to_string())?;
            std::net::Ipv6Addr::from(ip).to_string()
        }
        _ => return Err("unsupported address type".to_string()),
    };
    let mut port_bytes = [0u8; 2];
    client.read_exact(&mut port_bytes).await.map_err(|err| err.to_string())?;
    let port = u16::from_be_bytes(port_bytes);

    let mut remote = match dial_upstream(upstream, &host, port).await {
        Ok(remote) => remote,
        Err(err) => {
            let _ = client.write_all(&[0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await;
            return Err(err);
        }
    };
    client
        .write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await
        .map_err(|err| err.to_string())?;
    tokio::io::copy_bidirectional(&mut client, &mut remote)
        .await
        .map(|_| ())
        .map_err(|err| err.to_string())
}

async fn dial_upstream(upstream: &Upstream, host: &str, port: u16) -> Result<RemoteStream, String> {
    match upstream.kind {
        UpstreamKind::Socks5 => dial_socks5(upstream, host, port).await,
        UpstreamKind::Http => dial_http(upstream, host, port).await,
        UpstreamKind::Https => dial_https(upstream, host, port).await,
    }
}

async fn dial_socks5(upstream: &Upstream, host: &str, port: u16) -> Result<RemoteStream, String> {
    let mut stream = connect_tcp(&upstream.host, upstream.port).await?;
    if upstream.user.is_some() {
        stream.write_all(&[0x05, 0x01, 0x02]).await.map_err(|err| err.to_string())?;
    } else {
        stream.write_all(&[0x05, 0x01, 0x00]).await.map_err(|err| err.to_string())?;
    }
    let mut method = [0u8; 2];
    stream.read_exact(&mut method).await.map_err(|err| err.to_string())?;
    if method[0] != 0x05 {
        return Err("upstream is not SOCKS5".to_string());
    }
    if method[1] == 0x02 {
        let user = upstream.user.as_deref().unwrap_or("").as_bytes();
        let pass = upstream.password.as_deref().unwrap_or("").as_bytes();
        if user.len() > 255 || pass.len() > 255 {
            return Err("upstream credentials too long".to_string());
        }
        let mut auth = vec![0x01, user.len() as u8];
        auth.extend_from_slice(user);
        auth.push(pass.len() as u8);
        auth.extend_from_slice(pass);
        stream.write_all(&auth).await.map_err(|err| err.to_string())?;
        let mut status = [0u8; 2];
        stream.read_exact(&mut status).await.map_err(|err| err.to_string())?;
        if status[1] != 0x00 {
            return Err("upstream auth rejected".to_string());
        }
    } else if method[1] != 0x00 {
        return Err(format!("upstream chose unsupported auth method: {:#x}", method[1]));
    }

    let host_bytes = host.as_bytes();
    if host_bytes.len() > 255 {
        return Err("hostname too long".to_string());
    }
    let mut req = vec![0x05, 0x01, 0x00, 0x03, host_bytes.len() as u8];
    req.extend_from_slice(host_bytes);
    req.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&req).await.map_err(|err| err.to_string())?;

    let mut reply = [0u8; 4];
    stream.read_exact(&mut reply).await.map_err(|err| err.to_string())?;
    if reply[1] != 0x00 {
        return Err(format!("upstream CONNECT failed: {:#x}", reply[1]));
    }
    match reply[3] {
        0x01 => drain(&mut stream, 4).await?,
        0x03 => {
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await.map_err(|err| err.to_string())?;
            drain(&mut stream, len[0] as usize).await?;
        }
        0x04 => drain(&mut stream, 16).await?,
        _ => return Err("bad upstream reply address type".to_string()),
    }
    drain(&mut stream, 2).await?;
    Ok(RemoteStream::Tcp(stream))
}

async fn dial_http(upstream: &Upstream, host: &str, port: u16) -> Result<RemoteStream, String> {
    let mut stream = connect_tcp(&upstream.host, upstream.port).await?;
    write_connect_request(&mut stream, upstream, host, port).await?;
    read_http_connect_response(&mut stream).await?;
    Ok(RemoteStream::Tcp(stream))
}

async fn dial_https(upstream: &Upstream, host: &str, port: u16) -> Result<RemoteStream, String> {
    let tcp = connect_tcp(&upstream.host, upstream.port).await?;
    let root_store = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let config = ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();
    let connector = TlsConnector::from(Arc::new(config));
    let server_name = ServerName::try_from(upstream.host.clone()).map_err(|err| err.to_string())?;
    let mut stream = time::timeout(Duration::from_secs(20), connector.connect(server_name, tcp))
        .await
        .map_err(|_| "TLS upstream connect timed out".to_string())?
        .map_err(|err| err.to_string())?;
    write_connect_request(&mut stream, upstream, host, port).await?;
    read_http_connect_response(&mut stream).await?;
    Ok(RemoteStream::Tls(Box::new(stream)))
}

async fn connect_tcp(host: &str, port: u16) -> Result<TcpStream, String> {
    time::timeout(Duration::from_secs(20), TcpStream::connect((host, port)))
        .await
        .map_err(|_| format!("connect to {host}:{port} timed out"))?
        .map_err(|err| err.to_string())
}

async fn write_connect_request<S>(stream: &mut S, upstream: &Upstream, host: &str, port: u16) -> Result<(), String>
where
    S: AsyncWrite + Unpin,
{
    let mut req = format!("CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n");
    if let Some(user) = upstream.user.as_deref() {
        let token = base64::engine::general_purpose::STANDARD.encode(format!(
            "{}:{}",
            user,
            upstream.password.as_deref().unwrap_or("")
        ));
        req.push_str(&format!("Proxy-Authorization: Basic {token}\r\n"));
    }
    req.push_str("\r\n");
    stream.write_all(req.as_bytes()).await.map_err(|err| err.to_string())
}

async fn read_http_connect_response<S>(stream: &mut S) -> Result<(), String>
where
    S: AsyncRead + Unpin,
{
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).await.map_err(|err| err.to_string())?;
        buf.push(byte[0]);
        if buf.len() > 16 * 1024 {
            return Err("HTTP proxy response too large".to_string());
        }
    }
    let status = String::from_utf8_lossy(&buf);
    if !status.starts_with("HTTP/1.1 200") && !status.starts_with("HTTP/1.0 200") {
        return Err(format!("HTTP proxy CONNECT failed: {}", status.lines().next().unwrap_or("")));
    }
    Ok(())
}

async fn drain<S>(stream: &mut S, len: usize) -> Result<(), String>
where
    S: AsyncRead + Unpin,
{
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf).await.map_err(|err| err.to_string())?;
    Ok(())
}

fn percent_decode(value: &str) -> String {
    percent_encoding::percent_decode_str(value)
        .decode_utf8_lossy()
        .to_string()
}
