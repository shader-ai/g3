/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 G3-OSS developers.
 */

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::anyhow;
use kanal::AsyncReceiver;
use log::{debug, warn};
use tokio::io::{AsyncRead, AsyncWrite};

use g3_codec::ldap::{LdapResult, LdapSequence};
use g3_io_ext::openssl::MaybeSslStream;
use g3_io_ext::{AsyncStream, LimitedWriteExt};

use super::{LdapAuthRequest, LdapConnector};
use crate::auth::group::ldap::{LdapMessageReceiver, SearchRequestEncoder, SimpleBindRequestEncoder};
use crate::config::auth::LdapUserGroupConfig;

pub(super) struct LdapAuthTask {
    config: Arc<LdapUserGroupConfig>,
    connector: Arc<LdapConnector>,
    quit: bool,
    pending_request: Option<LdapAuthRequest>,
    request_encoder: SimpleBindRequestEncoder,
    search_encoder: Option<SearchRequestEncoder>,
}

impl LdapAuthTask {
    pub(super) fn new(config: Arc<LdapUserGroupConfig>, connector: Arc<LdapConnector>) -> Self {
        let search_encoder = if config.extra_ldap_attrs.is_empty() {
            None
        } else {
            Some(SearchRequestEncoder::new(0x10))
        };
        LdapAuthTask {
            config,
            connector,
            quit: false,
            pending_request: None,
            request_encoder: SimpleBindRequestEncoder::default(),
            search_encoder,
        }
    }

    pub(super) async fn run(
        mut self,
        receiver: AsyncReceiver<LdapAuthRequest>,
    ) -> anyhow::Result<()> {
        loop {
            let r = match self.connector.connect().await? {
                MaybeSslStream::Plain(stream) => self.run_with_stream(stream, &receiver).await,
                MaybeSslStream::Ssl(stream) => self.run_with_stream(stream, &receiver).await,
            };
            if let Err(e) = r {
                warn!("connection closed with error: {e}");
            }

            if let Some(mut request) = self.pending_request
                && request.retry
            {
                request.retry = false;
                self.pending_request = Some(request);
                continue;
            }

            return Ok(());
        }
    }

    async fn run_with_stream<S>(
        &mut self,
        stream: S,
        req_receiver: &AsyncReceiver<LdapAuthRequest>,
    ) -> anyhow::Result<()>
    where
        S: AsyncStream,
        S::R: AsyncRead + Unpin,
        S::W: AsyncWrite + Unpin,
    {
        self.request_encoder.reset();
        let (mut reader, mut writer) = stream.into_split();
        let mut ldap_rsp_receiver = LdapMessageReceiver::new(self.config.max_message_size);

        loop {
            if let Some(r) = self.pending_request.take() {
                let message_id = match self.send_simple_bind_request(&mut writer, &r).await {
                    Ok(id) => id,
                    Err(e) => {
                        self.pending_request = Some(r);
                        return Err(anyhow!("send simple bind request error: {e}"));
                    }
                };

                match tokio::time::timeout(
                    self.config.response_timeout,
                    ldap_rsp_receiver.recv(&mut reader),
                )
                .await
                {
                    Ok(Ok(message)) => {
                        if message.id() == 0 {
                            self.pending_request = Some(r);
                            let reconnect = self
                                .handle_unsolicited_notification(message.payload())
                                .map_err(|e| anyhow!("invalid unsolicited notification: {e}"))?;
                            if reconnect {
                                return Ok(());
                            } else {
                                continue;
                            }
                        } else if message.id() != message_id {
                            self.pending_request = Some(r);
                            debug!("unexpected response for message {}", message.id());
                            continue;
                        } else {
                            let bind_dn = format!(
                                "{}={},{}",
                                self.config.username_attribute, r.username, self.config.base_dn
                            );
                            // Copy payload out so message (and its borrow of ldap_rsp_receiver) is dropped
                            let payload = message.payload().to_vec();
                            drop(message);
                            self.handle_response(
                                &payload,
                                r,
                                &mut writer,
                                &mut reader,
                                &mut ldap_rsp_receiver,
                                &bind_dn,
                            )
                            .await
                            .map_err(|e| anyhow!("invalid response: {e}"))?;
                        }
                    }
                    Ok(Err(e)) => {
                        self.pending_request = Some(r);
                        return Err(anyhow!("recv ldap response message error: {e}"));
                    }
                    Err(_) => {
                        let _ = r.result_sender.send(None);
                        return Err(anyhow!("recv ldap response message timed out"));
                    }
                }
            }

            let timeout = tokio::time::sleep(self.config.connection_pool.idle_timeout());
            tokio::select! {
                biased;

                r = req_receiver.recv() => {
                    match r {
                        Ok(r) => self.pending_request = Some(r),
                        Err(_) => {
                            self.quit = true;
                            return Ok(());
                        }
                    }
                }
                _ = timeout => {
                    return self.send_unbind(&mut writer).await;
                }
                r = ldap_rsp_receiver.recv(&mut reader) => {
                    // detect the close of ldap server
                    match r {
                        Ok(message) => {
                            if message.id() != 0 {
                                debug!("unexpected response received for message {}", message.id());
                            } else {
                                let reconnect = self
                                    .handle_unsolicited_notification(message.payload())
                                    .map_err(|e| anyhow!("invalid unsolicited notification: {e}"))?;
                                if reconnect {
                                    return Ok(());
                                } else {
                                    continue;
                                }
                            }
                        }
                        Err(e) => {
                            return Err(anyhow!("ldap connection closed with error {e}"));
                        }
                    }
                }
            }
        }
    }

