// omp extension: reports main-session turns to NotchNotch's agent listener.
// Install: ln -s "$PWD/scripts/omp/notchnotch.ts" ~/.omp/agent/extensions/notchnotch.ts
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const ENDPOINT = "http://127.0.0.1:7823/event";
const TIMEOUT_MS = 1_000;

function report(ctx: ExtensionContext, state: "working" | "completed", event: string): void {
	// Subagent sessions (task tool, eval agent(), /tan clones) fire the same events.
	if (ctx.agent.kind !== "main") return;
	const body = {
		agent: "omp",
		state,
		event,
		session_id: `omp-${ctx.sessionManager.getSessionId()}`,
		title: ctx.sessionManager.getSessionName() ?? "",
		cwd: ctx.cwd,
		pid: process.pid,
	};
	// NotchNotch not running is normal; never surface it in the session.
	fetch(ENDPOINT, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(body),
		signal: AbortSignal.timeout(TIMEOUT_MS),
	}).catch(() => {});
}

export default function notchnotch(pi: ExtensionAPI) {
	pi.on("agent_start", (_event, ctx) => report(ctx, "working", "UserPromptSubmit"));
	pi.on("agent_end", (_event, ctx) => report(ctx, "completed", "Stop"));
}
