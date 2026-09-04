/// The number of minutes a test suite in this package may run before Swift Testing fails it.
///
/// Every `@Suite` under `Tests/` carries `.timeLimit(.minutes(suiteTimeLimitMinutes))`, so a test
/// that stops making progress fails its suite instead of holding the whole run open until something
/// outside the process gives up. One minute is the smallest bound Swift Testing can express: its
/// time limits have a granularity of one minute, and every shorter unit is unavailable.
///
/// The limit is enforced by cancelling the test's task, so what it ends is a test suspended on
/// something that never resumes. A test spinning synchronously reaches no cancellation point and
/// runs on regardless.
///
/// The bound guards against that suspension and is not the design target, which stays 100 ms per
/// test with a ceiling of one second. A parameterized test is bounded per case rather than across
/// its whole argument set, so a many-argument test can still run longer than this in total.
package let suiteTimeLimitMinutes = 1
