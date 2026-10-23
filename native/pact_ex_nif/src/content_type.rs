//! Tells the Elixir side how `pactffi_with_body` will treat a content type.

use pact_models::content_types::ContentType;
use rustler::Atom;

mod atoms {
    rustler::atoms! {
        xml,
        form,
        json,
        other,
        invalid,
    }
}

/// How `process_body` in pact_ffi branches on a parsed content type.
#[derive(Debug, PartialEq, Eq)]
enum Kind {
    Xml,
    Form,
    Json,
    Other,
    Invalid,
}

/// Parses `content_type` with the same function pact_ffi uses, then applies
/// its checks in the order `process_body` does: JSON first, then XML, then
/// form-urlencoded.
fn classify(content_type: &str) -> Kind {
    match ContentType::parse(content_type) {
        Err(_) => Kind::Invalid,
        Ok(ct) if ct.is_json() => Kind::Json,
        Ok(ct) if ct.is_xml() => Kind::Xml,
        Ok(ct) if ct.is_form_urlencoded() => Kind::Form,
        Ok(_) => Kind::Other,
    }
}

/// Returns `:xml`, `:form`, `:json`, `:other`, or `:invalid` when pact_ffi
/// cannot parse the content type (it then ignores it).
#[rustler::nif]
fn content_type_kind(content_type: String) -> Atom {
    match classify(&content_type) {
        Kind::Xml => atoms::xml(),
        Kind::Form => atoms::form(),
        Kind::Json => atoms::json(),
        Kind::Other => atoms::other(),
        Kind::Invalid => atoms::invalid(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_xml_types() {
        for ct in [
            "application/xml",
            "text/xml",
            "application/atom+xml",
            "text/foo+xml",
            "Application/XML; charset=utf-8",
            "application/xml;",
        ] {
            assert_eq!(classify(ct), Kind::Xml, "{ct}");
        }
    }

    #[test]
    fn classifies_form_types() {
        assert_eq!(classify("application/x-www-form-urlencoded"), Kind::Form);
        assert_eq!(
            classify("Application/X-WWW-Form-Urlencoded; charset=utf-8"),
            Kind::Form
        );
        assert_eq!(classify("text/x-www-form-urlencoded"), Kind::Other);
    }

    #[test]
    fn json_wins_over_xml() {
        assert_eq!(classify("application/json"), Kind::Json);
        assert_eq!(classify("application/hal+json"), Kind::Json);
        assert_eq!(classify("application/xml+json"), Kind::Json);
        assert_eq!(classify("application/json+xml"), Kind::Json);
    }

    #[test]
    fn classifies_other_types() {
        for ct in ["text/plain", "image/svg+xml", "application/xmlish"] {
            assert_eq!(classify(ct), Kind::Other, "{ct}");
        }
    }

    #[test]
    fn rejects_what_mime_cannot_parse() {
        for ct in [
            "",
            "nonsense",
            "application/xml ",
            " application/xml",
            "application/json; charset",
            "application/json,",
            "application/xml; charset",
            "application/x\0ml",
        ] {
            assert_eq!(classify(ct), Kind::Invalid, "{ct:?}");
        }
    }
}
