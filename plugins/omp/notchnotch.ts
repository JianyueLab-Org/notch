// NotchNotch omp plugin: reports main-session turns to NotchNotch.
// Install: link this file into ~/.omp/agent/extensions/ and manifest.json's
// directory into ~/Library/Application Support/NotchNotch/Plugins/.
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const ENDPOINT = "http://127.0.0.1:7823/event";
const PLUGIN_ID = "co.jianyuelab.notchnotch.omp";
const TIMEOUT_MS = 1_000;

function report(ctx: ExtensionContext, state: "working" | "completed"): void {
	// Subagent sessions (task tool, eval agent(), /tan clones) fire the same events.
	if (ctx.agent.kind !== "main") return;
	const body = {
		type: "session.update",
		plugin: PLUGIN_ID,
		id: ctx.sessionManager.getSessionId(),
		state,
		label: "omp",
		title: ctx.sessionManager.getSessionName() ?? "",
		cwd: ctx.cwd,
		pid: process.pid,
		alert: state === "completed",
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
	pi.on("agent_start", (_event, ctx) => report(ctx, "working"));
	pi.on("agent_end", (_event, ctx) => report(ctx, "completed"));
}
