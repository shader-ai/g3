/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 G3-OSS developers.
 */

use g3_codec::ber::BerLengthEncoder;

const MAX_MESSAGE_ID: u8 = 0x7F;
const MIN_MESSAGE_ID: u8 = 1;

pub(crate) struct SimpleBindRequestEncoder {
    message_id: u8,
    bind_dn_length_encoder: BerLengthEncoder,
    password_length_encoder: BerLengthEncoder,
    request_length_encoder: BerLengthEncoder,
    message_length_encoder: BerLengthEncoder,
    request_buf: Vec<u8>,
}

impl Default for SimpleBindRequestEncoder {
    fn default() -> Self {
        SimpleBindRequestEncoder {
            message_id: MAX_MESSAGE_ID,
            bind_dn_length_encoder: Default::default(),
            password_length_encoder: Default::default(),
            request_length_encoder: Default::default(),
            message_length_encoder: Default::default(),
            request_buf: Vec::with_capacity(256),
        }
    }
}

impl SimpleBindRequestEncoder {
    pub(crate) fn reset(&mut self) {
        self.message_id = MAX_MESSAGE_ID;
    }

    pub(crate) fn message_id(&self) -> u32 {
        self.message_id as u32
    }

    pub(crate) fn encode(&mut self, bind_dn: &str, password: &str) -> &[u8] {
        self.message_id += 1;
        if self.message_id > MAX_MESSAGE_ID {
            self.message_id = MIN_MESSAGE_ID;
        }

        let bind_dn_len = bind_dn.len();
        let bind_dn_length_bytes = self.bind_dn_length_encoder.encode(bind_dn_len);
        let bind_dn_encoded_len = 1 + bind_dn_length_bytes.len() + bind_dn_len;

        let password_len = password.len();
        let password_length_bytes = self.password_length_encoder.encode(password_len);
        let password_encoded_len = 1 + password_length_bytes.len() + password_len;

        let request_len = 3 + bind_dn_encoded_len + password_encoded_len;
        let request_length_bytes = self.request_length_encoder.encode(request_len);
        let request_encoded_len = 1 + request_length_bytes.len() + request_len;

        let message_len = 3 + request_encoded_len;
        let message_length_bytes = self.message_length_encoder.encode(message_len);
        let message_encoded_len = 1 + message_length_bytes.len() + message_len;

        self.request_buf.clear();
        self.request_buf.reserve(message_encoded_len);

        // Begin the LDAPMessage sequence
        self.request_buf.push(0x30);
        self.request_buf.extend_from_slice(message_length_bytes);

        // The message ID
        self.request_buf.push(0x02);
        self.request_buf.push(0x01);
        self.request_buf.push(self.message_id); // the message is always <= 0x7F

        // Begin the bind request protocol op
        self.request_buf.push(0x60);
        self.request_buf.extend_from_slice(request_length_bytes);

        // The LDAP protocol version (integer value 3)
        self.request_buf.extend_from_slice(&[0x02, 0x01, 0x03]);

        // The bind DN
        self.request_buf.push(0x04);
        self.request_buf.extend_from_slice(bind_dn_length_bytes);
        self.request_buf.extend_from_slice(bind_dn.as_bytes());

        // The password
        self.request_buf.push(0x80);
        self.request_buf.extend_from_slice(password_length_bytes);
        self.request_buf.extend_from_slice(password.as_bytes());

        &self.request_buf
    }

    pub(crate) fn unbind_sequence(&mut self) -> [u8; 7] {
        self.message_id += 1;
        if self.message_id > MAX_MESSAGE_ID {
            self.message_id = MIN_MESSAGE_ID;
        }

        [0x30, 0x05, 0x02, 0x01, self.message_id, 0x42, 0x00]
    }
}

/// Encode a BER definite length into a Vec<u8>.
fn push_ber_length(buf: &mut Vec<u8>, len: usize) {
    if len <= 0x7f {
        buf.push(len as u8);
    } else if len <= 0xff {
        buf.push(0x81);
        buf.push(len as u8);
    } else {
        buf.push(0x82);
        buf.push((len >> 8) as u8);
        buf.push(len as u8);
    }
}

