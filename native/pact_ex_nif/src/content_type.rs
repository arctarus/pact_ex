//! Tells the Elixir side how `pactffi_with_body` will treat a content type.

use pact_models::content_types::{detect_content_type_from_string, ContentType};
use rustler::{Atom, Encoder, Env, Term};
use serde_json::Value;

mod atoms {
    rustler::atoms! {
        xml,
        form,
        json,
        other,
        invalid,
        too_deep,
        object,
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
///
/// This stays on a normal scheduler: the input is a header value or an
/// explicit content type, a few dozen bytes, and parsing it is a matter of
/// microseconds. (`detect_json` and `json_text_shape` take a whole body.)
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

/// The test `process_body` applies to the body text to decide that it is JSON
/// (`detect_content_type_from_string`, then `is_json`). It looks at the bytes
/// only, never at the content type.
fn detects_json(text: &str) -> bool {
    detect_content_type_from_string(text).is_some_and(|ct| ct.is_json())
}

/// `true` when pact_ffi's content sniffing takes `text` for JSON.
///
/// `text` is a whole body, so this runs on a dirty CPU scheduler: pact_models
/// uppercases a copy of it and runs four regular expressions over it, which
/// takes tens of milliseconds for a few MB. It also logs the whole text with
/// `debug!`, which formats and writes the body once more. That cost applies
/// only when a tracing subscriber that accepts debug-level events (`:debug` or
/// `:trace`) is installed, as `PactEx.Log.init(level: :debug)` does; without
/// one, `debug!` formats nothing.
/// There is no deep recursion to guard against: the `regex` crate matches in
/// linear time without recursion, and nothing here walks a nested structure,
/// so the scheduler thread's own stack is enough (no `on_large_stack`). It
/// makes no `pactffi_*` call, so the clear_error and same-thread rules do not
/// apply.
#[rustler::nif(schedule = "DirtyCpu")]
fn detect_json(text: String) -> bool {
    detects_json(&text)
}

#[derive(Debug, PartialEq, Eq)]
enum Shape {
    /// A JSON object, with serde_json's own rendering of it.
    Object(String),
    Other,
    Invalid,
    /// Valid so far, but nested 128 levels or more (serde_json's limit).
    TooDeep,
}

/// Parses `text` with serde_json, the parser behind `process_xml` and
/// `process_form_urlencoded_json`, and renders what it parsed. The rendering
/// is what pact_ffi works with from then on: `-0` is `-0.0`, an integer above
/// `u64::MAX` is a float, and of two equal keys only the last is left.
fn json_shape(text: &str) -> Shape {
    match serde_json::from_str::<Value>(text) {
        Ok(value @ Value::Object(_)) => Shape::Object(value.to_string()),
        Ok(_) => Shape::Other,
        // `Error::classify` calls this a syntax error, like any other, so the
        // message is the only thing that tells the two apart.
        Err(err) if err.to_string().starts_with("recursion limit exceeded") => Shape::TooDeep,
        Err(_) => Shape::Invalid,
    }
}

/// Returns `{:object, rendered}` when serde_json parses `text` to a JSON
/// object, `:other` for any other JSON value, `:too_deep` when the parse stops
/// at serde_json's nesting limit of 128, and `:invalid` when it does not parse
/// for any other reason.
///
/// `text` is a whole body, and the parse plus the rendering take over 100 ms
/// for 4 MB, so this runs on a dirty CPU scheduler. The parse, the rendering
/// and the drop of the `Value` recurse once per nesting level, but serde_json
/// stops the parse at a depth of 128, so the stack they use is bounded and
/// small (kilobytes), and the scheduler thread's own stack is enough (no
/// `on_large_stack`). Deeper input is `:too_deep`, never a stack overflow. It
/// makes no `pactffi_*` call, so the clear_error and same-thread rules do not
/// apply.
#[rustler::nif(schedule = "DirtyCpu")]
fn json_text_shape<'a>(env: Env<'a>, text: String) -> Term<'a> {
    match json_shape(&text) {
        Shape::Object(rendered) => (atoms::object(), rendered).encode(env),
        Shape::Other => atoms::other().encode(env),
        Shape::Invalid => atoms::invalid().encode(env),
        Shape::TooDeep => atoms::too_deep().encode(env),
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

    #[test]
    fn sniffing_looks_at_the_text_only() {
        for text in [
            r#"{"root":{"name":"a"}}"#,
            "[1]",
            "123 items",
            "1=a&2=b",
            "null_flag=1",
            "true",
            "  {\"a\":1}",
            // The HTML check in pact_models does not fire on an embedded tag.
            r#"{"root":{"name":"a","children":[{"content":"<html>"}]}}"#,
        ] {
            assert!(detects_json(text), "{text}");
        }
        for text in [
            "<a/>",
            "<?xml version='1.0'?><a/>",
            "a=1&b=2",
            "plain text",
            "",
            // The first key must start with a word character.
            r#"{"-a":1}"#,
            r#"{"":1}"#,
        ] {
            assert!(!detects_json(text), "{text:?}");
        }
    }

    #[test]
    fn json_shape_follows_serde_json() {
        assert_eq!(
            json_shape(r#"{"a":1}"#),
            Shape::Object(r#"{"a":1}"#.to_string())
        );
        // The last of two equal keys wins.
        assert_eq!(
            json_shape(r#"{"a":1,"a":2}"#),
            Shape::Object(r#"{"a":2}"#.to_string())
        );
        // Numbers are rendered the way pact_ffi reads them.
        assert_eq!(
            json_shape(r#"{"a":-0,"b":2e0,"c":18446744073709551616}"#),
            Shape::Object(r#"{"a":-0.0,"b":2.0,"c":1.8446744073709552e+19}"#.to_string())
        );
        for text in ["[1]", "123", "\"x\"", "null", "true"] {
            assert_eq!(json_shape(text), Shape::Other, "{text}");
        }
        for text in ["1=a&2=b", "{\"a", "", "{} x", "{\"a\":01}", "[1,]"] {
            assert_eq!(json_shape(text), Shape::Invalid, "{text:?}");
        }
        // serde_json stops at a recursion limit of 128: the object is level 1.
        let nested = |levels: usize| {
            format!(
                r#"{{"a":{}{}}}"#,
                "[".repeat(levels - 1),
                "]".repeat(levels - 1)
            )
        };
        assert!(matches!(json_shape(&nested(127)), Shape::Object(_)));
        assert_eq!(json_shape(&nested(128)), Shape::TooDeep);
        assert_eq!(json_shape(&nested(200)), Shape::TooDeep);
        // Too deep is only the depth. A syntax error before the limit is not.
        assert_eq!(json_shape(r#"{"a":[1,]}"#), Shape::Invalid);
        let deep_and_broken = format!(r#"{{"a":{}"#, "[".repeat(200));
        assert_eq!(json_shape(&deep_and_broken), Shape::TooDeep);
    }

    #[test]
    fn serde_json_reads_minus_zero_as_a_float() {
        let value: Value = serde_json::from_str("-0").unwrap();
        assert_eq!(value.as_u64(), None);
        let value: Value = serde_json::from_str("0").unwrap();
        assert_eq!(value.as_u64(), Some(0));
    }
}
