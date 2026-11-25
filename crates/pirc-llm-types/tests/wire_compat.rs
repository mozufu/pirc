//! Fixed bytes passed against pirc-protocol at eb45f71d before the DTO extraction.
use pirc_llm_types::{
    AssistantDelta, InferenceErrorCode, Message, Model, ModelApi, ModelRef, Provider, StopReason,
    ThinkingLevel, ToolChoice, ToolSpec, Usage, UserBlock, UserContent,
};
use serde::{Serialize, de::DeserializeOwned};

fn fixed<T: DeserializeOwned + Serialize>(bytes: &str) {
    let parsed: T = serde_json::from_str(bytes).unwrap();
    assert_eq!(serde_json::to_string(&parsed).unwrap(), bytes);
}

#[test]
fn messages_keep_exact_bytes_and_absent_null() {
    for bytes in [
        r#"{"role":"user","content":"hi","timestamp":1}"#,
        r#"{"role":"user","content":[{"type":"text","text":"hi","textSignature":"s"},{"type":"image","data":"AA==","mimeType":"image/png"}],"timestamp":2}"#,
        r#"{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"thinking","thinking":"hm","signature":"sig","redacted":false},{"type":"toolCall","id":"c","name":"n","arguments":{"z":1,"a":{"y":2,"b":3}},"thoughtSignature":"t"}],"api":"a","provider":"p","model":"m","usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10},"stopReason":"toolUse","errorMessage":"raw","timestamp":3,"completedAt":4,"canonicalProvider":"cp","responseId":"r","responseModel":"rm"}"#,
        r#"{"role":"assistant","content":[{"type":"thinking","thinking":"hm"}],"api":"a","provider":"p","model":"m","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"stop","timestamp":3}"#,
        r#"{"role":"toolResult","toolCallId":"c","toolName":"n","content":[],"isError":false,"timestamp":4}"#,
        r#"{"role":"toolResult","toolCallId":"c","toolName":"n","content":[],"details":null,"isError":true,"timestamp":4}"#,
        r#"{"role":"toolResult","toolCallId":"c","toolName":"n","content":[],"details":{"z":1,"a":2},"isError":false,"timestamp":4}"#,
        r#"{"role":"custom","customType":"note","content":"x","display":true,"timestamp":5}"#,
        r#"{"role":"custom","customType":"note","content":"x","display":false,"details":null,"timestamp":5}"#,
        r#"{"role":"compactionSummary","summary":"s","tokensBefore":9,"timestamp":6}"#,
    ] {
        fixed::<Message>(bytes);
    }
}

#[test]
fn deltas_keep_tags_and_field_order() {
    for bytes in [
        r#"{"type":"text_start","contentIndex":0}"#,
        r#"{"type":"text_delta","contentIndex":0,"delta":"x"}"#,
        r#"{"type":"text_end","contentIndex":0,"content":"x"}"#,
        r#"{"type":"thinking_start","contentIndex":1}"#,
        r#"{"type":"thinking_delta","contentIndex":1,"delta":"x"}"#,
        r#"{"type":"thinking_end","contentIndex":1,"content":"x"}"#,
        r#"{"type":"toolcall_start","contentIndex":2,"id":"c","toolName":"n"}"#,
        r#"{"type":"toolcall_delta","contentIndex":2,"delta":"{}"}"#,
        r#"{"type":"toolcall_end","contentIndex":2,"toolCall":{"type":"toolCall","id":"c","name":"n","arguments":{"z":1,"a":2}}}"#,
    ] {
        fixed::<AssistantDelta>(bytes);
    }
}

#[test]
fn schema_order_defaults_and_optional_fields_are_stable() {
    fixed::<ToolSpec>(
        r#"{"name":"t","description":"d","parameters":{"type":"object","properties":{"z":{},"a":{}},"required":["z","a"]}}"#,
    );
    fixed::<Usage>(r#"{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10}"#);
    fixed::<UserContent>(r#""text""#);
    fixed::<UserContent>(r#"[{"type":"text","text":"x"}]"#);
    fixed::<UserBlock>(r#"{"type":"text","text":"x"}"#);
    fixed::<ModelRef>(r#"{"provider":"p","id":"m"}"#);
    fixed::<ModelRef>(r#"{"provider":"p","id":"m","thinking":"xhigh"}"#);
    fixed::<Model>(
        r#"{"api":"openai-responses","baseUrl":"https://m","canonicalProvider":"cp","headers":{"z":"1","a":"2"},"thinkingLevelMap":{"high":null,"low":"x"},"id":"m","name":"M","contextWindow":200000,"maxTokens":32000,"reasoning":false,"input":["text"],"compat":{"z":1,"a":2}}"#,
    );
    fixed::<Provider>(
        r#"{"api":"openai-completions","piProvider":"openai","opencodeGo":false,"baseUrl":"https://p","headers":{"z":"1","a":"2"},"compat":{"z":1,"a":2},"models":[{"id":"m","contextWindow":200000,"maxTokens":32000,"reasoning":false,"input":["text"],"compat":{}}],"apiKey":"secret"}"#,
    );
    let model: Model = serde_json::from_str(r#"{"id":"m"}"#).unwrap();
    assert_eq!(
        serde_json::to_string(&model).unwrap(),
        r#"{"id":"m","contextWindow":200000,"maxTokens":32000,"reasoning":false,"input":["text"],"compat":{}}"#
    );
    let provider: Provider =
        serde_json::from_str(r#"{"api":"openai-chat","baseUrl":"u","models":[]}"#).unwrap();
    assert_eq!(
        serde_json::to_string(&provider).unwrap(),
        r#"{"api":"openai-chat","baseUrl":"u","headers":{},"compat":{},"models":[]}"#
    );
    assert!(
        serde_json::from_str::<ToolSpec>(
            r#"{"name":"t","description":"d","parameters":{},"extra":1}"#
        )
        .is_err()
    );
}

#[test]
fn enum_spellings_are_stable() {
    for bytes in [
        r#""stop""#,
        r#""length""#,
        r#""toolUse""#,
        r#""error""#,
        r#""aborted""#,
    ] {
        fixed::<StopReason>(bytes);
    }
    for bytes in [
        r#""unavailable""#,
        r#""invalid_request""#,
        r#""limit_exceeded""#,
        r#""timeout""#,
        r#""cancelled""#,
        r#""inference_failed""#,
    ] {
        fixed::<InferenceErrorCode>(bytes);
    }
    for bytes in [r#""auto""#, r#""none""#] {
        fixed::<ToolChoice>(bytes);
    }
    for bytes in [
        r#""off""#,
        r#""minimal""#,
        r#""low""#,
        r#""medium""#,
        r#""high""#,
        r#""xhigh""#,
        r#""max""#,
    ] {
        fixed::<ThinkingLevel>(bytes);
    }
    for bytes in [
        r#""openai-chat""#,
        r#""anthropic-messages""#,
        r#""openai-completions""#,
        r#""openai-responses""#,
        r#""openai-codex-responses""#,
    ] {
        fixed::<ModelApi>(bytes);
    }
}
