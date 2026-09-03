/**
 * "Trial ends tomorrow" — composed once `trialEndsAt` is within 24 hours.
 *
 * Copy lives here; when (or whether) mail goes out lives in ../notify.js.
 * One file can never leak into the other.
 */
import { Button, Heading, Text } from "@react-email/components";
import { Shell, colors, style } from "./theme.js";

export function TrialEndingEmail({
  firstName = "there",
  when = "tomorrow",
  endsAt = "",
  price = "₹99",
}) {
  return (
    <Shell preview="One day left — activate to keep dictating.">
      <Heading style={style.h1}>Your free trial ends {when}</Heading>
      <Text style={style.p}>
        Hi {firstName} — a quick heads-up. Your SunoFlow free trial ends{" "}
        <strong>{when}</strong>
        {endsAt ? ` — ${endsAt}` : ""}. After that, dictation pauses until you
        activate.
      </Text>
      <Text style={style.p}>
        Activating keeps everything as it is: {price} a month, cancel any time,
        and the vocabulary SunoFlow has learned from your edits stays put.
      </Text>
      <Button href="https://sunoflow-app.web.app/dashboard.html" style={style.button}>
        Activate subscription
      </Button>
      <Text
        style={{
          ...style.small,
          margin: "26px 0 10px",
          color: colors.ink,
          fontWeight: 600,
        }}
      >
        What you'd lose with the trial:
      </Text>
      <Text style={style.bullet}>• Unlimited dictation, in any app</Text>
      <Text style={style.bullet}>
        • The AI cleanup pass — fillers out, punctuation and structure in
      </Text>
      <Text style={style.bullet}>
        • Every name, acronym and term it has learned from you
      </Text>
      <Text style={style.small}>
        Already activated? You're all set — ignore this note.
      </Text>
    </Shell>
  );
}