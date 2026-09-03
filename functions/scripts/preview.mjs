/**
 * Renders both trial emails to standalone files under /tmp so copy or layout
 * changes can be eyeballed in a browser without touching Firebase:
 *
 *   cd functions && npm run preview
 *   open /tmp/sunoflow-email-trial-ending.html /tmp/sunoflow-email-trial-ended.html
 */
import { createElement } from "react";
import { writeFile } from "node:fs/promises";
import { render } from "@react-email/render";

import { TrialEndedEmail } from "../emails/TrialEndedEmail.js";
import { TrialEndingEmail } from "../emails/TrialEndingEmail.js";

const fmtEndsAt = new Intl.DateTimeFormat("en-IN", {
  weekday: "long",
  day: "numeric",
  month: "long",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short",
  timeZone: "Asia/Kolkata",
});
const fmtEndedOn = new Intl.DateTimeFormat("en-IN", {
  weekday: "long",
  day: "numeric",
  month: "long",
  timeZone: "Asia/Kolkata",
});

const samples = [
  ["trial-ending", TrialEndingEmail, {
    firstName: "Prasenjeet",
    when: "tomorrow",
    endsAt: fmtEndsAt.format(new Date(Date.now() + 22 * 60 * 60 * 1000)),
    price: "₹99",
  }],
  ["trial-ended", TrialEndedEmail, {
    firstName: "Prasenjeet",
    endedOn: fmtEndedOn.format(new Date(Date.now() - 26 * 60 * 60 * 1000)),
    price: "₹99",
  }],
];

for (const [name, Template, props] of samples) {
  const html = await render(createElement(Template, props));
  const text = await render(createElement(Template, props), { plainText: true });

  // A plain-text render that still contains markup means the template pulled
  // in something render can't flatten — fail loudly here, not in production.
  if (/[<>]/.test(text)) throw new Error(`${name}: plain text still contains HTML`);

  const base = `/tmp/sunoflow-email-${name}`;
  await writeFile(`${base}.html`, html);
  await writeFile(`${base}.txt`, text);
  console.log("wrote", `${base}.html`, "and", `${base}.txt`);
}