    async fn send_simple_bind_request<W>(
        &mut self,
        writer: &mut W,
        r: &LdapAuthRequest,
    ) -> anyhow::Result<u32>
    where
        W: AsyncWrite + Unpin,
    {
        let bind_dn = format!(
            "{}={},{}",
            self.config.username_attribute, r.username, self.config.base_dn
        );
        let request_msg = self.request_encoder.encode(&bind_dn, &r.password);
        writer
            .write_all_flush(request_msg)
            .await
            .map_err(|e| anyhow!("failed to write bind request: {e}"))?;
        Ok(self.request_encoder.message_id())
    }

    async fn send_unbind<W>(&mut self, writer: &mut W) -> anyhow::Result<()>
    where
        W: AsyncWrite + Unpin,
    {
        let unbind_message = self.request_encoder.unbind_sequence();
        writer
            .write_all_flush(&unbind_message)
            .await
            .map_err(|e| anyhow!("failed to write unbind request: {e}"))
    }

    fn handle_unsolicited_notification(&self, op_data: &[u8]) -> anyhow::Result<bool> {
        let rsp_sequence = LdapSequence::parse_extended_response(op_data)?;
        let data = rsp_sequence.data();
        let result = LdapResult::parse(data)?;
        let left = &data[result.encoded_len()..];
        let oid = LdapSequence::parse_extended_response_oid(left)?;
        if oid.data() == b"1.3.6.1.4.1.1466.20036" {
            // The notice of disconnection unsolicited notification OID
            Ok(true)
        } else {
            // TODO log other OID
            Ok(false)
        }
    }

    async fn handle_response<W, R>(
        &mut self,
        op_data: &[u8],
        r: LdapAuthRequest,
        writer: &mut W,
        reader: &mut R,
        ldap_rsp_receiver: &mut LdapMessageReceiver,
        bind_dn: &str,
    ) -> anyhow::Result<()>
    where
        W: AsyncWrite + Unpin,
        R: AsyncRead + Unpin,
    {
        let rsp_sequence = LdapSequence::parse_bind_response(op_data)?;
        let data = rsp_sequence.data();
        let result = LdapResult::parse(data)?;
        if result.is_success() {
            let attrs = if let Some(ref mut enc) = self.search_encoder {
                let search_msg = enc.encode(bind_dn, &self.config.extra_ldap_attrs);
                if writer.write_all_flush(search_msg).await.is_ok() {
                    match tokio::time::timeout(
                        self.config.response_timeout,
                        Self::recv_search_attrs(ldap_rsp_receiver, reader, &self.config.extra_ldap_attrs),
                    )
                    .await
                    {
                        Ok(Ok(attrs)) => attrs,
                        _ => HashMap::new(),
                    }
                } else {
                    HashMap::new()
                }
            } else {
                HashMap::new()
            };
            let _ = r.result_sender.send(Some((r.username, r.password, attrs)));
        } else {
            let _ = r.result_sender.send(None);
        }
        Ok(())
    }

    /// Drain search result messages until SearchResultDone, collecting attribute values.
    async fn recv_search_attrs<R>(
        ldap_rsp_receiver: &mut LdapMessageReceiver,
        reader: &mut R,
        requested_attrs: &[String],
    ) -> anyhow::Result<HashMap<String, String>>
    where
        R: AsyncRead + Unpin,
    {
        let mut attrs: HashMap<String, String> = HashMap::new();
        loop {
            let message = ldap_rsp_receiver.recv(reader).await?;
            let payload = message.payload();
            if payload.is_empty() {
                break;
            }
            if LdapSequence::parse_search_result_done(payload).is_ok() {
                break;
            }
            if let Ok(entry_seq) = LdapSequence::parse_search_result_entry(payload) {
                let entry_data = entry_seq.data();
                // Skip the objectName LDAPDN (octet string)
                if let Ok(dn_seq) = LdapSequence::parse_octet_string(entry_data) {
                    let offset = dn_seq.encoded_len();
                    // Parse partial attribute list (SEQUENCE OF)
                    if let Ok(attr_list) = LdapSequence::parse_sequence(&entry_data[offset..]) {
                        let mut list_data = attr_list.data();
                        while !list_data.is_empty() {
                            // Each PartialAttribute is a SEQUENCE { type, vals }
                            if let Ok(partial) = LdapSequence::parse_sequence(list_data) {
                                let partial_data = partial.data();
                                if let Ok(attr_type) = LdapSequence::parse_octet_string(partial_data) {
                                    let attr_name = std::str::from_utf8(attr_type.data())
                                        .unwrap_or("")
                                        .to_string();
                                    let val_offset = attr_type.encoded_len();
                                    if let Ok(val_set) = LdapSequence::parse_set(&partial_data[val_offset..]) {
                                        let val_data = val_set.data();
                                        if let Ok(val_str) = LdapSequence::parse_octet_string(val_data) {
                                            if let Ok(s) = std::str::from_utf8(val_str.data()) {
                                                // Only keep attrs we asked for, map by lowercased name
                                                let lower = attr_name.to_lowercase();
                                                if requested_attrs.iter().any(|a| a.to_lowercase() == lower) {
                                                    attrs.insert(lower, s.to_string());
                                                }
                                            }
                                        }
                                    }
                                }
                                list_data = &list_data[partial.encoded_len()..];
                            } else {
                                break;
                            }
                        }
                    }
                }
            }
        }
        Ok(attrs)
    }
}
