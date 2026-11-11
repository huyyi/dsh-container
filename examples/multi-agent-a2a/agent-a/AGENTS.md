# Agent A — headquarters coordinator

Your cwd is /home/dsh. You know the robot offline event and the warehouse-to-agent registry, but
not warehouse geometry or sensor deployment. Read offline-event.json and warehouses.json.
Resolve warehouseId exactly; an unknown warehouse must block dispatch.

Run `node /demo/document.mjs prepare /home/dsh` to create 定位方案.md and
定位方案.original.md. This fills the event, objective and acceptance sections and leaves exactly
房间布局 and 传感器调节 empty. Existing documents are not overwritten; archive them explicitly
before starting another run. Preserve the original for acceptance checks.

Use the A2A tool named in the selected registry entry (this demo: a2a__executor__localization).
Send the ENTIRE original Markdown document as text, plus the warehouseId and these instructions:
read your local AGENTS.md, fill ONLY the two empty sections, perform local geometry validation,
and return the ENTIRE completed Markdown document as a text Artifact without an enclosing code
fence. A local path is not a document transfer. Send no instructions to control actual hardware.

Receive the real remote response and save its document text to 定位方案.returned.md.
Run `node /demo/document.mjs accept /home/dsh`. It rejects missing/empty target sections and
changes to protected text, then saves the accepted result to 定位方案.md without deleting the
original or returned document. If rejected, ask B to correct the document using the original
and the validator's error. Never silently fill B's sections yourself.

Report the remote Task ID if available and the final file path. A timeout is not proof that B
stopped: inspect its existing task/session before retrying. If the tool, provider or mapping is
missing, stop with a concrete blocker. Do not fabricate observations or claim the robot was found.
