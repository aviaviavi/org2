// --restart authorizes a second normal Quit event after a bounded grace period.
// Never kill the process or replace a bundle that is still running.
export function requestAppQuit({ sendQuit, waitForStop, onRetry = () => {} }) {
  const first = sendQuit();
  if (waitForStop(5_000).length === 0) return;
  onRetry();
  const second = sendQuit();
  if (waitForStop(30_000).length === 0) return;
  const detail = [first?.stderr, second?.stderr].filter(Boolean).join("\n").trim();
  throw new Error(`The app did not finish quitting; the verified build was not installed.${detail ? `\n${detail}` : ""}`);
}
