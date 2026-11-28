//! The words of a push, for an app that shows its own language (M8 step 8, S3).
//!
//! `title` and `body` stay English on the wire: the web's service worker shows
//! them as sent. A push whose title (or body) is made from a name also carries
//! `text: {key, args}`, and the Android app words it itself from these; a push
//! whose text is fixed is matched by the exact English below. The Android app
//! mirrors both (`notifications/KnownText.kt`); a key or string it does not know
//! is shown as sent.

/// `text` of a push: which words, and the names that go into them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushText {
    pub key: &'static str,
    pub args: Vec<(&'static str, String)>,
}

impl PushText {
    pub fn new(key: &'static str, args: &[(&'static str, &str)]) -> Self {
        Self {
            key,
            args: args
                .iter()
                .map(|(name, value)| (*name, (*value).to_owned()))
                .collect(),
        }
    }
}

/// `{pot, provider, model, work}`: "<pot> asks to use a model",
/// "<provider>/<model> for "<work>"".
pub const POT_APPROVAL: &str = "potApproval";
/// `{pot}`: "<pot> is blocked by its budget".
pub const POT_BUDGET_BLOCKED: &str = "potBudgetBlocked";
/// `{pot}`: "<pot> asks for more budget".
pub const POT_BUDGET_REQUEST: &str = "potBudgetRequest";
/// `{pot}`: "<pot> proposes a handover".
pub const POT_HANDOVER: &str = "potHandover";
/// `{pot}`: "<pot> replied".
pub const POT_REPLIED: &str = "potReplied";
/// `{pot}`: "<pot> opened work"; the body is the work's title.
pub const POT_OPENED_WORK: &str = "potOpenedWork";
/// `{pot}`: "<pot> noticed something"; the body is the pot's note.
pub const POT_NOTICED: &str = "potNoticed";
/// `{schedule}`: "<schedule> finished", "… failed", "… was missed",
/// "… is waiting for you".
pub const SCHEDULE_FINISHED: &str = "scheduleFinished";
pub const SCHEDULE_FAILED: &str = "scheduleFailed";
pub const SCHEDULE_MISSED: &str = "scheduleMissed";
pub const SCHEDULE_WAITING: &str = "scheduleWaiting";
/// `{event, when, timezone}`: "Event reminder: <event>", and "This event is
/// happening now (<when> <timezone>)." or "This event starts at <when>
/// (<timezone>).". `when` is already formatted in the event's time zone.
pub const CALENDAR_NOW: &str = "calendarNow";
pub const CALENDAR_STARTS: &str = "calendarStarts";

/// Fixed titles and bodies.
pub const QUESTION_BODY: &str = "It needs your answer to go on.";
pub const BUDGET_BLOCKED_BODY: &str =
    "A budget limit is used up. Open the thread to review its limits.";
pub const BUDGET_REQUEST_BODY: &str = "Open it to approve or deny.";
pub const HANDOVER_BODY: &str = "Open the thread to review it.";
pub const REPLIED_BODY: &str = "Open the thread to read it.";
pub const NOTICED_TITLE: &str = "A pot noticed something";
pub const SCHEDULE_MISSED_BODY: &str = "Allow it to run it now, or dismiss it.";
pub const SCHEDULE_WAITING_BODY: &str = "The scheduled run needs your answer to go on.";
pub const SCHEDULE_RESULT_BODY: &str = "Scheduled run: open it to read the result.";
pub const TEST_TITLE: &str = "pirc notifications work";
pub const TEST_BODY: &str = "Scheduled runs and anything waiting for you will show up here.";
