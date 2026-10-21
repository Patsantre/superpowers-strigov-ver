// A stand-in core adapter for tests/test-agent-dispatch.sh: the trivial "plain" test adapter
// (tests/fixtures/adapters/plain.mjs, which drives tests/fixtures/agent-stub.cjs) under the id of the claude harness
// and its job prefix ct-. The tests point $AGENT_DISPATCH_ADAPTER_DIR here, so agent-dispatch's core path — key
// resolution, the write reservation, maxParallel, status / result / cancel of core jobs, the runner — runs before the
// real claude adapter exists (increment 2). The key goes to PLAIN_API_KEY for any profile with a key-based auth.
import plain from "../adapters/plain.mjs";

export default { ...plain, id: "claude", idPrefix: "ct" };
