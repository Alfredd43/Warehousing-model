// JSON API client. Every response is {data, meta}; errors are {error: {status, code, message}}.

export class ApiError extends Error {
  constructor(status, code, message, detail) {
    super(message);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

const READ_TIMEOUT_MS = 20000;
const WRITE_TIMEOUT_MS = 30000;

function query(params) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params || {})) {
    if (v !== undefined && v !== null && v !== "") q.set(k, v);
  }
  const s = q.toString();
  return s ? `?${s}` : "";
}

async function call(method, path, { params, body } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), method === "GET" ? READ_TIMEOUT_MS : WRITE_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(`/api${path}${query(params)}`, {
      method,
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
      cache: "no-store",
    });
  } catch (err) {
    if (method !== "GET") {
      // The write may already have committed; never retry it automatically.
      throw new ApiError(0, "unknown_outcome",
        "No reply from the server, so the result is unknown: the action may have been recorded. " +
        "Refresh the reports and check before repeating it.");
    }
    throw new ApiError(0, "disconnected", "Cannot reach the dashboard server. Check that it is running, then retry.");
  } finally {
    clearTimeout(timer);
  }
  let payload = null;
  try {
    payload = await response.json();
  } catch {
    throw new ApiError(response.status, "bad_response", `Unexpected reply from the server (HTTP ${response.status}).`);
  }
  if (!response.ok) {
    const e = payload && payload.error ? payload.error : {};
    throw new ApiError(response.status, e.code || "error", e.message || `HTTP ${response.status}`, e.detail);
  }
  return payload;
}

export const get = (path, params) => call("GET", path, { params });
export const post = (path, body = {}) => call("POST", path, { body });