/// Encodes an LDAP SearchRequest (base scope, filter `(objectClass=*)`)
/// to fetch the listed attributes from `dn`.
pub(crate) struct SearchRequestEncoder {
    message_id: u8,
    buf: Vec<u8>,
}

impl SearchRequestEncoder {
    pub(crate) fn new(message_id: u8) -> Self {
        SearchRequestEncoder {
            message_id,
            buf: Vec::with_capacity(512),
        }
    }

    pub(crate) fn encode(&mut self, dn: &str, attrs: &[String]) -> &[u8] {
        // Build attributes list (SEQUENCE OF LDAPString)
        let mut attrs_inner: Vec<u8> = Vec::new();
        for attr in attrs {
            attrs_inner.push(0x04); // octet string
            push_ber_length(&mut attrs_inner, attr.len());
            attrs_inner.extend_from_slice(attr.as_bytes());
        }
        let mut attrs_seq: Vec<u8> = Vec::new();
        attrs_seq.push(0x30); // SEQUENCE
        push_ber_length(&mut attrs_seq, attrs_inner.len());
        attrs_seq.extend_from_slice(&attrs_inner);

        // filter: (objectClass=*) — present filter [7] = 0x87
        let filter: &[u8] = &[
            0x87, 0x0b, b'o', b'b', b'j', b'e', b'c', b't', b'C', b'l', b'a', b's', b's',
        ];

        // Build SearchRequest body
        let mut req_body: Vec<u8> = Vec::new();
        // baseObject LDAPDN (octet string)
        req_body.push(0x04);
        push_ber_length(&mut req_body, dn.len());
        req_body.extend_from_slice(dn.as_bytes());
        // scope: baseObject (0)
        req_body.extend_from_slice(&[0x0a, 0x01, 0x00]);
        // derefAliases: neverDerefAliases (0)
        req_body.extend_from_slice(&[0x0a, 0x01, 0x00]);
        // sizeLimit: 1
        req_body.extend_from_slice(&[0x02, 0x01, 0x01]);
        // timeLimit: 5
        req_body.extend_from_slice(&[0x02, 0x01, 0x05]);
        // typesOnly: false
        req_body.extend_from_slice(&[0x01, 0x01, 0x00]);
        // filter
        req_body.extend_from_slice(filter);
        // attributes
        req_body.extend_from_slice(&attrs_seq);

        // SearchRequest: [APPLICATION 3] constructed = 0x63
        let mut proto_op: Vec<u8> = Vec::new();
        proto_op.push(0x63);
        push_ber_length(&mut proto_op, req_body.len());
        proto_op.extend_from_slice(&req_body);

        // LDAPMessage: SEQUENCE { messageID, protocolOp }
        let msg_content_len = 3 + proto_op.len(); // 3 bytes for messageID
        self.buf.clear();
        self.buf.push(0x30); // SEQUENCE
        push_ber_length(&mut self.buf, msg_content_len);
        self.buf.extend_from_slice(&[0x02, 0x01, self.message_id]);
        self.buf.extend_from_slice(&proto_op);
        &self.buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode() {
        let mut encoder = SimpleBindRequestEncoder::default();
        let bind_dn = "uid=jdoe,ou=People,dc=example,dc=com";

        let request = encoder.encode(bind_dn, "secret123");
        assert_eq!(
            request,
            [
                0x30, 0x39, // Begin the LDAPMessage sequence
                0x02, 0x01, 0x01, // The message ID (integer value 1)
                0x60, 0x34, // Begin the bind request protocol op
                0x02, 0x01, 0x03, // The LDAP protocol version (integer value 3)
                0x04, 0x24, b'u', b'i', b'd', b'=', b'j', b'd', b'o', b'e', b',', b'o', b'u', b'=',
                b'P', b'e', b'o', b'p', b'l', b'e', b',', b'd', b'c', b'=', b'e', b'x', b'a', b'm',
                b'p', b'l', b'e', b',', b'd', b'c', b'=', b'c', b'o', b'm', // base dn
                0x80, 0x09, b's', b'e', b'c', b'r', b'e', b't', b'1', b'2', b'3', // password
            ]
        );
    }
}
